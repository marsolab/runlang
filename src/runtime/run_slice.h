#ifndef RUN_SLICE_H
#define RUN_SLICE_H

#include <stddef.h>
#include <stdint.h>

/*
 * A slice header. The backing array lives on the generational heap and the
 * header remembers the generation it was allocated with; every element
 * access verifies it, so a stale header copy (e.g. kept across an append
 * that grew the array) fails deterministically instead of touching freed
 * memory.
 */
typedef struct {
    void *ptr;
    uint64_t generation; /* generation of ptr's allocation; 0 when ptr == NULL */
    size_t len;
    size_t cap;
    size_t elem_size;
} run_slice_t;

run_slice_t run_slice_new(size_t elem_size, size_t initial_cap);
void run_slice_append(run_slice_t *s, const void *elem);
void *run_slice_get(run_slice_t *s, size_t index);
int64_t run_slice_len(const run_slice_t *s);
void run_slice_free(run_slice_t *s);

#endif
