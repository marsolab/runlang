#include "bench_common.h"
#include "run_scheduler.h"

static void yield_loop_fn(void *arg) {
    int n = (int)(intptr_t)arg;
    for (int i = 0; i < n; i++) {
        run_yield();
    }
}

void bench_context_switch(void) {
    const int NUM_GS = 2;
    const int YIELDS_PER_G = 500000;
    const int TOTAL_SWITCHES = NUM_GS * YIELDS_PER_G;
    struct timespec start, end;

    for (int i = 0; i < NUM_GS; i++) {
        run_spawn(yield_loop_fn, (void *)(intptr_t)YIELDS_PER_G);
    }

    clock_gettime(CLOCK_MONOTONIC, &start);
    run_scheduler_run();
    clock_gettime(CLOCK_MONOTONIC, &end);

    double ns = timespec_diff_ns(&start, &end);
    bench_print_json("context_switch", TOTAL_SWITCHES, ns / TOTAL_SWITCHES);
}
