#include "test_framework.h"
#include "../run_vmem.h"
#include <string.h>

static void test_vmem_alloc_free(void) {
    void *p = run_vmem_alloc(4096);
    RUN_ASSERT(p != NULL);
    /* Write to the memory to verify it's accessible */
    memset(p, 0xAB, 4096);
    run_vmem_free(p, 4096);
}

static void test_vmem_reserve_protect(void) {
    size_t size = 64 * 1024; /* 64 KB */
    void *p = run_vmem_reserve(size);
    RUN_ASSERT(p != NULL);
    /* Memory should be reserved but not accessible.
     * Commit the first page */
    run_vmem_protect(p, 4096, RUN_VMEM_READWRITE);
    memset(p, 0xCD, 4096);
    run_vmem_free(p, size);
}

static void test_vmem_page_size(void) {
    size_t ps = run_vmem_page_size();
    RUN_ASSERT(ps > 0);
    RUN_ASSERT(ps >= 4096); /* Most systems use at least 4KB pages */
}

static void test_vmem_large_alloc(void) {
    size_t size = 1024 * 1024; /* 1 MB */
    void *p = run_vmem_alloc(size);
    RUN_ASSERT(p != NULL);
    /* Write first and last byte */
    ((char *)p)[0] = 1;
    ((char *)p)[size - 1] = 2;
    RUN_ASSERT(((char *)p)[0] == 1);
    RUN_ASSERT(((char *)p)[size - 1] == 2);
    run_vmem_free(p, size);
}

void run_test_vmem(void) {
    TEST_SUITE("run_vmem");
    RUN_TEST(test_vmem_alloc_free);
    RUN_TEST(test_vmem_reserve_protect);
    RUN_TEST(test_vmem_page_size);
    RUN_TEST(test_vmem_large_alloc);
}
