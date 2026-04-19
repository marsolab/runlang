#include "../run_poller.h"
#include "../run_scheduler.h"
#include "test_framework.h"

#include <string.h>
#include <unistd.h>

/* --- Helpers --- */

static volatile int read_done = 0;
static volatile int write_done = 0;

/* --- Test 1: has_waiters tracks open/close --- */

static void test_poller_has_waiters(void) {
    /* Before any registration, no waiters. */
    RUN_ASSERT(run_poller_has_waiters() == false);

    int fds[2];
    int rc = pipe(fds);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = fds[0];

    rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);
    RUN_ASSERT(run_poller_has_waiters() == true);

    /* Close: waiters should drop back to false. */
    run_poll_close(&pd);
    RUN_ASSERT(run_poller_has_waiters() == false);

    close(fds[0]);
    close(fds[1]);
}

static volatile int read_done_2 = 0;

/* --- Test 2: pipe read — data written before reader spawns --- */

typedef struct {
    run_poll_desc_t *pd;
    volatile int *flag;
} reader_ctx_t;

static void reader_fn(void *arg) {
    reader_ctx_t *ctx = (reader_ctx_t *)arg;
    run_poll_wait(ctx->pd, RUN_POLL_READ);
    *(ctx->flag) = 1;
}

static void test_poller_pipe_read(void) {
    read_done = 0;

    int fds[2];
    int rc = pipe(fds);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = fds[0];

    rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    /* Write data BEFORE spawning the reader so the pipe is already
     * readable when the poller registers interest. */
    char c = 'x';
    ssize_t nw = write(fds[1], &c, 1);
    RUN_ASSERT(nw == 1);

    reader_ctx_t ctx = {.pd = &pd, .flag = &read_done};
    run_spawn(reader_fn, &ctx);

    run_scheduler_run();

    RUN_ASSERT_EQ(read_done, 1);

    run_poll_close(&pd);
    close(fds[0]);
    close(fds[1]);
}

/* --- Test 3: poll_open returns 0 on success --- */

static void test_poller_open_close(void) {
    int fds[2];
    int rc = pipe(fds);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = fds[0];

    rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    /* Descriptor fields are as we set them. */
    RUN_ASSERT_EQ(pd.fd, fds[0]);
    RUN_ASSERT(pd.read_g == NULL);
    RUN_ASSERT(pd.write_g == NULL);
    RUN_ASSERT(pd.closing == false);

    /* Close sets closing flag and clears g pointers. */
    run_poll_close(&pd);
    RUN_ASSERT(pd.closing == true);

    close(fds[0]);
    close(fds[1]);
}

/* --- Test 3: poll_close wakes a parked reader G --- */

static void reader_close_fn(void *arg) {
    run_poll_desc_t *pd = (run_poll_desc_t *)arg;
    run_poll_wait(pd, RUN_POLL_READ);
    /* Woken by poll_close — mark done. */
    read_done = 1;
}

static void closer_fn(void *arg) {
    run_poll_desc_t *pd = (run_poll_desc_t *)arg;
    /* Yield once so the reader parks first. */
    run_yield();
    run_poll_close(pd);
    write_done = 1;
}

static void test_poller_close_while_waiting(void) {
    read_done = 0;
    write_done = 0;

    int fds[2];
    int rc = pipe(fds);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = fds[0];

    rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    /* Reader parks on poll_wait; closer yields then calls poll_close
     * which directly wakes the reader via run_g_ready.
     * Spawn closer first so reader is popped first (local queue is LIFO). */
    run_spawn(closer_fn, &pd);
    run_spawn(reader_close_fn, &pd);

    run_scheduler_run();

    RUN_ASSERT_EQ(read_done, 1);
    RUN_ASSERT_EQ(write_done, 1);

    close(fds[0]);
    close(fds[1]);
}

/* --- Test 5: multiple fds — two pipes, both readable, two reader Gs --- */

static void test_poller_multiple_fds(void) {
    read_done = 0;
    read_done_2 = 0;

    int fds1[2], fds2[2];
    int rc = pipe(fds1);
    RUN_ASSERT(rc == 0);
    rc = pipe(fds2);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd1, pd2;
    memset(&pd1, 0, sizeof(pd1));
    memset(&pd2, 0, sizeof(pd2));
    pd1.fd = fds1[0];
    pd2.fd = fds2[0];

    rc = run_poll_open(&pd1);
    RUN_ASSERT(rc == 0);
    rc = run_poll_open(&pd2);
    RUN_ASSERT(rc == 0);
    RUN_ASSERT(run_poller_has_waiters() == true);

    /* Pre-write data to both pipes so readiness is immediate. */
    char c = 'a';
    ssize_t nw = write(fds1[1], &c, 1);
    RUN_ASSERT(nw == 1);
    nw = write(fds2[1], &c, 1);
    RUN_ASSERT(nw == 1);

    reader_ctx_t ctx1 = {.pd = &pd1, .flag = &read_done};
    reader_ctx_t ctx2 = {.pd = &pd2, .flag = &read_done_2};

    run_spawn(reader_fn, &ctx1);
    run_spawn(reader_fn, &ctx2);

    run_scheduler_run();

    RUN_ASSERT_EQ(read_done, 1);
    RUN_ASSERT_EQ(read_done_2, 1);

    run_poll_close(&pd1);
    run_poll_close(&pd2);
    close(fds1[0]);
    close(fds1[1]);
    close(fds2[0]);
    close(fds2[1]);
}

/* --- Suite entry point --- */

void run_test_poller(void) {
    TEST_SUITE("run_poller");
    RUN_TEST(test_poller_has_waiters);
    RUN_TEST(test_poller_open_close);
    RUN_TEST(test_poller_close_while_waiting);
    RUN_TEST(test_poller_pipe_read);
    /* Gated on #424: libxev kqueue adapter only fires one fd's callback per
     * tick when multiple fds are ready, so this test hangs. Re-enable once
     * the adapter is fixed. */
    /* RUN_TEST(test_poller_multiple_fds); */
}
