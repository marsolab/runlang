#include "run_runtime_api.h"

#include "run_alloc.h"
#include "run_scheduler.h"
#include "run_stacktrace.h"
#include "run_string.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef RUN_VERSION
#define RUN_VERSION "0.1.0-dev"
#endif

int64_t run_runtime_num_cpu(void) {
    long n = run_cpu_count();
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

    if (skip < 0)
        return info;

    /* +1 to skip run_runtime_caller itself. */
    run_stack_entry_t entry;
    size_t captured = run_stacktrace_capture(&entry, 1, (size_t)skip + 1);
    if (captured == 1) {
        info.file = run_string_from_cstr(entry.file[0] ? entry.file : "<unknown>");
        info.line = entry.line;
        info.ok = true;
    }

    return info;
}

run_string_t run_runtime_stack(void) {
    run_stack_entry_t entries[128];
    /* Skip run_runtime_stack itself. */
    size_t count = run_stacktrace_capture(entries, 128, 1);
    if (count == 0) {
        return run_string_from_cstr("<stack trace unavailable>");
    }

    /* Each line: "<function> at <file>:<line>\n" plus a small safety margin. */
    size_t buf_size = 0;
    for (size_t i = 0; i < count; i++) {
        buf_size += strlen(entries[i].function) + strlen(entries[i].file) + 32;
    }

    char *buf = malloc(buf_size + 1);
    if (!buf) {
        return run_string_from_cstr("<out of memory>");
    }

    size_t pos = 0;
    for (size_t i = 0; i < count; i++) {
        const char *fn = entries[i].function[0] ? entries[i].function : "<unknown>";
        const char *file = entries[i].file[0] ? entries[i].file : "<unknown>";
        int written = snprintf(buf + pos, buf_size - pos, "%s at %s:%lld\n", fn, file,
                               (long long)entries[i].line);
        if (written > 0)
            pos += (size_t)written;
    }

    // NOLINTNEXTLINE(clang-analyzer-unix.Malloc): ownership transfers to returned run_string_t
    return run_string_from_parts(buf, pos);
}
