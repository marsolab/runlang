#ifndef RUN_FMT_H
#define RUN_FMT_H

#include "run_string.h"

#include <stdbool.h>
#include <stdint.h>

void run_fmt_println(run_string_t s);
void run_fmt_print_int(int64_t v);
void run_fmt_print_float(double v);
void run_fmt_print_bool(bool v);

#endif
