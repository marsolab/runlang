#ifndef RUN_POLLER_H
#define RUN_POLLER_H

#include "run_scheduler.h"

#include <stdbool.h>
#include <stdint.h>

/* ========================================================================
 * Network Poller
 *
 * Integrates async I/O with the green thread scheduler. When a G performs
 * a blocking network operation, it registers interest with the poller and
 * parks itself (G_WAITING). The scheduler polls for completions and wakes
 * ready Gs.
 *
 * Backends:
 *   Linux  — io_uring (completion-based, kernel 5.1+)
 *   macOS  — kqueue   (readiness-based, but used in completion style)
 *
 * The poller is called from the scheduler's find_runnable path:
 *   1. Check local queue
 *   2. Check global queue
 *   3. Poll for I/O completions  <-- here
 *   4. Work stealing
 * ======================================================================== */

/* ---------- Poll descriptor ---------- */

/* Events that a G can wait for on a file descriptor. */
typedef enum {
    RUN_POLL_READ = 1 << 0,
    RUN_POLL_WRITE = 1 << 1,
} run_poll_event_t;

/* A poll descriptor associates an fd with a waiting G. */
typedef struct {
    int fd;
    run_poll_event_t events; /* events this G is waiting for */
    run_g_t *read_g;         /* G waiting for readability (or NULL) */
    run_g_t *write_g;        /* G waiting for writability (or NULL) */
    bool closing;            /* fd is being closed */
} run_poll_desc_t;

/* ---------- Poller lifecycle ---------- */

/* Initialize the poller. Called once from run_scheduler_init. */
void run_poller_init(void);

/* Shut down the poller. Called from scheduler cleanup. */
void run_poller_close(void);

/* ---------- Registration ---------- */

/* Register an fd with the poller. Must be called before poll_wait.
 * Returns 0 on success, -1 on error. */
int run_poll_open(run_poll_desc_t *pd);

/* Unregister an fd from the poller. Called when the fd is closed.
 * Wakes any Gs still waiting on this fd. */
void run_poll_close(run_poll_desc_t *pd);

/* ---------- Waiting ---------- */

/* Park the current G until the fd is ready for the given events.
 * The G transitions to G_WAITING and yields to the scheduler.
 * When the poller detects readiness, the G is made runnable again. */
void run_poll_wait(run_poll_desc_t *pd, run_poll_event_t events);

/* ---------- Polling (called from scheduler) ---------- */

/* Poll for completed I/O events without blocking (timeout = 0).
 * Returns the number of Gs made runnable. Called from find_runnable
 * on every scheduling pass. */
int run_poller_poll(void);

/* Poll for I/O events, blocking until at least one event arrives
 * or the timeout (in nanoseconds) expires. Used when the scheduler
 * has no runnable Gs and would otherwise park the M.
 * timeout_ns = 0 means non-blocking, -1 means block indefinitely. */
int run_poller_poll_blocking(int64_t timeout_ns);

/* ---------- Wakeup ---------- */

/* Wake the poller from a blocking poll (thread-safe, lockless). */
void run_poller_wakeup(void);

/* ---------- Query ---------- */

/* Returns true if the poller has any registered fds. */
bool run_poller_has_waiters(void);

#endif
