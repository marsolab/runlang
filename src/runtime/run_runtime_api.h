#ifndef RUN_RUNTIME_API_H
#define RUN_RUNTIME_API_H

#include "run_string.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int64_t alloc_count;
    int64_t free_count;
    int64_t bytes_allocated;
    int64_t bytes_freed;
    int64_t generation_checks;
    int64_t generation_failures;
} run_mem_stats_t;

typedef struct {
    run_string_t file;
    int64_t line;
    bool ok;
} run_caller_info_t;

int64_t run_runtime_num_cpu(void);
int64_t run_runtime_num_goroutine(void);
int64_t run_runtime_gomaxprocs(int64_t n);
run_mem_stats_t run_runtime_mem_stats(void);
run_string_t run_runtime_version(void);
void run_runtime_gc_disable(void);
void run_runtime_gc_enable(void);
void run_runtime_yield(void);
run_caller_info_t run_runtime_caller(int64_t skip);
run_string_t run_runtime_stack(void);

#endif
