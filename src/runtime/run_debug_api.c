#include "run_debug_api.h"

#include "run_alloc.h"
#include "run_slice.h"
#include "run_string.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__) || defined(__linux__)
#include <dlfcn.h>
#include <execinfo.h>
#endif

run_slice_t run_debug_stack_trace(int64_t skip) {
    run_slice_t result = run_slice_new(sizeof(run_stack_frame_t), 16);

#if defined(__APPLE__) || defined(__linux__)
    void *addrs[128];
    int count = backtrace(addrs, 128);
    /* skip + 1 to skip this function */
    int start = (int)skip + 1;

    for (int i = start; i < count; i++) {
        run_stack_frame_t frame;
        frame.function = run_string_from_cstr("<unknown>");
        frame.file = run_string_from_cstr("<unknown>");
        frame.line = 0;

        Dl_info dl;
        if (dladdr(addrs[i], &dl)) {
            if (dl.dli_sname)
                frame.function = run_string_from_cstr(dl.dli_sname);
            if (dl.dli_fname)
                frame.file = run_string_from_cstr(dl.dli_fname);
        }

        run_slice_append(&result, &frame);
    }
#else
    (void)skip;
#endif

    return result;
}

void run_debug_print_stack(void) {
#if defined(__APPLE__) || defined(__linux__)
    void *addrs[128];
    int count = backtrace(addrs, 128);
    char **symbols = backtrace_symbols(addrs, count);
    if (!symbols) {
        fprintf(stderr, "<stack trace unavailable>\n");
        return;
    }

    fprintf(stderr, "goroutine stack trace:\n");
    for (int i = 1; i < count; i++) { /* skip frame 0 (this function) */
        fprintf(stderr, "  %s\n", symbols[i]);
    }

    free(symbols);
#else
    fprintf(stderr, "<stack trace not supported on this platform>\n");
#endif
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
