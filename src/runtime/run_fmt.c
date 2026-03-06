#include "run_fmt.h"
#include <stdio.h>
#include <inttypes.h>

void run_fmt_println(run_string_t s) {
    if (s.len > 0) {
        fwrite(s.ptr, 1, s.len, stdout);
    }
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
