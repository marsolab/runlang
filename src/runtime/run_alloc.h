#ifndef RUN_ALLOC_H
#define RUN_ALLOC_H

#include <stddef.h>
#include <stdint.h>

/* Generation counter overflow sentinel — indicates freed memory. */
#define RUN_GEN_FREED UINT64_MAX

/**
 * A generational reference: stores a raw pointer and the generation at which
 * the reference was created. Dereference checks compare the stored generation
 * against the allocation's current generation.
 */
typedef struct {
    void *ptr;
    uint64_t generation;
} run_gen_ref_t;

/* Allocate `size` bytes with generation tracking. Returns pointer to user data. */
void *run_gen_alloc(size_t size);

/* Free a generational allocation. Marks generation as freed. Detects double-free. */
void run_gen_free(void *ptr);

/**
 * Check that `ptr`'s current generation matches `expected_gen`.
 * Aborts on mismatch (use-after-free) or if the allocation has been freed.
 * Can be disabled at compile time with -DRUN_NO_GEN_CHECKS.
 */
void run_gen_check(void *ptr, uint64_t expected_gen);

/* Get the current generation of the allocation backing `ptr`. */
uint64_t run_gen_get(void *ptr);

/**
 * Create a generational reference from a raw pointer.
 * Captures the current generation of the allocation.
 */
run_gen_ref_t run_gen_ref_create(void *ptr);

/**
 * Dereference a generational reference with a safety check.
 * Returns the raw pointer if the generation matches; aborts otherwise.
 * Can be disabled at compile time with -DRUN_NO_GEN_CHECKS.
 */
void *run_gen_ref_deref(run_gen_ref_t ref);

#endif
