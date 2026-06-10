#include "run_alloc.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Allocation tracking counters. Plain (racy) on purpose: they sit on the
 * allocation and dereference hot paths, and atomic RMWs there cost more than
 * the operations being counted. The stats API is informational only. */
static int64_t run_alloc_total_count = 0;
static int64_t run_free_total_count = 0;
static int64_t run_bytes_total_allocated = 0;
static int64_t run_bytes_total_freed = 0;
static int64_t run_gen_check_count_relaxed = 0;
static _Atomic int64_t run_gen_failure_count = 0;

/* Runtime-controllable generation check flag */
_Atomic bool run_gen_checks_enabled = true;

/*
 * Monotonic generation epoch. Every live allocation gets a unique generation,
 * so a stale reference can never match a newer allocation that reuses the
 * same address. Starts at 1 so generation 0 never names a live allocation
 * (null references carry generation 0).
 */
static _Atomic uint64_t run_gen_epoch = 1;

typedef struct {
    /* Atomic so a generation check racing a free on another thread reads a
     * coherent value instead of being a data race. */
    _Atomic uint64_t generation;
    size_t alloc_size; /* size requested by the user for the current lifetime */
    size_t capacity;   /* usable bytes in the user area (size-class rounded) */
    void *base_ptr;    /* pointer returned by malloc, for bookkeeping */
} run_alloc_header_t;

static run_alloc_header_t *run_get_header(void *ptr) {
    return (run_alloc_header_t *)((char *)ptr - sizeof(run_alloc_header_t));
}

/*
 * Quarantine free lists.
 *
 * Freed blocks are NEVER returned to the system allocator. The header (and
 * its generation) must stay readable for the lifetime of the process so that
 * any stale generational reference can always be checked safely. Freed blocks
 * are instead recycled through per-size-class free lists; recycling assigns a
 * fresh generation from the epoch, so stale references to the old lifetime
 * fail the generation check.
 *
 * Classes are powers of two from 16 bytes (2^4) to 1 MiB (2^20). Larger
 * allocations go on a single first-fit list.
 */
#define RUN_ALLOC_MIN_CLASS_SHIFT 4
#define RUN_ALLOC_MAX_CLASS_SHIFT 20
#define RUN_ALLOC_CLASS_COUNT (RUN_ALLOC_MAX_CLASS_SHIFT - RUN_ALLOC_MIN_CLASS_SHIFT + 1)

/* Freelist links live in the (dead) user area of quarantined blocks. */
typedef struct run_free_node {
    struct run_free_node *next;
} run_free_node_t;

static run_free_node_t *run_free_lists[RUN_ALLOC_CLASS_COUNT];
static run_free_node_t *run_large_free_list;

/* One spinlock per class plus one for the large list. Zero-initialized. */
static _Atomic int run_free_locks[RUN_ALLOC_CLASS_COUNT + 1];

static void run_freelist_lock(size_t lock_idx) {
    while (atomic_exchange_explicit(&run_free_locks[lock_idx], 1, memory_order_acquire)) {
        /* spin */
    }
}

static void run_freelist_unlock(size_t lock_idx) {
    atomic_store_explicit(&run_free_locks[lock_idx], 0, memory_order_release);
}

/* Smallest class whose block size holds `size`, or -1 if it needs the large list. */
static int run_size_class(size_t size) {
    size_t class_size = (size_t)1 << RUN_ALLOC_MIN_CLASS_SHIFT;
    for (int c = 0; c < RUN_ALLOC_CLASS_COUNT; c++) {
        if (size <= class_size)
            return c;
        class_size <<= 1;
    }
    return -1;
}

static size_t run_class_block_size(int class_idx) {
    return (size_t)1 << ((size_t)class_idx + RUN_ALLOC_MIN_CLASS_SHIFT);
}

static uint64_t run_next_generation(void) {
    return atomic_fetch_add_explicit(&run_gen_epoch, 1, memory_order_relaxed);
}

/* Pop a recycled block that satisfies `size` and `alignment`, or NULL. */
static void *run_freelist_pop(size_t size, size_t alignment) {
    const int class_idx = run_size_class(size);

    if (class_idx >= 0) {
        run_freelist_lock((size_t)class_idx);
        run_free_node_t *node = run_free_lists[class_idx];
        /* Blocks are aligned to max_align_t at creation; stricter alignment
         * requests only take the head if it happens to satisfy them. */
        if (node && ((uintptr_t)node & (alignment - 1)) == 0) {
            run_free_lists[class_idx] = node->next;
            run_freelist_unlock((size_t)class_idx);
            return node;
        }
        run_freelist_unlock((size_t)class_idx);
        return NULL;
    }

    /* Large allocation: first fit by capacity and alignment. */
    run_freelist_lock(RUN_ALLOC_CLASS_COUNT);
    run_free_node_t **link = &run_large_free_list;
    while (*link) {
        run_free_node_t *node = *link;
        run_alloc_header_t *header = run_get_header(node);
        if (header->capacity >= size && ((uintptr_t)node & (alignment - 1)) == 0) {
            *link = node->next;
            run_freelist_unlock(RUN_ALLOC_CLASS_COUNT);
            return node;
        }
        link = &node->next;
    }
    run_freelist_unlock(RUN_ALLOC_CLASS_COUNT);
    return NULL;
}

static void run_freelist_push(void *user_ptr, size_t capacity) {
    run_free_node_t *node = (run_free_node_t *)user_ptr;
    const int class_idx = run_size_class(capacity);
    /* A class block's capacity is exactly its class size, so it goes back to
     * the same class it was carved for. */
    const size_t lock_idx = class_idx >= 0 ? (size_t)class_idx : RUN_ALLOC_CLASS_COUNT;
    run_free_node_t **list = class_idx >= 0 ? &run_free_lists[class_idx] : &run_large_free_list;

    run_freelist_lock(lock_idx);
    node->next = *list;
    *list = node;
    run_freelist_unlock(lock_idx);
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

    if (size == 0) {
        size = 1;
    }

    /* Recycle a quarantined block when possible. */
    void *recycled = run_freelist_pop(size, alignment);
    if (recycled) {
        run_alloc_header_t *header = run_get_header(recycled);
        atomic_store_explicit(&header->generation, run_next_generation(), memory_order_relaxed);
        header->alloc_size = size;
        memset(recycled, 0, size);

        run_alloc_total_count++;
        run_bytes_total_allocated += (int64_t)size;
        return recycled;
    }

    const int class_idx = run_size_class(size);
    const size_t capacity = class_idx >= 0 ? run_class_block_size(class_idx) : size;

    const size_t extra = sizeof(run_alloc_header_t) + alignment - 1;
    void *raw = malloc(extra + capacity);
    if (!raw) {
        fprintf(stderr, "run: out of memory\n");
        abort();
    }

    uintptr_t user_addr = (uintptr_t)raw + sizeof(run_alloc_header_t);
    user_addr = (user_addr + alignment - 1) & ~(uintptr_t)(alignment - 1);

    // NOLINTNEXTLINE(performance-no-int-to-ptr): alignment math requires uintptr_t round-trip
    run_alloc_header_t *block = (run_alloc_header_t *)(user_addr - sizeof(run_alloc_header_t));
    atomic_store_explicit(&block->generation, run_next_generation(), memory_order_relaxed);
    block->alloc_size = size;
    block->capacity = capacity;
    block->base_ptr = raw;

    // NOLINTNEXTLINE(performance-no-int-to-ptr): alignment math requires uintptr_t round-trip
    void *user_ptr = (void *)user_addr;
    memset(user_ptr, 0, size);

    run_alloc_total_count++;
    run_bytes_total_allocated += (int64_t)size;

    return user_ptr;
}

void run_gen_free(void *ptr) {
    if (!ptr)
        return;
    run_alloc_header_t *header = run_get_header(ptr);
    if (atomic_load_explicit(&header->generation, memory_order_relaxed) == RUN_GEN_FREED) {
        fprintf(stderr, "run: double free detected\n");
        abort();
    }
    run_free_total_count++;
    run_bytes_total_freed += (int64_t)header->alloc_size;

    atomic_store_explicit(&header->generation, RUN_GEN_FREED, memory_order_relaxed);
    /* Quarantine instead of free(): the header must stay readable so stale
     * references can still be generation-checked, and recycling bumps the
     * generation so they can never match again. */
    run_freelist_push(ptr, header->capacity);
}

void run_gen_check(void *ptr, uint64_t expected_gen) {
#ifndef RUN_NO_GEN_CHECKS
    if (!atomic_load_explicit(&run_gen_checks_enabled, memory_order_relaxed))
        return;

    /* Plain (racy) counter: this is on every pointer dereference, and an
     * atomic RMW here costs more than the check itself. The stats API is
     * informational, so approximate counts under contention are fine. */
    run_gen_check_count_relaxed++;

    if (!ptr) {
        atomic_fetch_add_explicit(&run_gen_failure_count, 1, memory_order_relaxed);
        fprintf(stderr, "run: null pointer dereference\n");
        abort();
    }
    run_alloc_header_t *header = run_get_header(ptr);
    const uint64_t current = atomic_load_explicit(&header->generation, memory_order_relaxed);
    if (current == RUN_GEN_FREED) {
        atomic_fetch_add_explicit(&run_gen_failure_count, 1, memory_order_relaxed);
        fprintf(stderr, "run: use-after-free detected (memory has been freed)\n");
        abort();
    }
    if (current != expected_gen) {
        atomic_fetch_add_explicit(&run_gen_failure_count, 1, memory_order_relaxed);
        fprintf(stderr, "run: generation check failed (expected %llu, got %llu)\n",
                (unsigned long long)expected_gen, (unsigned long long)current);
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
    return atomic_load_explicit(&run_get_header(ptr)->generation, memory_order_relaxed);
}

run_gen_ref_t run_gen_ref_create(void *ptr) {
    run_gen_ref_t ref;
    ref.ptr = ptr;
    ref.generation = ptr ? run_gen_get(ptr) : 0;
    return ref;
}

run_gen_ref_t run_gen_ref_stack(void *ptr) {
    run_gen_ref_t ref;
    ref.ptr = ptr;
    ref.generation = 0;
    return ref;
}

void *run_gen_ref_deref(run_gen_ref_t ref) {
    if (!ref.ptr) {
        fprintf(stderr, "run: null pointer dereference\n");
        abort();
    }
    /* Generation 0 marks an unchecked stack reference (no header). */
    if (ref.generation == 0) {
        return ref.ptr;
    }
    run_gen_check(ref.ptr, ref.generation);
    return ref.ptr;
}

/* Allocation stats getters */
int64_t run_alloc_get_count(void) {
    return run_alloc_total_count;
}

int64_t run_alloc_get_free_count(void) {
    return run_free_total_count;
}

int64_t run_alloc_get_bytes_allocated(void) {
    return run_bytes_total_allocated;
}

int64_t run_alloc_get_bytes_freed(void) {
    return run_bytes_total_freed;
}

int64_t run_alloc_get_gen_checks(void) {
    return run_gen_check_count_relaxed;
}

int64_t run_alloc_get_gen_failures(void) {
    return atomic_load_explicit(&run_gen_failure_count, memory_order_relaxed);
}
