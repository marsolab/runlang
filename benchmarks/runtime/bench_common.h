#ifndef BENCH_COMMON_H
#define BENCH_COMMON_H

#include <stdint.h>
#include <stdio.h>
#include <time.h>

typedef struct {
    const char *name;
    int iterations;
    double ns_per_op;
} bench_result_t;

static inline double timespec_diff_ns(const struct timespec *start, const struct timespec *end) {
    return (double)(end->tv_sec - start->tv_sec) * 1e9 + (double)(end->tv_nsec - start->tv_nsec);
}

void bench_emit_result(const char *name, int iterations, double ns_per_op);

static inline void bench_print_json(const char *name, int iterations, double ns_per_op) {
    bench_emit_result(name, iterations, ns_per_op);
}

/* Benchmark function declarations */
extern void bench_spawn(void);
extern void bench_context_switch(void);
extern void bench_channel(void);
extern void bench_steal(void);
extern void bench_poll(void);
extern void bench_scheduler(void);

#endif
