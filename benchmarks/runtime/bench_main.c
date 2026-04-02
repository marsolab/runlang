#include "bench_common.h"
#include "run_scheduler.h"
#include <stdlib.h>

int main(void) {
    /* Force single-processor mode for consistent benchmarks */
    setenv("RUN_MAXPROCS", "1", 1);

    /* Initialize the scheduler */
    run_scheduler_init();

    printf("[\n");

    bench_spawn();
    printf(",");
    bench_context_switch();
    printf(",");
    bench_channel();
    printf(",");
    bench_scheduler();

    printf("]\n");

    return 0;
}
