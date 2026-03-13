#ifndef RUN_ANY_H
#define RUN_ANY_H

#include "run_string.h"

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    RUN_ANY_INT = 0,
    RUN_ANY_FLOAT,
    RUN_ANY_STRING,
    RUN_ANY_BOOL,
} run_any_tag_t;

typedef struct {
    run_any_tag_t tag;
    union {
        int64_t i;
        double f;
        run_string_t s;
        bool b;
    } val;
} run_any_t;

static inline run_any_t run_any_int(int64_t v) {
    run_any_t a;
    a.tag = RUN_ANY_INT;
    a.val.i = v;
    return a;
}

static inline run_any_t run_any_float(double v) {
    run_any_t a;
    a.tag = RUN_ANY_FLOAT;
    a.val.f = v;
    return a;
}

static inline run_any_t run_any_string(run_string_t v) {
    run_any_t a;
    a.tag = RUN_ANY_STRING;
    a.val.s = v;
    return a;
}

static inline run_any_t run_any_bool(bool v) {
    run_any_t a;
    a.tag = RUN_ANY_BOOL;
    a.val.b = v;
    return a;
}

#endif
