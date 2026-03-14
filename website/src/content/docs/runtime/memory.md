---
title: "Memory Allocation Design"
sidebar:
  order: 3
---


## Overview

Run's memory system provides safety through **generational references** — a lightweight alternative to garbage collection and borrow checking. Every heap allocation carries a generation counter. When memory is freed, the generation is incremented. Any subsequent access through a stale reference detects the mismatch and traps.

The allocator is layered:

```
User code
    │
    ├── run_gen_alloc / run_gen_free / run_gen_check  (generational API)
    │       │
    │       ├── Slab allocator (< 4 KB)               (size-class free lists)
    │       │       │
    │       └── Large allocator (>= 4 KB)              (direct mmap)
    │               │
    │           run_vmem (platform virtual memory)
    │
    ├── run_arena (bump allocator for batch allocation)
    │       │
    │       └── run_vmem
    │
    └── run_allocator_t (custom allocator interface)
```

## Current Implementation

The current allocator (`run_alloc.c`) uses `malloc` with a 16-byte header prepended to every allocation:

```c
typedef struct {
    uint64_t generation;    // incremented on free
    size_t   alloc_size;    // original allocation size
} run_alloc_header_t;
```

- `run_gen_alloc(size)` — `malloc(16 + size)`, zero-init generation and user memory
- `run_gen_free(ptr)` — increment generation, then `free`
- `run_gen_check(ptr, expected_gen)` — compare generation, abort on mismatch
- `run_gen_get(ptr)` — return current generation

This is functional but has limitations: high per-allocation overhead, no thread-local caching, and fragmentation under concurrent workloads.

## Planned: Platform Virtual Memory Layer (`run_vmem`)

A thin abstraction over OS virtual memory primitives.

### API

```c
// Allocate `size` bytes of virtual memory (page-aligned).
// Returns NULL on failure.
void *run_vmem_alloc(size_t size);

// Free `size` bytes starting at `ptr` (must match a previous alloc).
void run_vmem_free(void *ptr, size_t size);

// Change protection on a memory region.
// prot: RUN_VMEM_NONE, RUN_VMEM_READ, RUN_VMEM_READWRITE
void run_vmem_protect(void *ptr, size_t size, int prot);

// Advise the OS that pages can be reclaimed without unmapping.
void run_vmem_release(void *ptr, size_t size);
```

### Platform Implementation

```c
#if defined(__linux__) || defined(__APPLE__)

void *run_vmem_alloc(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return (p == MAP_FAILED) ? NULL : p;
}

void run_vmem_free(void *ptr, size_t size) {
    munmap(ptr, size);
}

void run_vmem_protect(void *ptr, size_t size, int prot) {
    int mp = PROT_NONE;
    if (prot & RUN_VMEM_READ)      mp |= PROT_READ;
    if (prot & RUN_VMEM_READWRITE) mp |= PROT_READ | PROT_WRITE;
    mprotect(ptr, size, mp);
}

void run_vmem_release(void *ptr, size_t size) {
    madvise(ptr, size, MADV_DONTNEED);
}

#elif defined(_WIN32)

void *run_vmem_alloc(size_t size) {
    return VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
}

void run_vmem_free(void *ptr, size_t size) {
    (void)size;
    VirtualFree(ptr, 0, MEM_RELEASE);
}

void run_vmem_protect(void *ptr, size_t size, int prot) {
    DWORD old, np = PAGE_NOACCESS;
    if (prot & RUN_VMEM_READWRITE) np = PAGE_READWRITE;
    else if (prot & RUN_VMEM_READ) np = PAGE_READONLY;
    VirtualProtect(ptr, size, np, &old);
}

void run_vmem_release(void *ptr, size_t size) {
    VirtualFree(ptr, size, MEM_DECOMMIT);
}

#endif
```

## Planned: Slab Allocator

For small allocations (under 4 KB), a size-class slab allocator replaces raw `malloc`:

### Size Classes

| Class | Size (bytes) |
|-------|-------------|
| 0 | 16 |
| 1 | 32 |
| 2 | 64 |
| 3 | 128 |
| 4 | 256 |
| 5 | 512 |
| 6 | 1024 |
| 7 | 2048 |
| 8 | 4096 |

### Design

- Each size class maintains a **free list** of available slots
- Slots are allocated from **slab pages** — 64 KB blocks obtained from `run_vmem`
- Each slab page is divided into fixed-size slots for one size class
- **Thread-local caches** (one per P in the GMP model) hold per-size-class free lists, avoiding lock contention for most allocations
- When a thread-local cache is empty, it refills from a central (locked) free list
- When the central free list is empty, a new slab page is allocated via `run_vmem`

### Generational Header

The generation counter moves from a per-allocation header to slab metadata:

```c
typedef struct {
    uint64_t generation;   // incremented on free
} run_slab_slot_header_t;  // 8 bytes (down from 16)
```

The `alloc_size` is implicit from the size class, saving 8 bytes per allocation.

### Large Allocations

Allocations >= 4 KB bypass the slab allocator and use `run_vmem` directly, with the generation header prepended to the mmap'd region.

## Planned: Arena Allocator (`run_arena`)

A bump-pointer allocator for batch allocation patterns where many allocations share a lifetime.

### API

```c
typedef struct run_arena run_arena_t;

// Create a new arena. block_size is the size of each backing block (default 64 KB).
run_arena_t *run_arena_create(size_t block_size);

// Allocate `size` bytes with `align` alignment from the arena.
// Never fails (aborts on OOM). Memory is zero-initialized.
void *run_arena_alloc(run_arena_t *arena, size_t size, size_t align);

// Reset the arena — reuse all blocks without unmapping.
// All previous allocations are invalidated.
void run_arena_reset(run_arena_t *arena);

// Destroy the arena — munmap all blocks.
void run_arena_destroy(run_arena_t *arena);
```

### Internal Structure

```c
typedef struct run_arena_block {
    struct run_arena_block *next;
    size_t capacity;
    size_t used;
    char data[];   // flexible array member
} run_arena_block_t;

struct run_arena {
    run_arena_block_t *current;
    run_arena_block_t *head;
    size_t block_size;
};
```

Allocation bumps `current->used`. When a block is full, a new block is allocated via `run_vmem` and linked into the list.

### Use Cases

- Per-green-thread scratch allocation (each G gets its own arena)
- Compiler passes (allocate during a pass, free everything after)
- Request-scoped allocation in server programs

## Planned: Custom Allocator Interface (`run_allocator_t`)

A vtable-based allocator interface that allows user code to swap allocators.

```c
typedef struct {
    void *(*alloc)(void *ctx, size_t size, size_t align);
    void (*free)(void *ctx, void *ptr, size_t size);
    void *ctx;
} run_allocator_t;

// The global default allocator (generational slab allocator).
extern run_allocator_t run_default_allocator;
```

In the Run language, `alloc(type, capacity, allocator: my_alloc)` lowers to C code that passes a `run_allocator_t*` parameter to the allocation function.

## Green Thread Stack Allocation

Green thread stacks require special allocation strategies. See [scheduler.md](scheduler.md) for details.

### Phase 1: Fixed-Size Stacks

- Allocate 64 KB via `run_vmem_alloc`
- Mark the bottom page (4 KB) as `PROT_NONE` as a guard page
- Stack overflow hits the guard page, causing SIGSEGV (caught by the runtime for a clean error)

### Phase 2: Growable Stacks

- Reserve 1 MB of address space via `mmap(PROT_NONE)`
- Commit initial 8 KB at the top via `mprotect(PROT_READ|PROT_WRITE)`
- Install a `SIGSEGV` handler that checks if the fault is in a stack guard region
- On stack overflow: commit the next page, resume execution
- Maximum stack size configurable via `RUN_STACK_MAX` environment variable (default 1 MB)
