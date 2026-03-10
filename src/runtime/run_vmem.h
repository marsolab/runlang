#ifndef RUN_VMEM_H
#define RUN_VMEM_H

#include <stddef.h>

/* Protection flags for run_vmem_protect. */
#define RUN_VMEM_NONE      0
#define RUN_VMEM_READ      1
#define RUN_VMEM_READWRITE 3

/* Allocate `size` bytes of virtual memory (page-aligned, read-write).
 * Returns NULL on failure. */
void *run_vmem_alloc(size_t size);

/* Reserve `size` bytes of virtual address space without committing.
 * Memory is not accessible until committed via run_vmem_protect.
 * Returns NULL on failure. */
void *run_vmem_reserve(size_t size);

/* Free `size` bytes starting at `ptr`. Must match a previous alloc/reserve. */
void run_vmem_free(void *ptr, size_t size);

/* Change protection on a memory region. `prot` is RUN_VMEM_* flags. */
void run_vmem_protect(void *ptr, size_t size, int prot);

/* Advise the OS that pages can be reclaimed without unmapping. */
void run_vmem_release(void *ptr, size_t size);

/* Return the system page size. */
size_t run_vmem_page_size(void);

#endif
