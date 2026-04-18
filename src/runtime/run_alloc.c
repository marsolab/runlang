#include "run_alloc.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Allocation tracking counters */
static _Atomic int64_t run_alloc_total_count = 0;
static _Atomic int64_t run_free_total_count = 0;
static _Atomic int64_t run_bytes_total_allocated = 0;
static _Atomic int64_t run_bytes_total_freed = 0;
static _Atomic int64_t run_gen_check_count = 0;
static _Atomic int64_t run_gen_failure_count = 0;

/* Runtime-controllable generation check flag */
_Atomic bool run_gen_checks_enabled = true;

typedef struct {
    uint64_t generation;
    size_t alloc_size;
    void *base_ptr;
} run_alloc_header_t;

static run_alloc_header_t *run_get_header(void *ptr) {
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

    // NOLINTNEXTLINE(performance-no-int-to-ptr): alignment math requires uintptr_t round-trip
    run_alloc_header_t *block = (run_alloc_header_t *)(user_addr - sizeof(run_alloc_header_t));
    block->generation = 0;
    block->alloc_size = size;
    block->base_ptr = raw;

    // NOLINTNEXTLINE(performance-no-int-to-ptr): alignment math requires uintptr_t round-trip
    void *user_ptr = (void *)user_addr;
    memset(user_ptr, 0, size);

    atomic_fetch_add_explicit(&run_alloc_total_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&run_bytes_total_allocated, (int64_t)size, memory_order_relaxed);

    return user_ptr;
}

void run_gen_free(void *ptr) {
    if (!ptr)
        return;
    run_alloc_header_t *header = run_get_header(ptr);
    if (header->generation == RUN_GEN_FREED) {
        fprintf(stderr, "run: double free detected\n");
        abort();
    }
    atomic_fetch_add_explicit(&run_free_total_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&run_bytes_total_freed, (int64_t)header->alloc_size,
                              memory_order_relaxed);

    header->generation = RUN_GEN_FREED;
    free(header->base_ptr);
}

void run_gen_check(void *ptr, uint64_t expected_gen) {
#ifndef RUN_NO_GEN_CHECKS
    if (!atomic_load_explicit(&run_gen_checks_enabled, memory_order_relaxed))
        return;

    atomic_fetch_add_explicit(&run_gen_check_count, 1, memory_order_relaxed);

    if (!ptr) {
        atomic_fetch_add_explicit(&run_gen_failure_count, 1, memory_order_relaxed);
        fprintf(stderr, "run: null pointer dereference\n");
        abort();
    }
    run_alloc_header_t *header = run_get_header(ptr);
    if (header->generation == RUN_GEN_FREED) {
        atomic_fetch_add_explicit(&run_gen_failure_count, 1, memory_order_relaxed);
        fprintf(stderr, "run: use-after-free detected (memory has been freed)\n");
        abort();
    }
    if (header->generation != expected_gen) {
        atomic_fetch_add_explicit(&run_gen_failure_count, 1, memory_order_relaxed);
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
    return run_get_header(ptr)->generation;
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

/* Allocation stats getters */
int64_t run_alloc_get_count(void) {
    return atomic_load_explicit(&run_alloc_total_count, memory_order_relaxed);
}

int64_t run_alloc_get_free_count(void) {
    return atomic_load_explicit(&run_free_total_count, memory_order_relaxed);
}

int64_t run_alloc_get_bytes_allocated(void) {
    return atomic_load_explicit(&run_bytes_total_allocated, memory_order_relaxed);
}

int64_t run_alloc_get_bytes_freed(void) {
    return atomic_load_explicit(&run_bytes_total_freed, memory_order_relaxed);
}

int64_t run_alloc_get_gen_checks(void) {
    return atomic_load_explicit(&run_gen_check_count, memory_order_relaxed);
}

int64_t run_alloc_get_gen_failures(void) {
    return atomic_load_explicit(&run_gen_failure_count, memory_order_relaxed);
}
