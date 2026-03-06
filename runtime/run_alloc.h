#ifndef RUN_ALLOC_H
#define RUN_ALLOC_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    void *ptr;
    uint64_t generation;
} run_gen_ref_t;

/* Allocate `size` bytes with generation tracking. Returns pointer to user data. */
void *run_gen_alloc(size_t size);

/* Free a generational allocation. Increments generation before freeing. */
void run_gen_free(void *ptr);

/* Check that `ptr`'s current generation matches `expected_gen`. Aborts on mismatch. */
void run_gen_check(void *ptr, uint64_t expected_gen);

/* Get the current generation of the allocation backing `ptr`. */
uint64_t run_gen_get(void *ptr);

#endif
