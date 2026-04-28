#include "bench_common.h"
#include "run_platform.h"
#include "run_poller.h"
#include "run_scheduler.h"

#include <stdatomic.h>
#include <string.h>

typedef struct {
    run_poll_desc_t *pd;
    int read_fd;
} poll_bench_ctx_t;

static _Atomic int poll_done = 0;

static void poll_reader_fn(void *arg) {
    poll_bench_ctx_t *ctx = (poll_bench_ctx_t *)arg;
    run_poll_wait(ctx->pd, RUN_POLL_READ);

    char c = 0;
    int n = run_fd_read(ctx->read_fd, &c, 1);
    if (n == 1) {
        atomic_store(&poll_done, 1);
    }
}

void bench_poll(void) {
#ifdef _WIN32
    bench_print_json("poll_delivery", 0, 0.0);
    return;
#else
    const int N = 1;
    struct timespec start, end;

    run_pipe_t pipe_pair;
    if (!run_pipe_open(&pipe_pair)) {
        bench_print_json("poll_delivery", 0, 0.0);
        return;
    }

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = pipe_pair.read_fd;
    if (run_poll_open(&pd) != 0) {
        run_pipe_close(&pipe_pair);
        bench_print_json("poll_delivery", 0, 0.0);
        return;
    }

    char c = 'p';
    if (run_fd_write(pipe_pair.write_fd, &c, 1) != 1) {
        run_poll_close(&pd);
        run_pipe_close(&pipe_pair);
        bench_print_json("poll_delivery", 0, 0.0);
        return;
    }

    atomic_store(&poll_done, 0);
    poll_bench_ctx_t ctx = {.pd = &pd, .read_fd = pipe_pair.read_fd};
    run_spawn(poll_reader_fn, &ctx);

    clock_gettime(CLOCK_MONOTONIC, &start);
    run_scheduler_run();
    clock_gettime(CLOCK_MONOTONIC, &end);

    /* The one-shot wait completed; close should not re-ready this benchmark G. */
    pd.read_g = NULL;
    pd.write_g = NULL;
    run_poll_close(&pd);
    run_pipe_close(&pipe_pair);

    double ns = atomic_load(&poll_done) == 1 ? timespec_diff_ns(&start, &end) : 0.0;
    bench_print_json("poll_delivery", N, ns / N);
#endif
}
