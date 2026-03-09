#include "run_slice.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

run_slice_t run_slice_new(size_t elem_size, size_t initial_cap) {
    void *ptr = NULL;
    if (initial_cap > 0) {
        ptr = malloc(elem_size * initial_cap);
        if (!ptr) {
            fprintf(stderr, "run: out of memory in slice_new\n");
            abort();
        }
    }
    return (run_slice_t){
        .ptr = ptr,
        .len = 0,
        .cap = initial_cap,
        .elem_size = elem_size,
    };
}

void run_slice_append(run_slice_t *s, const void *elem) {
    if (s->len == s->cap) {
        size_t new_cap = s->cap == 0 ? 4 : s->cap * 2;
        void *new_ptr = realloc(s->ptr, s->elem_size * new_cap);
        if (!new_ptr) {
            fprintf(stderr, "run: out of memory in slice_append\n");
            abort();
        }
        s->ptr = new_ptr;
        s->cap = new_cap;
    }
    memcpy((char *)s->ptr + s->len * s->elem_size, elem, s->elem_size);
    s->len++;
}

void *run_slice_get(run_slice_t *s, size_t index) {
    if (index >= s->len) {
        fprintf(stderr, "run: slice index out of bounds (%zu >= %zu)\n", index, s->len);
        abort();
    }
    return (char *)s->ptr + index * s->elem_size;
}

void run_slice_free(run_slice_t *s) {
    free(s->ptr);
    s->ptr = NULL;
    s->len = 0;
    s->cap = 0;
}
