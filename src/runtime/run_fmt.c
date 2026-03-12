#include "run_fmt.h"

#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

void run_fmt_println(run_string_t s) {
    if (s.len > 0) {
        fwrite(s.ptr, 1, s.len, stdout);
    }
    putchar('\n');
}

void run_fmt_print(run_string_t s) {
    if (s.len > 0) {
        fwrite(s.ptr, 1, s.len, stdout);
    }
}

void run_fmt_newline(void) {
    putchar('\n');
}

void run_fmt_print_int(int64_t v) {
    printf("%" PRId64, v);
}

void run_fmt_print_float(double v) {
    printf("%g", v);
}

void run_fmt_print_bool(bool v) {
    fputs(v ? "true" : "false", stdout);
}

static int run_fmt_vsnprintf(char *buf, size_t buf_size, const char *fmt, va_list args) {
    int n = vsnprintf(buf, buf_size, fmt, args);
    if (n < 0) {
        fprintf(stderr, "run: invalid format string\n");
        return -1;
    }
    return n;
}

static int run_fmt_vprintf(const char *fmt, va_list args) {
    int n = vprintf(fmt, args);
    if (n < 0) {
        fprintf(stderr, "run: invalid format string\n");
    }
    return n;
}

int run_fmt_printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int out = run_fmt_vprintf(fmt, args);
    va_end(args);
    return out;
}

int run_fmt_printfln(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int out = run_fmt_vprintf(fmt, args);
    va_end(args);

    if (out < 0) {
        return out;
    }

    putchar('\n');
    return out + 1;
}

run_string_t run_fmt_sprintf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    va_list args_copy;
    va_copy(args_copy, args);

    int needed = run_fmt_vsnprintf(NULL, 0, fmt, args);
    va_end(args);

    if (needed < 0) {
        va_end(args_copy);
        return (run_string_t){ .ptr = NULL, .len = 0 };
    }

    char *buf = malloc((size_t)needed + 1);
    if (!buf) {
        fprintf(stderr, "run: out of memory in run_fmt_sprintf\n");
        abort();
    }

    int written = run_fmt_vsnprintf(buf, (size_t)needed + 1, fmt, args_copy);
    va_end(args_copy);

    if (written < 0) {
        free(buf);
        return (run_string_t){ .ptr = NULL, .len = 0 };
    }

    return (run_string_t){
        .ptr = buf,
        .len = (size_t)written,
    };
}

int run_fmt_snprintf(char *buf, size_t buf_size, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int out = run_fmt_vsnprintf(buf, buf_size, fmt, args);
    va_end(args);
    return out;
}
