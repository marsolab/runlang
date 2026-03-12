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

// Go-fmt-style convenience entry points used by stdlib/fmt wiring.
int run_fmt_printf(const char *fmt, ...);
int run_fmt_printfln(const char *fmt, ...);

// Bootstrap formatting helpers for stdlib/fmt implementation.
// Supports C-style format specifiers via snprintf semantics.
// Returned strings are heap-allocated and owned by caller.
run_string_t run_fmt_sprintf(const char *fmt, ...);

// Writes formatted output to caller-provided buffer.
// Returns number of bytes that would be written (excluding trailing NUL),
// or -1 on formatting error.
int run_fmt_snprintf(char *buf, size_t buf_size, const char *fmt, ...);

// ── Variadic any-typed formatting (Go-style verbs) ──────────────────────────

#include "run_any.h"

// Go-style printf: parses %d, %s, %f, %v, %t, %x, %o, %b, %e, %g verbs.
// Mismatched arg count produces %!(MISSING) or %!(EXTRA ...) markers.
void run_fmt_printf_args(run_string_t format, const run_any_t *args, size_t nargs);

// Returns heap-allocated formatted string using Go-style verbs.
run_string_t run_fmt_sprintf_args(run_string_t format, const run_any_t *args, size_t nargs);

// Print args with space separator and trailing newline (Go's fmt.Println).
void run_fmt_println_args(const run_any_t *args, size_t nargs);

// Print args with no separator or trailing newline (Go's fmt.Print).
void run_fmt_print_args(const run_any_t *args, size_t nargs);

// Sprint: concatenate default string representations of args.
run_string_t run_fmt_sprint_args(const run_any_t *args, size_t nargs);

// Sprintln: like sprint but with spaces and trailing newline.
run_string_t run_fmt_sprintln_args(const run_any_t *args, size_t nargs);

#endif
