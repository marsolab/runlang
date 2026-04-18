#include "run_poller.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ========================================================================
 * Platform detection
 * ======================================================================== */

#if defined(__linux__)
#define RUN_POLLER_IOURING 1
#elif defined(__APPLE__)
#define RUN_POLLER_KQUEUE 1
#else
#define RUN_POLLER_STUB 1
#endif

/* ========================================================================
 * Shared state
 * ======================================================================== */

#include <pthread.h>

static pthread_mutex_t poller_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int32_t registered_fd_count = 0;

/* ========================================================================
 * Linux: io_uring
 *
 * io_uring is a completion-based async I/O interface (kernel 5.1+).
 * Unlike epoll (readiness-based), io_uring uses submission and completion
 * queues in shared memory between user space and kernel, minimizing
 * syscalls.
 *
 * Design:
 *   - One io_uring instance per scheduler (not per P) for simplicity.
 *   - poll_open submits IORING_OP_POLL_ADD SQEs to watch fds.
 *   - The scheduler's polling path reaps CQEs to wake Gs.
 *   - IORING_FEAT_FAST_POLL (kernel 5.7+) avoids internal worker threads
 *     for poll operations.
 *   - Multishot poll (IORING_POLL_ADD_MULTI, kernel 5.13+) keeps the
 *     registration alive across multiple events, avoiding re-arm overhead.
 * ======================================================================== */

#if defined(RUN_POLLER_IOURING)

#include <linux/io_uring.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/syscall.h>

/* io_uring syscall wrappers (not all libcs expose these) */

static int io_uring_setup(unsigned entries, struct io_uring_params *p) {
    return (int)syscall(SYS_io_uring_setup, entries, p);
}

static int io_uring_enter(int fd, unsigned to_submit, unsigned min_complete, unsigned flags,
                          void *arg, size_t argsz) {
    return (int)syscall(SYS_io_uring_enter, fd, to_submit, min_complete, flags, arg, argsz);
}

/* Ring sizes and configuration */
#define RING_ENTRIES 256

/* io_uring instance state */
typedef struct {
    int ring_fd;

    /* Submission queue */
    void *sq_mmap;
    size_t sq_mmap_size;
    uint32_t *sq_head;
    uint32_t *sq_tail;
    uint32_t *sq_ring_mask;
    uint32_t *sq_ring_entries;
    uint32_t *sq_flags;
    uint32_t *sq_array;
    struct io_uring_sqe *sqes;
    size_t sqes_mmap_size;

    /* Completion queue */
    void *cq_mmap;
    size_t cq_mmap_size;
    uint32_t *cq_head;
    uint32_t *cq_tail;
    uint32_t *cq_ring_mask;
    uint32_t *cq_ring_entries;
    struct io_uring_cqe *cqes;
} run_uring_t;

static run_uring_t uring;

/* Memory barriers for SQ/CQ synchronization */
#define io_uring_smp_store_release(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)
#define io_uring_smp_load_acquire(p) __atomic_load_n((p), __ATOMIC_ACQUIRE)

static int uring_init(void) {
    struct io_uring_params params;
    memset(&params, 0, sizeof(params));

    /* Request kernel-side SQ polling if available (reduces syscalls).
     * Falls back gracefully if not supported. */
    /* params.flags = IORING_SETUP_SQPOLL; */

    int fd = io_uring_setup(RING_ENTRIES, &params);
    if (fd < 0) {
        return -1;
    }
    uring.ring_fd = fd;

    /* Map the submission queue ring buffer */
    uring.sq_mmap_size = params.sq_off.array + params.sq_entries * sizeof(uint32_t);
    uring.sq_mmap = mmap(NULL, uring.sq_mmap_size, PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
    if (uring.sq_mmap == MAP_FAILED) {
        close(fd);
        return -1;
    }

    /* Set up SQ pointers into the mapped region */
    uint8_t *sq = (uint8_t *)uring.sq_mmap;
    uring.sq_head = (uint32_t *)(sq + params.sq_off.head);
    uring.sq_tail = (uint32_t *)(sq + params.sq_off.tail);
    uring.sq_ring_mask = (uint32_t *)(sq + params.sq_off.ring_mask);
    uring.sq_ring_entries = (uint32_t *)(sq + params.sq_off.ring_entries);
    uring.sq_flags = (uint32_t *)(sq + params.sq_off.flags);
    uring.sq_array = (uint32_t *)(sq + params.sq_off.array);

    /* Map the SQE array (separate mapping) */
    uring.sqes_mmap_size = params.sq_entries * sizeof(struct io_uring_sqe);
    uring.sqes = (struct io_uring_sqe *)mmap(NULL, uring.sqes_mmap_size, PROT_READ | PROT_WRITE,
                                             MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
    if (uring.sqes == MAP_FAILED) {
        munmap(uring.sq_mmap, uring.sq_mmap_size);
        close(fd);
        return -1;
    }

    /* Map the completion queue ring buffer */
    uring.cq_mmap_size = params.cq_off.cqes + params.cq_entries * sizeof(struct io_uring_cqe);
    /* CQ may share mapping with SQ (IORING_FEAT_SINGLE_MMAP) */
    if (params.features & IORING_FEAT_SINGLE_MMAP) {
        /* SQ and CQ share a single mmap; adjust SQ size to cover both */
        if (uring.cq_mmap_size > uring.sq_mmap_size) {
            munmap(uring.sq_mmap, uring.sq_mmap_size);
            uring.sq_mmap_size = uring.cq_mmap_size;
            uring.sq_mmap = mmap(NULL, uring.sq_mmap_size, PROT_READ | PROT_WRITE,
                                 MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
            if (uring.sq_mmap == MAP_FAILED) {
                munmap(uring.sqes, uring.sqes_mmap_size);
                close(fd);
                return -1;
            }
            /* Re-derive SQ pointers after re-mapping */
            sq = (uint8_t *)uring.sq_mmap;
            uring.sq_head = (uint32_t *)(sq + params.sq_off.head);
            uring.sq_tail = (uint32_t *)(sq + params.sq_off.tail);
            uring.sq_ring_mask = (uint32_t *)(sq + params.sq_off.ring_mask);
            uring.sq_ring_entries = (uint32_t *)(sq + params.sq_off.ring_entries);
            uring.sq_flags = (uint32_t *)(sq + params.sq_off.flags);
            uring.sq_array = (uint32_t *)(sq + params.sq_off.array);
        }
        uring.cq_mmap = uring.sq_mmap;
        uring.cq_mmap_size = 0; /* don't munmap separately */
    } else {
        uring.cq_mmap = mmap(NULL, uring.cq_mmap_size, PROT_READ | PROT_WRITE,
                             MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
        if (uring.cq_mmap == MAP_FAILED) {
            munmap(uring.sqes, uring.sqes_mmap_size);
            munmap(uring.sq_mmap, uring.sq_mmap_size);
            close(fd);
            return -1;
        }
    }

    /* Set up CQ pointers */
    uint8_t *cq = (uint8_t *)uring.cq_mmap;
    uring.cq_head = (uint32_t *)(cq + params.cq_off.head);
    uring.cq_tail = (uint32_t *)(cq + params.cq_off.tail);
    uring.cq_ring_mask = (uint32_t *)(cq + params.cq_off.ring_mask);
    uring.cq_ring_entries = (uint32_t *)(cq + params.cq_off.ring_entries);
    uring.cqes = (struct io_uring_cqe *)(cq + params.cq_off.cqes);

    return 0;
}

static void uring_close(void) {
    if (uring.ring_fd < 0)
        return;

    if (uring.cq_mmap_size > 0 && uring.cq_mmap != uring.sq_mmap) {
        munmap(uring.cq_mmap, uring.cq_mmap_size);
    }
    munmap(uring.sqes, uring.sqes_mmap_size);
    munmap(uring.sq_mmap, uring.sq_mmap_size);
    close(uring.ring_fd);
    uring.ring_fd = -1;
}

/* Get a submission queue entry, or NULL if the SQ is full. */
static struct io_uring_sqe *uring_get_sqe(void) {
    uint32_t tail = *uring.sq_tail;
    uint32_t head = io_uring_smp_load_acquire(uring.sq_head);
    uint32_t mask = *uring.sq_ring_mask;

    if (tail - head >= *uring.sq_ring_entries) {
        return NULL; /* SQ full */
    }

    struct io_uring_sqe *sqe = &uring.sqes[tail & mask];
    uring.sq_array[tail & mask] = tail & mask;
    return sqe;
}

/* Advance the SQ tail after filling one or more SQEs. */
static void uring_sq_advance(uint32_t count) {
    io_uring_smp_store_release(uring.sq_tail, *uring.sq_tail + count);
}

/* Submit pending SQEs to the kernel. */
static int uring_submit(void) {
    uint32_t tail = io_uring_smp_load_acquire(uring.sq_tail);
    uint32_t head = io_uring_smp_load_acquire(uring.sq_head);
    uint32_t to_submit = tail - head;
    if (to_submit == 0)
        return 0;
    return io_uring_enter(uring.ring_fd, to_submit, 0, 0, NULL, 0);
}

/* Submit and wait for at least min_complete completions. */
static int uring_submit_and_wait(uint32_t min_complete) {
    uint32_t tail = io_uring_smp_load_acquire(uring.sq_tail);
    uint32_t head = io_uring_smp_load_acquire(uring.sq_head);
    uint32_t to_submit = tail - head;
    unsigned flags = 0;
    if (min_complete > 0)
        flags |= IORING_ENTER_GETEVENTS;
    return io_uring_enter(uring.ring_fd, to_submit, min_complete, flags, NULL, 0);
}

/* Reap completed events. Returns number of CQEs consumed. */
static int uring_reap(void) {
    int woken = 0;
    uint32_t head = io_uring_smp_load_acquire(uring.cq_head);
    uint32_t tail = io_uring_smp_load_acquire(uring.cq_tail);
    uint32_t mask = *uring.cq_ring_mask;

    while (head != tail) {
        struct io_uring_cqe *cqe = &uring.cqes[head & mask];
        uint64_t user_data = cqe->user_data;

        if (user_data != 0) {
            run_poll_desc_t *pd = (run_poll_desc_t *)(uintptr_t)user_data;

            /* Determine which Gs to wake based on the poll result */
            int32_t res = cqe->res;
            if (res >= 0) {
                if ((res & POLLIN) && pd->read_g) {
                    run_g_t *g = pd->read_g;
                    pd->read_g = NULL;
                    run_g_ready(g);
                    woken++;
                }
                if ((res & POLLOUT) && pd->write_g) {
                    run_g_t *g = pd->write_g;
                    pd->write_g = NULL;
                    run_g_ready(g);
                    woken++;
                }
                if ((res & (POLLERR | POLLHUP | POLLNVAL))) {
                    /* Error or hangup — wake both readers and writers */
                    if (pd->read_g) {
                        run_g_t *g = pd->read_g;
                        pd->read_g = NULL;
                        run_g_ready(g);
                        woken++;
                    }
                    if (pd->write_g) {
                        run_g_t *g = pd->write_g;
                        pd->write_g = NULL;
                        run_g_ready(g);
                        woken++;
                    }
                }
            } else {
                /* CQE error — wake all waiters */
                if (pd->read_g) {
                    run_g_t *g = pd->read_g;
                    pd->read_g = NULL;
                    run_g_ready(g);
                    woken++;
                }
                if (pd->write_g) {
                    run_g_t *g = pd->write_g;
                    pd->write_g = NULL;
                    run_g_ready(g);
                    woken++;
                }
            }
        }

        head++;
    }

    io_uring_smp_store_release(uring.cq_head, head);
    return woken;
}

/* ---------- Public API (io_uring backend) ---------- */

void run_poller_init(void) {
    uring.ring_fd = -1;
    if (uring_init() < 0) {
        fprintf(stderr, "run: io_uring init failed (kernel 5.1+ required)\n");
        abort();
    }
}

void run_poller_close(void) {
    uring_close();
}

int run_poll_open(run_poll_desc_t *pd) {
    (void)pd;
    /* io_uring doesn't require pre-registration of fds.
     * Interest is expressed per-operation via IORING_OP_POLL_ADD.
     * Just track the count. */
    __atomic_add_fetch(&registered_fd_count, 1, __ATOMIC_SEQ_CST);
    return 0;
}

void run_poll_close(run_poll_desc_t *pd) {
    pthread_mutex_lock(&poller_lock);
    pd->closing = true;

    /* Wake any Gs still waiting */
    if (pd->read_g) {
        run_g_t *g = pd->read_g;
        pd->read_g = NULL;
        run_g_ready(g);
    }
    if (pd->write_g) {
        run_g_t *g = pd->write_g;
        pd->write_g = NULL;
        run_g_ready(g);
    }

    /* Submit a POLL_REMOVE to cancel any outstanding poll SQEs for this fd.
     * We use the pd pointer as the user_data key to match. */
    struct io_uring_sqe *sqe = uring_get_sqe();
    if (sqe) {
        memset(sqe, 0, sizeof(*sqe));
        sqe->opcode = IORING_OP_POLL_REMOVE;
        sqe->user_data = (uint64_t)(uintptr_t)pd;
        uring_sq_advance(1);
        uring_submit();
    }

    __atomic_sub_fetch(&registered_fd_count, 1, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&poller_lock);
}

void run_poll_wait(run_poll_desc_t *pd, run_poll_event_t events) {
    run_g_t *g = run_current_g();
    if (!g)
        return;

    pthread_mutex_lock(&poller_lock);

    /* Record which G is waiting */
    if (events & RUN_POLL_READ)
        pd->read_g = g;
    if (events & RUN_POLL_WRITE)
        pd->write_g = g;

    /* Submit a POLL_ADD SQE to io_uring.
     * Use multishot (IORING_POLL_ADD_MULTI) if available (kernel 5.13+)
     * so we don't need to re-arm after each event. The CQE will have
     * IORING_CQE_F_MORE set if more events will follow. */
    struct io_uring_sqe *sqe = uring_get_sqe();
    if (sqe) {
        memset(sqe, 0, sizeof(*sqe));
        sqe->opcode = IORING_OP_POLL_ADD;
        sqe->fd = pd->fd;
        sqe->user_data = (uint64_t)(uintptr_t)pd;

        /* Translate our events to poll mask */
        uint32_t poll_mask = 0;
        if (events & RUN_POLL_READ)
            poll_mask |= POLLIN;
        if (events & RUN_POLL_WRITE)
            poll_mask |= POLLOUT;

#ifdef IORING_POLL_ADD_MULTI
        sqe->len = IORING_POLL_ADD_MULTI;
#endif
        /* io_uring expects poll_mask in the 32-bit poll_events field.
         * On little-endian (x86), this is straightforward.
         * On big-endian, byte-swap would be needed. Linux x86/arm64 is LE. */
        sqe->poll32_events = poll_mask;

        uring_sq_advance(1);
        uring_submit();
    }

    /* Park the G */
    g->status = G_WAITING;
    pthread_mutex_unlock(&poller_lock);
    run_schedule();
}

int run_poller_poll(void) {
    if (registered_fd_count == 0)
        return 0;

    pthread_mutex_lock(&poller_lock);
    int woken = uring_reap();
    pthread_mutex_unlock(&poller_lock);
    return woken;
}

int run_poller_poll_blocking(int64_t timeout_ns) {
    if (registered_fd_count == 0)
        return 0;

    pthread_mutex_lock(&poller_lock);

    if (timeout_ns == 0) {
        /* Non-blocking: just reap */
        int woken = uring_reap();
        pthread_mutex_unlock(&poller_lock);
        return woken;
    }

    /* Submit and wait for at least 1 completion */
    uring_submit_and_wait(1);
    int woken = uring_reap();
    pthread_mutex_unlock(&poller_lock);
    return woken;
}

void run_poller_wakeup(void) {
    /* Legacy poller: no-op. Ms are woken via pthread_cond_signal. */
}

bool run_poller_has_waiters(void) {
    return __atomic_load_n(&registered_fd_count, __ATOMIC_SEQ_CST) > 0;
}

/* ========================================================================
 * macOS: kqueue
 *
 * kqueue is a readiness-based event notification system. While not
 * completion-based like io_uring, it is the best available async I/O
 * interface on macOS and is used in completion style:
 *   - Register interest via kevent() with EV_ADD
 *   - Reap ready events via kevent() with timeout=0
 *   - Wake the associated G when its fd is ready
 *
 * kqueue advantages over select/poll:
 *   - O(1) event registration and retrieval
 *   - Edge-triggered with EV_CLEAR (no re-arm needed)
 *   - Can monitor any fd type, signals, timers, and processes
 * ======================================================================== */

#elif defined(RUN_POLLER_KQUEUE)

#include <sys/event.h>
#include <sys/types.h>

static int kq_fd = -1;

#define KQ_MAX_EVENTS 64

void run_poller_init(void) {
    kq_fd = kqueue();
    if (kq_fd < 0) {
        fprintf(stderr, "run: kqueue init failed: %s\n", strerror(errno));
        abort();
    }
}

void run_poller_close(void) {
    if (kq_fd >= 0) {
        close(kq_fd);
        kq_fd = -1;
    }
}

int run_poll_open(run_poll_desc_t *pd) {
    (void)pd;
    /* kqueue doesn't require pre-registration. Interest is expressed
     * per-operation via kevent(). Just track the count. */
    __atomic_add_fetch(&registered_fd_count, 1, __ATOMIC_SEQ_CST);
    return 0;
}

void run_poll_close(run_poll_desc_t *pd) {
    pthread_mutex_lock(&poller_lock);
    pd->closing = true;

    /* Remove any registered kevents for this fd */
    struct kevent changes[2];
    int nchanges = 0;
    EV_SET(&changes[nchanges++], pd->fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
    EV_SET(&changes[nchanges++], pd->fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
    /* Ignore errors — the filter may not be registered */
    kevent(kq_fd, changes, nchanges, NULL, 0, NULL);

    /* Wake any Gs still waiting */
    if (pd->read_g) {
        run_g_t *g = pd->read_g;
        pd->read_g = NULL;
        run_g_ready(g);
    }
    if (pd->write_g) {
        run_g_t *g = pd->write_g;
        pd->write_g = NULL;
        run_g_ready(g);
    }

    __atomic_sub_fetch(&registered_fd_count, 1, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&poller_lock);
}

void run_poll_wait(run_poll_desc_t *pd, run_poll_event_t events) {
    run_g_t *g = run_current_g();
    if (!g)
        return;

    pthread_mutex_lock(&poller_lock);

    struct kevent changes[2];
    int nchanges = 0;

    /* Register interest with EV_CLEAR for edge-triggered behavior.
     * EV_ONESHOT would require re-arming; EV_CLEAR automatically
     * resets the event state after delivery. */
    if (events & RUN_POLL_READ) {
        pd->read_g = g;
        EV_SET(&changes[nchanges++], pd->fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, pd);
    }
    if (events & RUN_POLL_WRITE) {
        pd->write_g = g;
        EV_SET(&changes[nchanges++], pd->fd, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, 0, pd);
    }

    if (nchanges > 0) {
        int ret = kevent(kq_fd, changes, nchanges, NULL, 0, NULL);
        if (ret < 0 && errno != ENOENT) {
            fprintf(stderr, "run: kevent register failed: %s\n", strerror(errno));
        }
    }

    /* Park the G */
    g->status = G_WAITING;
    pthread_mutex_unlock(&poller_lock);
    run_schedule();
}

/* Reap kqueue events and wake associated Gs. */
static int run_kq_reap(const struct timespec *timeout) {
    struct kevent events[KQ_MAX_EVENTS];
    int n = kevent(kq_fd, NULL, 0, events, KQ_MAX_EVENTS, timeout);
    if (n <= 0)
        return 0;

    int woken = 0;
    for (int i = 0; i < n; i++) {
        run_poll_desc_t *pd = (run_poll_desc_t *)events[i].udata;
        if (!pd)
            continue;

        if (events[i].flags & EV_ERROR) {
            /* Error — wake all waiters */
            if (pd->read_g) {
                run_g_t *g = pd->read_g;
                pd->read_g = NULL;
                run_g_ready(g);
                woken++;
            }
            if (pd->write_g) {
                run_g_t *g = pd->write_g;
                pd->write_g = NULL;
                run_g_ready(g);
                woken++;
            }
            continue;
        }

        if (events[i].filter == EVFILT_READ && pd->read_g) {
            run_g_t *g = pd->read_g;
            pd->read_g = NULL;
            run_g_ready(g);
            woken++;
        }
        if (events[i].filter == EVFILT_WRITE && pd->write_g) {
            run_g_t *g = pd->write_g;
            pd->write_g = NULL;
            run_g_ready(g);
            woken++;
        }

        /* EV_EOF — connection closed, wake remaining waiters */
        if (events[i].flags & EV_EOF) {
            if (pd->read_g) {
                run_g_t *g = pd->read_g;
                pd->read_g = NULL;
                run_g_ready(g);
                woken++;
            }
            if (pd->write_g) {
                run_g_t *g = pd->write_g;
                pd->write_g = NULL;
                run_g_ready(g);
                woken++;
            }
        }
    }

    return woken;
}

int run_poller_poll(void) {
    if (registered_fd_count == 0)
        return 0;

    pthread_mutex_lock(&poller_lock);
    struct timespec ts = {0, 0}; /* non-blocking */
    int woken = run_kq_reap(&ts);
    pthread_mutex_unlock(&poller_lock);
    return woken;
}

int run_poller_poll_blocking(int64_t timeout_ns) {
    if (registered_fd_count == 0)
        return 0;

    pthread_mutex_lock(&poller_lock);

    const struct timespec *ts_ptr = NULL;
    struct timespec ts;
    if (timeout_ns == 0) {
        ts.tv_sec = 0;
        ts.tv_nsec = 0;
        ts_ptr = &ts;
    } else if (timeout_ns > 0) {
        ts.tv_sec = (time_t)(timeout_ns / 1000000000LL);
        ts.tv_nsec = (long)(timeout_ns % 1000000000LL);
        ts_ptr = &ts;
    }
    /* timeout_ns == -1: ts_ptr remains NULL, kevent blocks indefinitely */

    int woken = run_kq_reap(ts_ptr);
    pthread_mutex_unlock(&poller_lock);
    return woken;
}

void run_poller_wakeup(void) {
    /* Legacy poller: no-op. Ms are woken via pthread_cond_signal. */
}

bool run_poller_has_waiters(void) {
    return __atomic_load_n(&registered_fd_count, __ATOMIC_SEQ_CST) > 0;
}

/* ========================================================================
 * Stub (unsupported platforms)
 * ======================================================================== */

#elif defined(RUN_POLLER_STUB)

void run_poller_init(void) {}
void run_poller_close(void) {}
int run_poll_open(run_poll_desc_t *pd) {
    (void)pd;
    return -1;
}
void run_poll_close(run_poll_desc_t *pd) {
    (void)pd;
}
void run_poll_wait(run_poll_desc_t *pd, run_poll_event_t events) {
    (void)pd;
    (void)events;
}
int run_poller_poll(void) {
    return 0;
}
int run_poller_poll_blocking(int64_t timeout_ns) {
    (void)timeout_ns;
    return 0;
}
void run_poller_wakeup(void) {
    /* Stub poller: no-op. */
}
bool run_poller_has_waiters(void) {
    return false;
}

#endif
