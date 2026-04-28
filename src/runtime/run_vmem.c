#include "run_vmem.h"

#include <stdio.h>
#include <stdlib.h>

#if defined(__linux__) || defined(__APPLE__)

#include <sys/mman.h>
#include <unistd.h>

void *run_vmem_alloc(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return (p == MAP_FAILED) ? NULL : p;
}

void *run_vmem_reserve(size_t size) {
    void *p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return (p == MAP_FAILED) ? NULL : p;
}

void run_vmem_free(void *ptr, size_t size) {
    munmap(ptr, size);
}

void run_vmem_protect(void *ptr, size_t size, int prot) {
    int mp = PROT_NONE;
    if (prot & RUN_VMEM_READ)
        mp |= PROT_READ;
    if (prot & RUN_VMEM_READWRITE)
        mp |= PROT_READ | PROT_WRITE;
    mprotect(ptr, size, mp);
}

void run_vmem_release(void *ptr, size_t size) {
#if defined(__APPLE__)
    madvise(ptr, size, MADV_FREE);
#else
    madvise(ptr, size, MADV_DONTNEED);
#endif
}

size_t run_vmem_page_size(void) {
    return (size_t)sysconf(_SC_PAGESIZE);
}

#elif defined(_WIN32)

#include <windows.h>

void *run_vmem_alloc(size_t size) {
    return VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
}

void *run_vmem_reserve(size_t size) {
    return VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_NOACCESS);
}

void run_vmem_free(void *ptr, size_t size) {
    (void)size;
    VirtualFree(ptr, 0, MEM_RELEASE);
}

void run_vmem_protect(void *ptr, size_t size, int prot) {
    DWORD old, np = PAGE_NOACCESS;
    if (prot & RUN_VMEM_READWRITE)
        np = PAGE_READWRITE;
    else if (prot & RUN_VMEM_READ)
        np = PAGE_READONLY;

    if (np != PAGE_NOACCESS) {
        if (VirtualAlloc(ptr, size, MEM_COMMIT, np) != NULL)
            return;
    }

    VirtualProtect(ptr, size, np, &old);
}

void run_vmem_release(void *ptr, size_t size) {
    VirtualFree(ptr, size, MEM_DECOMMIT);
}

size_t run_vmem_page_size(void) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
}

#elif defined(__wasi__)

void *run_vmem_alloc(size_t size) {
    return malloc(size);
}

void *run_vmem_reserve(size_t size) {
    return malloc(size);
}

void run_vmem_free(void *ptr, size_t size) {
    (void)size;
    free(ptr);
}

void run_vmem_protect(void *ptr, size_t size, int prot) {
    (void)ptr;
    (void)size;
    (void)prot;
}

void run_vmem_release(void *ptr, size_t size) {
    (void)ptr;
    (void)size;
}

size_t run_vmem_page_size(void) {
    return 64 * 1024;
}

#endif
