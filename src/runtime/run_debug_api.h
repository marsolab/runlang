#ifndef RUN_DEBUG_API_H
#define RUN_DEBUG_API_H

#include "run_any.h"
#include "run_slice.h"
#include "run_string.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    run_string_t function;
    run_string_t file;
    int64_t line;
} run_stack_frame_t;

run_slice_t run_debug_stack_trace(int64_t skip);
void run_debug_print_stack(void);
run_string_t run_debug_format_stack(run_slice_t frames);
void run_debug_assert(bool condition, run_string_t msg);
void run_debug_assert_eq(run_any_t expected, run_any_t actual);
void run_debug_unreachable(run_string_t msg);
void run_debug_todo(run_string_t msg);
void run_debug_breakpoint(void);

#endif
