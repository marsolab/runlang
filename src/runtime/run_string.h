#ifndef RUN_STRING_H
#define RUN_STRING_H

#include <stddef.h>
#include <stdbool.h>

typedef struct {
    const char *ptr;
    size_t len;
} run_string_t;

run_string_t run_string_from_cstr(const char *s);
run_string_t run_string_from_parts(const char *ptr, size_t len);
bool run_string_eq(run_string_t a, run_string_t b);
run_string_t run_string_concat(run_string_t a, run_string_t b);
void run_string_print(run_string_t s);

#endif
