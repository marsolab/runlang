#include "bench_common.h"
#include "run_scheduler.h"

static void noop_fn(void *arg) {
    (void)arg;
}

void bench_spawn(void) {
    const int N = 100000;
    struct timespec start, end;

    clock_gettime(CLOCK_MONOTONIC, &start);
    for (int i = 0; i < N; i++) {
        run_spawn(noop_fn, NULL);
    }
    run_scheduler_run();
    clock_gettime(CLOCK_MONOTONIC, &end);

    double ns = timespec_diff_ns(&start, &end);
    bench_print_json("spawn", N, ns / N);
}
