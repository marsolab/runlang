#ifndef RUN_SLICE_H
#define RUN_SLICE_H

#include <stddef.h>

typedef struct {
    void *ptr;
    size_t len;
    size_t cap;
    size_t elem_size;
} run_slice_t;

run_slice_t run_slice_new(size_t elem_size, size_t initial_cap);
void run_slice_append(run_slice_t *s, const void *elem);
void *run_slice_get(run_slice_t *s, size_t index);
void run_slice_free(run_slice_t *s);

#endif
