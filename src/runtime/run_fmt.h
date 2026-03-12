#ifndef RUN_FMT_H
#define RUN_FMT_H

#include "run_string.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void run_fmt_println(run_string_t s);
void run_fmt_print(run_string_t s);
void run_fmt_newline(void);
void run_fmt_print_int(int64_t v);
void run_fmt_print_float(double v);
void run_fmt_print_bool(bool v);

// Bootstrap formatting helpers for stdlib/fmt implementation.
// Supports C-style format specifiers via snprintf semantics.
// Returned strings are heap-allocated and owned by caller.
run_string_t run_fmt_sprintf(const char *fmt, ...);

// Writes formatted output to caller-provided buffer.
// Returns number of bytes that would be written (excluding trailing NUL),
// or -1 on formatting error.
int run_fmt_snprintf(char *buf, size_t buf_size, const char *fmt, ...);

#endif
