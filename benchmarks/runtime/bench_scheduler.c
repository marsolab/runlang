#include "bench_common.h"
#include "run_scheduler.h"
#include <stdatomic.h>

static _Atomic int work_done = 0;

static void work_fn(void *arg) {
    int units = (int)(intptr_t)arg;
    /* Simulate some trivial work */
    volatile int sink = 0;
    for (int i = 0; i < units; i++) {
        sink += i;
    }
    atomic_fetch_add(&work_done, units);
}

void bench_scheduler(void) {
    const int NUM_GS = 10000;
    const int WORK_PER_G = 100;
    const int TOTAL_WORK = NUM_GS * WORK_PER_G;
    struct timespec start, end;

    atomic_store(&work_done, 0);

    for (int i = 0; i < NUM_GS; i++) {
        run_spawn(work_fn, (void *)(intptr_t)WORK_PER_G);
    }

    clock_gettime(CLOCK_MONOTONIC, &start);
    run_scheduler_run();
    clock_gettime(CLOCK_MONOTONIC, &end);

    double ns = timespec_diff_ns(&start, &end);
    bench_print_json("scheduler_throughput", TOTAL_WORK, ns / TOTAL_WORK);
}
