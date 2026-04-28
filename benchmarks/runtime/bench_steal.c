#include "bench_common.h"
#include "run_scheduler.h"

#include <string.h>

void bench_steal(void) {
    const int N = 100000;
    struct timespec start, end;

    run_local_queue_t victim;
    run_local_queue_t thief;
    run_g_t gs[RUN_LOCAL_QUEUE_SIZE];

    memset(gs, 0, sizeof(gs));
    for (int i = 0; i < RUN_LOCAL_QUEUE_SIZE; i++) {
        gs[i].id = (uint64_t)(i + 1);
    }

    int stolen = 0;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (stolen < N) {
        run_local_queue_init(&victim);
        run_local_queue_init(&thief);

        int batch = N - stolen;
        if (batch > RUN_LOCAL_QUEUE_SIZE) {
            batch = RUN_LOCAL_QUEUE_SIZE;
        }

        for (int i = 0; i < batch; i++) {
            run_local_queue_push(&victim, &gs[i]);
        }
        for (int i = 0; i < batch; i++) {
            if (run_local_queue_steal(&victim, &thief) != NULL) {
                stolen++;
            }
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &end);

    double ns = timespec_diff_ns(&start, &end);
    bench_print_json("work_steal", N, ns / N);
}
