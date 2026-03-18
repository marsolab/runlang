#include "run_alloc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t generation;
    size_t alloc_size;
    void *base_ptr;
} run_alloc_header_t;

static run_alloc_header_t *get_header(void *ptr) {
    return (run_alloc_header_t *)((char *)ptr - sizeof(run_alloc_header_t));
}

void *run_gen_alloc(size_t size) {
    return run_gen_alloc_aligned(size, _Alignof(max_align_t));
}

void *run_gen_alloc_aligned(size_t size, size_t alignment) {
    if (alignment < _Alignof(max_align_t)) {
        alignment = _Alignof(max_align_t);
    }

    /* Round alignment up to the next power of two if needed. */
    if ((alignment & (alignment - 1)) != 0) {
        size_t rounded = _Alignof(max_align_t);
        while (rounded < alignment) {
            rounded <<= 1;
        }
        alignment = rounded;
    }

    const size_t extra = sizeof(run_alloc_header_t) + alignment - 1;
    void *raw = malloc(extra + size);
    if (!raw) {
        fprintf(stderr, "run: out of memory\n");
        abort();
    }

    uintptr_t user_addr = (uintptr_t)raw + sizeof(run_alloc_header_t);
    user_addr = (user_addr + alignment - 1) & ~(uintptr_t)(alignment - 1);

    run_alloc_header_t *block = (run_alloc_header_t *)(user_addr - sizeof(run_alloc_header_t));
    block->generation = 0;
    block->alloc_size = size;
    block->base_ptr = raw;

    void *user_ptr = (void *)user_addr;
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
    free(header->base_ptr);
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
