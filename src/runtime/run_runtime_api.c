#include "run_runtime_api.h"

#include "run_alloc.h"
#include "run_scheduler.h"
#include "run_string.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__) || defined(__linux__)
#include <dlfcn.h>
#include <execinfo.h>
#endif

#ifndef RUN_VERSION
#define RUN_VERSION "0.1.0-dev"
#endif

int64_t run_runtime_num_cpu(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int64_t)n : 1;
}

int64_t run_runtime_num_goroutine(void) {
    return run_scheduler_goroutine_count();
}

int64_t run_runtime_gomaxprocs(int64_t n) {
    if (n >= 1) {
        return (int64_t)run_scheduler_set_maxprocs((uint32_t)n);
    }
    return (int64_t)run_scheduler_get_maxprocs();
}

run_mem_stats_t run_runtime_mem_stats(void) {
    run_mem_stats_t stats;
    stats.alloc_count = run_alloc_get_count();
    stats.free_count = run_alloc_get_free_count();
    stats.bytes_allocated = run_alloc_get_bytes_allocated();
    stats.bytes_freed = run_alloc_get_bytes_freed();
    stats.generation_checks = run_alloc_get_gen_checks();
    stats.generation_failures = run_alloc_get_gen_failures();
    return stats;
}

run_string_t run_runtime_version(void) {
    return run_string_from_cstr(RUN_VERSION);
}

void run_runtime_gc_disable(void) {
    atomic_store_explicit(&run_gen_checks_enabled, false, memory_order_relaxed);
}

void run_runtime_gc_enable(void) {
    atomic_store_explicit(&run_gen_checks_enabled, true, memory_order_relaxed);
}

void run_runtime_yield(void) {
    run_yield();
}

run_caller_info_t run_runtime_caller(int64_t skip) {
    run_caller_info_t info;
    info.file = run_string_from_cstr("");
    info.line = 0;
    info.ok = false;

#if defined(__APPLE__) || defined(__linux__)
    /* skip + 1 to skip this function, + 1 more for safety */
    int depth = (int)skip + 2;
    void *frames[64];
    int count = backtrace(frames, 64);
    if (depth < count) {
        Dl_info dl;
        if (dladdr(frames[depth], &dl)) {
            info.file = run_string_from_cstr(dl.dli_fname ? dl.dli_fname : "<unknown>");
            info.ok = true;
            /* dladdr doesn't provide line numbers; set to 0 */
        }
    }
#endif

    return info;
}

run_string_t run_runtime_stack(void) {
#if defined(__APPLE__) || defined(__linux__)
    void *frames[128];
    int count = backtrace(frames, 128);
    char **symbols = backtrace_symbols(frames, count);
    if (!symbols) {
        return run_string_from_cstr("<stack trace unavailable>");
    }

    /* Calculate total buffer size */
    size_t total = 0;
    for (int i = 1; i < count; i++) {    /* skip frame 0 (this function) */
        total += strlen(symbols[i]) + 1; /* +1 for newline */
    }

    char *buf = malloc(total + 1);
    if (!buf) {
        free((void *)symbols);
        return run_string_from_cstr("<out of memory>");
    }

    size_t pos = 0;
    for (int i = 1; i < count; i++) {
        size_t len = strlen(symbols[i]);
        memcpy(buf + pos, symbols[i], len);
        pos += len;
        buf[pos++] = '\n';
    }
    buf[pos] = '\0';

    free((void *)symbols);

    /* Return as run_string_t — caller owns the memory */
    return run_string_from_parts(buf, pos);
#else
    return run_string_from_cstr("<stack trace not supported on this platform>");
#endif
}
