#include "run_poller.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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

/* ---------- Zig bridge imports ---------- */

typedef void (*run_xev_ready_cb)(int fd, uint32_t events, void *read_g, void *write_g);

extern int run_xev_init(run_xev_ready_cb cb);
extern void run_xev_close(void);
extern int run_xev_open(int fd);
extern void run_xev_close_fd(int fd);
extern void run_xev_poll_read(int fd, void *g);
extern void run_xev_poll_write(int fd, void *g);
extern int run_xev_tick(void);
extern int run_xev_tick_blocking(int64_t timeout_ms);
extern int run_xev_async_init(void);
extern int run_xev_async_notify(void);
extern void run_xev_async_wait(void);
extern bool run_xev_has_waiters(void);

/* ---------- Internal state ---------- */

static pthread_mutex_t xev_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int32_t woken_count = 0;

/* ---------- Readiness callback ---------- */

/* Called from the Zig bridge when an fd becomes ready.
 * events bitmask: 1=read, 2=write, 3=both/error. */
static void on_fd_ready(int fd, uint32_t events, void *read_g, void *write_g) {
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

/* ---------- Public API (run_poller.h) ---------- */

void run_poller_init(void) {
    if (run_xev_init(on_fd_ready) < 0) {
        fprintf(stderr, "run: libxev init failed\n");
        abort();
    }
    run_xev_async_init();
}

void run_poller_close(void) {
    run_xev_close();
}

int run_poll_open(run_poll_desc_t *pd) {
    return run_xev_open(pd->fd);
}

void run_poll_close(run_poll_desc_t *pd) {
    pthread_mutex_lock(&xev_lock);
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

    run_xev_close_fd(pd->fd);
    pthread_mutex_unlock(&xev_lock);
}

void run_poll_wait(run_poll_desc_t *pd, run_poll_event_t events) {
    run_g_t *g = run_current_g();
    if (!g)
        return;

    pthread_mutex_lock(&xev_lock);

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
    pthread_mutex_unlock(&xev_lock);
    run_schedule();
}

int run_poller_poll(void) {
    if (!run_xev_has_waiters())
        return 0;

    pthread_mutex_lock(&xev_lock);
    __atomic_store_n(&woken_count, 0, __ATOMIC_SEQ_CST);
    run_xev_tick();
    int woken = __atomic_load_n(&woken_count, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&xev_lock);
    return woken;
}

int run_poller_poll_blocking(int64_t timeout_ns) {
    if (!run_xev_has_waiters())
        return 0;

    pthread_mutex_lock(&xev_lock);
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
    pthread_mutex_unlock(&xev_lock);
    return woken;
}

void run_poller_wakeup(void) {
    run_xev_async_notify();
}

bool run_poller_has_waiters(void) {
    return run_xev_has_waiters();
}
