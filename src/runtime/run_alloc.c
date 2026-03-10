#include "run_alloc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t generation;
    size_t alloc_size;
} run_alloc_header_t;

static run_alloc_header_t *get_header(void *ptr) {
    return (run_alloc_header_t *)((char *)ptr - sizeof(run_alloc_header_t));
}

void *run_gen_alloc(size_t size) {
    run_alloc_header_t *block = malloc(sizeof(run_alloc_header_t) + size);
    if (!block) {
        fprintf(stderr, "run: out of memory\n");
        abort();
    }
    block->generation = 0;
    block->alloc_size = size;
    void *user_ptr = (char *)block + sizeof(run_alloc_header_t);
    memset(user_ptr, 0, size);
    return user_ptr;
}

void run_gen_free(void *ptr) {
    if (!ptr)
        return;
    run_alloc_header_t *header = get_header(ptr);
    if (header->generation == RUN_GEN_FREED) {
        fprintf(stderr, "run: double free detected\n");
        abort();
    }
    header->generation = RUN_GEN_FREED;
    free(header);
}

void run_gen_check(void *ptr, uint64_t expected_gen) {
#ifndef RUN_NO_GEN_CHECKS
    if (!ptr) {
        fprintf(stderr, "run: null pointer dereference\n");
        abort();
    }
    run_alloc_header_t *header = get_header(ptr);
    if (header->generation == RUN_GEN_FREED) {
        fprintf(stderr, "run: use-after-free detected (memory has been freed)\n");
        abort();
    }
    if (header->generation != expected_gen) {
        fprintf(stderr, "run: generation check failed (expected %llu, got %llu)\n",
                (unsigned long long)expected_gen, (unsigned long long)header->generation);
        abort();
    }
#else
    (void)ptr;
    (void)expected_gen;
#endif
}

uint64_t run_gen_get(void *ptr) {
    if (!ptr) {
        fprintf(stderr, "run: null pointer in run_gen_get\n");
        abort();
    }
    return get_header(ptr)->generation;
}

run_gen_ref_t run_gen_ref_create(void *ptr) {
    run_gen_ref_t ref;
    ref.ptr = ptr;
    ref.generation = ptr ? run_gen_get(ptr) : 0;
    return ref;
}

void *run_gen_ref_deref(run_gen_ref_t ref) {
    run_gen_check(ref.ptr, ref.generation);
    return ref.ptr;
}
