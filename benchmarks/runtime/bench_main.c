#include "bench_common.h"
#include "run_scheduler.h"

#include <stdlib.h>

#define MAX_BENCH_RESULTS 32

static bench_result_t bench_results[MAX_BENCH_RESULTS];
static int bench_result_count = 0;

void bench_emit_result(const char *name, int iterations, double ns_per_op) {
    if (bench_result_count < MAX_BENCH_RESULTS) {
        bench_results[bench_result_count++] = (bench_result_t){
            .name = name,
            .iterations = iterations,
            .ns_per_op = ns_per_op,
        };
    }
}

static void write_results(FILE *out) {
    fprintf(out, "{\n");
    fprintf(out, "  \"suite\": \"runtime\",\n");
    fprintf(out, "  \"results\": [\n");
    for (int i = 0; i < bench_result_count; i++) {
        const bench_result_t *r = &bench_results[i];
        fprintf(out, "    {\"name\": \"%s\", \"iterations\": %d, \"ns_per_op\": %.2f}%s\n", r->name,
                r->iterations, r->ns_per_op, i + 1 == bench_result_count ? "" : ",");
    }
    fprintf(out, "  ]\n");
    fprintf(out, "}\n");
}

static void write_results_file(void) {
    const char *path = getenv("RUN_BENCH_RESULTS");
    if (path == NULL || path[0] == '\0') {
        path = "bench-results.json";
    }

    FILE *out = fopen(path, "w");
    if (out == NULL) {
        perror("bench-results.json");
        exit(1);
    }
    write_results(out);
    fclose(out);
}

int main(void) {
    /* Default to single-P consistency, but allow explicit multi-P bench runs. */
    if (getenv("RUN_MAXPROCS") == NULL) {
        run_setenv("RUN_MAXPROCS", "1", 1);
    }

    /* Initialize the scheduler */
    run_scheduler_init();

    bench_spawn();
    bench_context_switch();
    bench_channel();
    bench_steal();
    bench_scheduler();
    bench_poll();

    write_results(stdout);
    write_results_file();

    return 0;
}
