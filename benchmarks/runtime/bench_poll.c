#include "bench_common.h"
#include "run_poller.h"
#include "run_scheduler.h"

#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    run_poll_desc_t *pd;
    int read_fd;
} poll_bench_ctx_t;

static _Atomic int poll_done = 0;

static void poll_reader_fn(void *arg) {
    poll_bench_ctx_t *ctx = (poll_bench_ctx_t *)arg;
    run_poll_wait(ctx->pd, RUN_POLL_READ);

    char c = 0;
    ssize_t n = read(ctx->read_fd, &c, 1);
    if (n == 1) {
        atomic_store(&poll_done, 1);
    }
}

void bench_poll(void) {
    const int N = 1;
    struct timespec start, end;

    int fds[2];
    if (pipe(fds) != 0) {
        bench_print_json("poll_delivery", 0, 0.0);
        return;
    }

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = fds[0];
    if (run_poll_open(&pd) != 0) {
        close(fds[0]);
        close(fds[1]);
        bench_print_json("poll_delivery", 0, 0.0);
        return;
    }

    char c = 'p';
    if (write(fds[1], &c, 1) != 1) {
        run_poll_close(&pd);
        close(fds[0]);
        close(fds[1]);
        bench_print_json("poll_delivery", 0, 0.0);
        return;
    }

    atomic_store(&poll_done, 0);
    poll_bench_ctx_t ctx = {.pd = &pd, .read_fd = fds[0]};
    run_spawn(poll_reader_fn, &ctx);

    clock_gettime(CLOCK_MONOTONIC, &start);
    run_scheduler_run();
    clock_gettime(CLOCK_MONOTONIC, &end);

    /* The one-shot wait completed; close should not re-ready this benchmark G. */
    pd.read_g = NULL;
    pd.write_g = NULL;
    run_poll_close(&pd);
    close(fds[0]);
    close(fds[1]);

    double ns = atomic_load(&poll_done) == 1 ? timespec_diff_ns(&start, &end) : 0.0;
    bench_print_json("poll_delivery", N, ns / N);
}
