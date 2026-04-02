#include "bench_common.h"
#include "run_scheduler.h"
#include "run_chan.h"

typedef struct {
    run_chan_t *ch;
    int count;
} chan_bench_ctx_t;

static void sender_fn(void *arg) {
    chan_bench_ctx_t *ctx = (chan_bench_ctx_t *)arg;
    for (int i = 0; i < ctx->count; i++) {
        int64_t val = (int64_t)i;
        run_chan_send(ctx->ch, &val);
    }
}

static void receiver_fn(void *arg) {
    chan_bench_ctx_t *ctx = (chan_bench_ctx_t *)arg;
    for (int i = 0; i < ctx->count; i++) {
        int64_t val = 0;
        run_chan_recv(ctx->ch, &val);
    }
}

void bench_channel(void) {
    const int N = 100000;
    struct timespec start, end;

    run_chan_t *ch = run_chan_new(sizeof(int64_t), 64);
    chan_bench_ctx_t ctx = { .ch = ch, .count = N };

    run_spawn(sender_fn, &ctx);
    run_spawn(receiver_fn, &ctx);

    clock_gettime(CLOCK_MONOTONIC, &start);
    run_scheduler_run();
    clock_gettime(CLOCK_MONOTONIC, &end);

    double ns = timespec_diff_ns(&start, &end);
    bench_print_json("channel_throughput", N, ns / N);

    run_chan_free(ch);
}
