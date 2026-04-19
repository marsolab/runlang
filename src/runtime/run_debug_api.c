#include "run_debug_api.h"

#include "run_alloc.h"
#include "run_slice.h"
#include "run_stacktrace.h"
#include "run_string.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

run_slice_t run_debug_stack_trace(int64_t skip) {
    run_slice_t result = run_slice_new(sizeof(run_stack_frame_t), 16);

    if (skip < 0)
        return result;

    run_stack_entry_t entries[128];
    /* +1 to skip run_debug_stack_trace itself. */
    size_t count = run_stacktrace_capture(entries, 128, (size_t)skip + 1);

    for (size_t i = 0; i < count; i++) {
        run_stack_frame_t frame;
        frame.function =
            run_string_from_cstr(entries[i].function[0] ? entries[i].function : "<unknown>");
        frame.file = run_string_from_cstr(entries[i].file[0] ? entries[i].file : "<unknown>");
        frame.line = entries[i].line;
        run_slice_append(&result, &frame);
    }

    return result;
}

void run_debug_print_stack(void) {
    run_stack_entry_t entries[128];
    /* Skip run_debug_print_stack itself. */
    size_t count = run_stacktrace_capture(entries, 128, 1);
    if (count == 0) {
        fprintf(stderr, "<stack trace unavailable>\n");
        return;
    }

    fprintf(stderr, "goroutine stack trace:\n");
    for (size_t i = 0; i < count; i++) {
        const char *fn = entries[i].function[0] ? entries[i].function : "<unknown>";
        const char *file = entries[i].file[0] ? entries[i].file : "<unknown>";
        fprintf(stderr, "  %zu  %p  %s  (%s:%lld)\n", i + 1, entries[i].ip, fn, file,
                (long long)entries[i].line);
    }
}

run_string_t run_debug_format_stack(run_slice_t frames) {
    if (frames.len == 0) {
        return run_string_from_cstr("<empty stack>");
    }

    /* Estimate buffer size: ~256 bytes per frame */
    size_t buf_size = frames.len * 256;
    char *buf = malloc(buf_size);
    if (!buf) {
        return run_string_from_cstr("<out of memory>");
    }

    size_t pos = 0;
    for (size_t i = 0; i < frames.len; i++) {
        run_stack_frame_t *f =
            (run_stack_frame_t *)((char *)frames.ptr + i * sizeof(run_stack_frame_t));
        int written =
            snprintf(buf + pos, buf_size - pos, "%.*s\n    %.*s:%lld\n", (int)f->function.len,
                     f->function.ptr, (int)f->file.len, f->file.ptr, (long long)f->line);
        if (written > 0)
            pos += (size_t)written;
    }

    return run_string_from_parts(buf, pos);
}

void run_debug_assert(bool condition, run_string_t msg) {
    if (!condition) {
        fprintf(stderr, "run: assertion failed: %.*s\n", (int)msg.len, msg.ptr);
        abort();
    }
}

void run_debug_assert_eq(run_any_t expected, run_any_t actual) {
    if (expected.tag != actual.tag) {
        fprintf(stderr, "run: assert_eq failed: type mismatch\n");
        abort();
    }

    bool equal = false;
    switch (expected.tag) {
    case RUN_ANY_INT:
        equal = (expected.val.i == actual.val.i);
        break;
    case RUN_ANY_FLOAT:
        equal = (expected.val.f == actual.val.f);
        break;
    case RUN_ANY_STRING:
        equal = run_string_eq(expected.val.s, actual.val.s);
        break;
    case RUN_ANY_BOOL:
        equal = (expected.val.b == actual.val.b);
        break;
    }

    if (!equal) {
        switch (expected.tag) {
        case RUN_ANY_INT:
            fprintf(stderr, "run: assert_eq failed: expected %lld, got %lld\n",
                    (long long)expected.val.i, (long long)actual.val.i);
            break;
        case RUN_ANY_FLOAT:
            fprintf(stderr, "run: assert_eq failed: expected %g, got %g\n", expected.val.f,
                    actual.val.f);
            break;
        case RUN_ANY_STRING:
            fprintf(stderr, "run: assert_eq failed: expected \"%.*s\", got \"%.*s\"\n",
                    (int)expected.val.s.len, expected.val.s.ptr, (int)actual.val.s.len,
                    actual.val.s.ptr);
            break;
        case RUN_ANY_BOOL:
            fprintf(stderr, "run: assert_eq failed: expected %s, got %s\n",
                    expected.val.b ? "true" : "false", actual.val.b ? "true" : "false");
            break;
        }
        abort();
    }
}

void run_debug_unreachable(run_string_t msg) {
    fprintf(stderr, "run: unreachable reached: %.*s\n", (int)msg.len, msg.ptr);
    abort();
}

void run_debug_todo(run_string_t msg) {
    fprintf(stderr, "run: not implemented: %.*s\n", (int)msg.len, msg.ptr);
    abort();
}

void run_debug_breakpoint(void) {
#if __has_builtin(__builtin_debugtrap)
    __builtin_debugtrap();
#else
    raise(SIGTRAP);
#endif
}
