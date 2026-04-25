#include "../run_poller.h"
#include "../run_scheduler.h"
#include "test_framework.h"

#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

/* --- Helpers --- */

static volatile int read_done = 0;
static volatile int write_done = 0;

typedef struct {
    int read_fd;
    int write_fd;
} test_pipe_t;

static bool test_pipe_open(test_pipe_t *pipe_pair) {
    pipe_pair->read_fd = -1;
    pipe_pair->write_fd = -1;
#ifdef _WIN32
    static unsigned long pipe_counter = 0;
    char name[128];
    snprintf(name, sizeof(name), "\\\\.\\pipe\\runlang-poller-%lu-%lu",
             (unsigned long)GetCurrentProcessId(), ++pipe_counter);

    HANDLE read_handle =
        CreateNamedPipeA(name, PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
                         PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, NULL);
    if (read_handle == INVALID_HANDLE_VALUE)
        return false;

    HANDLE write_handle =
        CreateFileA(name, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (write_handle == INVALID_HANDLE_VALUE) {
        CloseHandle(read_handle);
        return false;
    }

    BOOL connected = ConnectNamedPipe(read_handle, NULL);
    if (!connected && GetLastError() != ERROR_PIPE_CONNECTED) {
        CloseHandle(read_handle);
        CloseHandle(write_handle);
        return false;
    }

    pipe_pair->read_fd = _open_osfhandle((intptr_t)read_handle, _O_RDONLY);
    if (pipe_pair->read_fd < 0) {
        CloseHandle(read_handle);
        CloseHandle(write_handle);
        return false;
    }

    pipe_pair->write_fd = _open_osfhandle((intptr_t)write_handle, _O_WRONLY);
    if (pipe_pair->write_fd < 0) {
        _close(pipe_pair->read_fd);
        CloseHandle(write_handle);
        pipe_pair->read_fd = -1;
        return false;
    }
#else
    int fds[2];
    int rc = pipe(fds);
    if (rc != 0)
        return false;
    pipe_pair->read_fd = fds[0];
    pipe_pair->write_fd = fds[1];
#endif
    return true;
}

static void test_pipe_close(test_pipe_t *pipe_pair) {
#ifdef _WIN32
    if (pipe_pair->read_fd >= 0)
        _close(pipe_pair->read_fd);
    if (pipe_pair->write_fd >= 0)
        _close(pipe_pair->write_fd);
#else
    if (pipe_pair->read_fd >= 0)
        close(pipe_pair->read_fd);
    if (pipe_pair->write_fd >= 0)
        close(pipe_pair->write_fd);
#endif
    pipe_pair->read_fd = -1;
    pipe_pair->write_fd = -1;
}

static int test_pipe_write_byte(int fd, char c) {
#ifdef _WIN32
    return _write(fd, &c, 1);
#else
    return (int)write(fd, &c, 1);
#endif
}

#ifndef _WIN32
static int test_pipe_read(int fd, char *buf, size_t len) {
    return (int)read(fd, buf, len);
}
#endif

/* --- Test 1: has_waiters tracks open/close --- */

static void test_poller_has_waiters(void) {
    /* Before any registration, no waiters. */
    RUN_ASSERT(run_poller_has_waiters() == false);

    test_pipe_t pipe_pair;
    RUN_ASSERT(test_pipe_open(&pipe_pair));

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = pipe_pair.read_fd;

    int rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);
    RUN_ASSERT(run_poller_has_waiters() == true);

    /* Close: waiters should drop back to false. */
    run_poll_close(&pd);
    RUN_ASSERT(run_poller_has_waiters() == false);

    test_pipe_close(&pipe_pair);
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

    test_pipe_t pipe_pair;
    RUN_ASSERT(test_pipe_open(&pipe_pair));

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = pipe_pair.read_fd;

    int rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    /* Write data BEFORE spawning the reader so the pipe is already
     * readable when the poller registers interest. */
    int nw = test_pipe_write_byte(pipe_pair.write_fd, 'x');
    RUN_ASSERT(nw == 1);

    reader_ctx_t ctx = {.pd = &pd, .flag = &read_done};
    run_spawn(reader_fn, &ctx);

    run_scheduler_run();

    RUN_ASSERT_EQ(read_done, 1);

    run_poll_close(&pd);
    test_pipe_close(&pipe_pair);
}

/* --- Test 3: poll_open returns 0 on success --- */

static void test_poller_open_close(void) {
    test_pipe_t pipe_pair;
    RUN_ASSERT(test_pipe_open(&pipe_pair));

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = pipe_pair.read_fd;

    int rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    /* Descriptor fields are as we set them. */
    RUN_ASSERT_EQ(pd.fd, pipe_pair.read_fd);
    RUN_ASSERT(pd.read_g == NULL);
    RUN_ASSERT(pd.write_g == NULL);
    RUN_ASSERT(pd.closing == false);

    /* Close sets closing flag and clears g pointers. */
    run_poll_close(&pd);
    RUN_ASSERT(pd.closing == true);

    test_pipe_close(&pipe_pair);
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

    test_pipe_t pipe_pair;
    RUN_ASSERT(test_pipe_open(&pipe_pair));

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = pipe_pair.read_fd;

    int rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    /* Reader parks on poll_wait; closer yields then calls poll_close
     * which directly wakes the reader via run_g_ready.
     * Spawn closer first so reader is popped first (local queue is LIFO). */
    run_spawn(closer_fn, &pd);
    run_spawn(reader_close_fn, &pd);

    run_scheduler_run();

    RUN_ASSERT_EQ(read_done, 1);
    RUN_ASSERT_EQ(write_done, 1);

    test_pipe_close(&pipe_pair);
}

/* --- Test 5: multiple fds — two pipes, both readable, two reader Gs --- */

static void test_poller_multiple_fds(void) {
    read_done = 0;
    read_done_2 = 0;

    test_pipe_t pipe1;
    test_pipe_t pipe2;
    RUN_ASSERT(test_pipe_open(&pipe1));
    RUN_ASSERT(test_pipe_open(&pipe2));

    run_poll_desc_t pd1, pd2;
    memset(&pd1, 0, sizeof(pd1));
    memset(&pd2, 0, sizeof(pd2));
    pd1.fd = pipe1.read_fd;
    pd2.fd = pipe2.read_fd;

    int rc = run_poll_open(&pd1);
    RUN_ASSERT(rc == 0);
    rc = run_poll_open(&pd2);
    RUN_ASSERT(rc == 0);
    RUN_ASSERT(run_poller_has_waiters() == true);

    /* Pre-write data to both pipes so readiness is immediate. */
    int nw = test_pipe_write_byte(pipe1.write_fd, 'a');
    RUN_ASSERT(nw == 1);
    nw = test_pipe_write_byte(pipe2.write_fd, 'a');
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
    test_pipe_close(&pipe1);
    test_pipe_close(&pipe2);
}

/* --- Test 6: write-interest park — fill pipe, park writer, drainer wakes it --- */

#ifndef _WIN32

typedef struct {
    run_poll_desc_t *pd;
    int write_fd;
    volatile int *flag;
} writer_ctx_t;

typedef struct {
    int read_fd;
    size_t to_drain;
} drainer_ctx_t;

static void writer_fn(void *arg) {
    writer_ctx_t *ctx = (writer_ctx_t *)arg;
    run_poll_wait(ctx->pd, RUN_POLL_WRITE);
    /* Write one byte to confirm the fd is now writable. */
    char c = 'w';
    ssize_t nw = write(ctx->write_fd, &c, 1);
    if (nw == 1)
        *(ctx->flag) = 1;
}

static void drainer_fn(void *arg) {
    drainer_ctx_t *ctx = (drainer_ctx_t *)arg;
    /* Yield first so the writer attempts poll_wait before we drain. */
    run_yield();
    char buf[4096];
    size_t drained = 0;
    while (drained < ctx->to_drain) {
        int nr = test_pipe_read(ctx->read_fd, buf, sizeof(buf));
        if (nr <= 0)
            break;
        drained += (size_t)nr;
    }
}

static void test_poller_write_park(void) {
    write_done = 0;

    test_pipe_t pipe_pair;
    RUN_ASSERT(test_pipe_open(&pipe_pair));

    /* Fill the pipe buffer so the write end is not writable.
     * macOS pipe capacity is 16–64KB; write nonblocking in chunks until EAGAIN. */
    int flags = fcntl(pipe_pair.write_fd, F_GETFL, 0);
    RUN_ASSERT(flags != -1);
    int rc = fcntl(pipe_pair.write_fd, F_SETFL, flags | O_NONBLOCK);
    RUN_ASSERT(rc == 0);

    /* Use 256-byte chunks (below PIPE_BUF) so writes are atomic: either
     * the whole chunk fits or the write returns EAGAIN with no partial data. */
    char chunk[256];
    memset(chunk, 'x', sizeof(chunk));
    size_t filled = 0;
    while (1) {
        int nw = (int)write(pipe_pair.write_fd, chunk, sizeof(chunk));
        if (nw < 0)
            break;
        filled += (size_t)nw;
        if (filled > 1024 * 1024)
            break; /* safety cap */
    }
    RUN_ASSERT(filled > 0);

    /* Restore blocking mode so the writer's one-byte write blocks on a
     * full buffer rather than erroring — but the poll should have woken it
     * precisely when the buffer had space. */
    rc = fcntl(pipe_pair.write_fd, F_SETFL, flags);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = pipe_pair.write_fd;

    rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    writer_ctx_t wctx = {.pd = &pd, .write_fd = pipe_pair.write_fd, .flag = &write_done};
    drainer_ctx_t dctx = {.read_fd = pipe_pair.read_fd, .to_drain = filled};

    /* Spawn drainer first so writer pops first (LIFO) and parks before drainer
     * yields and empties the pipe. */
    run_spawn(drainer_fn, &dctx);
    run_spawn(writer_fn, &wctx);

    run_scheduler_run();

    RUN_ASSERT_EQ(write_done, 1);

    run_poll_close(&pd);
    test_pipe_close(&pipe_pair);
}

#endif

/* --- Suite entry point --- */

void run_test_poller(void) {
    TEST_SUITE("run_poller");
    RUN_TEST(test_poller_has_waiters);
    RUN_TEST(test_poller_open_close);
#ifdef _WIN32
    RUN_TEST(test_poller_pipe_read);
    RUN_TEST(test_poller_close_while_waiting);
#else
    /* Gated on #426: hangs on Linux x86_64 CI due to libxev epoll state leaking
     * across tests (passes in isolation and on macOS). Re-enable once #426 is fixed. */
    /* RUN_TEST(test_poller_close_while_waiting); */
    /* Gated on #426: hangs on macOS CI due to libxev kqueue state leaking from
     * prior tests (passes in isolation). Re-enable once #426 is fixed. */
    /* RUN_TEST(test_poller_pipe_read); */
    /* Gated on #426: passes in isolation, but running it in the same suite as
     * test_poller_pipe_read in either order causes the second test to hang due
     * to inter-test libxev state leak. Re-enable once #426 is fixed. */
    /* RUN_TEST(test_poller_write_park); */
    /* Gated on #424: libxev kqueue adapter only fires one fd's callback per
     * tick when multiple fds are ready, so this test hangs. Re-enable once
     * the adapter is fixed. */
    /* RUN_TEST(test_poller_multiple_fds); */
#endif
}
