#include "run_xev.h"

#include "run_poller.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__wasi__)
#define RUN_XEV_LOCK() ((void)0)
#define RUN_XEV_UNLOCK() ((void)0)
#else
#include "run_platform.h"
static run_mutex_t xev_lock = RUN_MUTEX_INITIALIZER;
#define RUN_XEV_LOCK() run_mutex_lock(&xev_lock)
#define RUN_XEV_UNLOCK() run_mutex_unlock(&xev_lock)
#endif

/* ========================================================================
 * libxev-backed Network Poller
 *
 * Replaces the hand-written io_uring/kqueue poller (run_poller_legacy.c)
 * with a thin adapter over libxev. The actual event loop lives in
 * run_xev_bridge.zig which exports C-callable functions.
 *
 * Architecture:
 *   run_poller.h API  →  run_xev.c (this file)  →  run_xev_bridge.zig  →  libxev
 *
 * The Zig bridge is needed because libxev's C API does not expose fd
 * polling — only timers and async notifications. The Zig bridge uses
 * the full libxev Zig API (xev.File.poll) and exports C functions.
 * ======================================================================== */

/* ---------- Internal state ---------- */

#if defined(_WIN32)

static volatile int32_t windows_registered_count = 0;

#else

static volatile int32_t woken_count = 0;

/* ---------- Readiness callback ---------- */

/* Called from the Zig bridge when an fd becomes ready.
 * events bitmask: 1=read, 2=write, 3=both/error. */
static void run_on_fd_ready(int fd, uint32_t events, void *read_g, void *write_g) {
    (void)fd;

    if ((events & 1) && read_g) {
        run_g_ready((run_g_t *)read_g);
        __atomic_add_fetch(&woken_count, 1, __ATOMIC_SEQ_CST);
    }
    if ((events & 2) && write_g) {
        run_g_ready((run_g_t *)write_g);
        __atomic_add_fetch(&woken_count, 1, __ATOMIC_SEQ_CST);
    }
}

#endif

/* ---------- Public API (run_poller.h) ---------- */

void run_poller_init(void) {
#if defined(_WIN32)
    /* Windows fd readiness support is not wired through the runtime yet.
     * Keep the poller API available for bookkeeping-only tests without
     * initializing libxev's IOCP loop. */
#else
    if (run_xev_init(run_on_fd_ready) < 0) {
        fprintf(stderr, "run: libxev init failed\n");
        abort();
    }
    run_xev_async_init();
    run_xev_async_wait();
#endif
}

void run_poller_close(void) {
#if defined(_WIN32)
    __atomic_store_n(&windows_registered_count, 0, __ATOMIC_SEQ_CST);
#else
    run_xev_close();
#endif
}

int run_poll_open(run_poll_desc_t *pd) {
#if defined(_WIN32)
    pd->closing = false;
    __atomic_add_fetch(&windows_registered_count, 1, __ATOMIC_SEQ_CST);
    return 0;
#else
    return run_xev_open(pd->fd);
#endif
}

void run_poll_close(run_poll_desc_t *pd) {
    RUN_XEV_LOCK();
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

#if defined(_WIN32)
    int32_t count = __atomic_load_n(&windows_registered_count, __ATOMIC_SEQ_CST);
    if (count > 0) {
        __atomic_sub_fetch(&windows_registered_count, 1, __ATOMIC_SEQ_CST);
    }
#else
    run_xev_close_fd(pd->fd);
#endif
    RUN_XEV_UNLOCK();
}

void run_poll_wait(run_poll_desc_t *pd, run_poll_event_t events) {
#if defined(_WIN32)
    (void)pd;
    (void)events;
#else
    run_g_t *g = run_current_g();
    if (!g)
        return;

    RUN_XEV_LOCK();

    if (events & RUN_POLL_READ) {
        pd->read_g = g;
        run_xev_poll_read(pd->fd, g);
    }
    if (events & RUN_POLL_WRITE) {
        pd->write_g = g;
        run_xev_poll_write(pd->fd, g);
    }

    /* Park the G */
    g->status = G_WAITING;
    RUN_XEV_UNLOCK();
    run_schedule();

    RUN_XEV_LOCK();
    if ((events & RUN_POLL_READ) && pd->read_g == g) {
        pd->read_g = NULL;
    }
    if ((events & RUN_POLL_WRITE) && pd->write_g == g) {
        pd->write_g = NULL;
    }
    RUN_XEV_UNLOCK();
#endif
}

int run_poller_poll(void) {
#if defined(_WIN32)
    return 0;
#else
    if (!run_xev_has_waiters())
        return 0;

    RUN_XEV_LOCK();
    __atomic_store_n(&woken_count, 0, __ATOMIC_SEQ_CST);
    run_xev_tick();
    int woken = __atomic_load_n(&woken_count, __ATOMIC_SEQ_CST);
    RUN_XEV_UNLOCK();
    return woken;
#endif
}

int run_poller_poll_blocking(int64_t timeout_ns) {
#if defined(_WIN32)
    (void)timeout_ns;
    return 0;
#else
    if (!run_xev_has_waiters())
        return 0;

    RUN_XEV_LOCK();
    __atomic_store_n(&woken_count, 0, __ATOMIC_SEQ_CST);

    /* Convert nanoseconds to milliseconds for libxev */
    int64_t timeout_ms;
    if (timeout_ns == 0) {
        timeout_ms = 0;
    } else if (timeout_ns < 0) {
        timeout_ms = -1; /* block indefinitely */
    } else {
        timeout_ms = timeout_ns / 1000000;
        if (timeout_ms == 0)
            timeout_ms = 1; /* minimum 1ms */
    }

    run_xev_tick_blocking(timeout_ms);
    int woken = __atomic_load_n(&woken_count, __ATOMIC_SEQ_CST);
    RUN_XEV_UNLOCK();
    return woken;
#endif
}

void run_poller_wakeup(void) {
#if defined(_WIN32)
    (void)0;
#else
    run_xev_async_notify();
#endif
}

bool run_poller_has_waiters(void) {
#if defined(_WIN32)
    return __atomic_load_n(&windows_registered_count, __ATOMIC_SEQ_CST) > 0;
#else
    return run_xev_has_waiters();
#endif
}
