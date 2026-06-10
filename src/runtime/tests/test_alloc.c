#include "../run_alloc.h"
#include "test_framework.h"

#include <stdint.h>
#include <string.h>

#ifndef _WIN32
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

/* Run `fn` in a child process and report whether it aborted. */
static int expect_abort(void (*fn)(void)) {
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        /* Child: silence the runtime's abort message. */
        freopen("/dev/null", "w", stderr);
        fn();
        _exit(0); /* not reached if fn aborts */
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}
#endif

static void test_alloc_zeroed_and_valid(void) {
    unsigned char *p = (unsigned char *)run_gen_alloc(128);
    RUN_ASSERT(p != NULL);
    for (int i = 0; i < 128; i++) {
        RUN_ASSERT_EQ(p[i], 0);
    }
    run_gen_check(p, run_gen_get(p)); /* must not abort */
    run_gen_free(p);
}

static void test_generations_unique(void) {
    void *a = run_gen_alloc(32);
    void *b = run_gen_alloc(32);
    RUN_ASSERT(run_gen_get(a) != run_gen_get(b));
    RUN_ASSERT(run_gen_get(a) != RUN_GEN_FREED);
    RUN_ASSERT(run_gen_get(b) != RUN_GEN_FREED);
    /* Generation 0 is reserved for null references. */
    RUN_ASSERT(run_gen_get(a) != 0);
    RUN_ASSERT(run_gen_get(b) != 0);
    run_gen_free(a);
    run_gen_free(b);
}

static void test_freed_generation_readable(void) {
    void *p = run_gen_alloc(64);
    run_gen_free(p);
    /* The block is quarantined, so the header stays readable and reports
     * the freed sentinel instead of garbage. */
    RUN_ASSERT(run_gen_get(p) == RUN_GEN_FREED);
}

static void test_recycled_address_gets_new_generation(void) {
    void *p1 = run_gen_alloc(48);
    uint64_t gen1 = run_gen_get(p1);
    run_gen_free(p1);

    /* Same size class, so the freelist hands back the same block. */
    void *p2 = run_gen_alloc(48);
    RUN_ASSERT(p2 == p1);
    RUN_ASSERT(run_gen_get(p2) != gen1);
    RUN_ASSERT(run_gen_get(p2) != RUN_GEN_FREED);
    run_gen_free(p2);
}

static void test_recycled_block_zeroed(void) {
    unsigned char *p1 = (unsigned char *)run_gen_alloc(64);
    memset(p1, 0xAB, 64);
    run_gen_free(p1);

    unsigned char *p2 = (unsigned char *)run_gen_alloc(64);
    for (int i = 0; i < 64; i++) {
        RUN_ASSERT_EQ(p2[i], 0);
    }
    run_gen_free(p2);
}

static void test_large_alloc_roundtrip(void) {
    /* Bigger than the largest size class (1 MiB). */
    const size_t big = (size_t)3 * 1024 * 1024;
    unsigned char *p = (unsigned char *)run_gen_alloc(big);
    RUN_ASSERT(p != NULL);
    p[0] = 1;
    p[big - 1] = 2;
    uint64_t gen = run_gen_get(p);
    run_gen_free(p);

    unsigned char *q = (unsigned char *)run_gen_alloc(big);
    RUN_ASSERT(q == p); /* recycled from the large free list */
    RUN_ASSERT(run_gen_get(q) != gen);
    RUN_ASSERT_EQ(q[0], 0);
    RUN_ASSERT_EQ(q[big - 1], 0);
    run_gen_free(q);
}

static void test_aligned_alloc(void) {
    void *p = run_gen_alloc_aligned(40, 64);
    RUN_ASSERT(((uintptr_t)p & 63) == 0);
    run_gen_free(p);
    void *q = run_gen_alloc_aligned(40, 64);
    RUN_ASSERT(((uintptr_t)q & 63) == 0);
    run_gen_free(q);
}

static void test_ref_create_and_deref(void) {
    void *p = run_gen_alloc(16);
    run_gen_ref_t ref = run_gen_ref_create(p);
    RUN_ASSERT(ref.ptr == p);
    RUN_ASSERT(ref.generation == run_gen_get(p));
    RUN_ASSERT(run_gen_ref_deref(ref) == p);
    run_gen_free(p);
}

#ifndef _WIN32
static void uaf_check_fn(void) {
    void *p = run_gen_alloc(16);
    uint64_t gen = run_gen_get(p);
    run_gen_free(p);
    run_gen_check(p, gen); /* must abort: freed */
}

static void test_use_after_free_aborts(void) {
    RUN_ASSERT(expect_abort(uaf_check_fn));
}

static void stale_ref_after_recycle_fn(void) {
    void *p1 = run_gen_alloc(24);
    run_gen_ref_t stale = run_gen_ref_create(p1);
    run_gen_free(p1);
    void *p2 = run_gen_alloc(24); /* recycles the same address */
    (void)p2;
    run_gen_ref_deref(stale); /* must abort: generation mismatch */
}

static void test_stale_ref_after_recycle_aborts(void) {
    RUN_ASSERT(expect_abort(stale_ref_after_recycle_fn));
}

static void double_free_fn(void) {
    void *p = run_gen_alloc(16);
    run_gen_free(p);
    run_gen_free(p); /* must abort */
}

static void test_double_free_aborts(void) {
    RUN_ASSERT(expect_abort(double_free_fn));
}

static void null_check_fn(void) {
    run_gen_check(NULL, 0); /* must abort */
}

static void test_null_check_aborts(void) {
    RUN_ASSERT(expect_abort(null_check_fn));
}
#endif

void run_test_alloc(void) {
    printf("\n=== alloc ===\n");
    RUN_TEST(test_alloc_zeroed_and_valid);
    RUN_TEST(test_generations_unique);
    RUN_TEST(test_freed_generation_readable);
    RUN_TEST(test_recycled_address_gets_new_generation);
    RUN_TEST(test_recycled_block_zeroed);
    RUN_TEST(test_large_alloc_roundtrip);
    RUN_TEST(test_aligned_alloc);
    RUN_TEST(test_ref_create_and_deref);
#ifndef _WIN32
    RUN_TEST(test_use_after_free_aborts);
    RUN_TEST(test_stale_ref_after_recycle_aborts);
    RUN_TEST(test_double_free_aborts);
    RUN_TEST(test_null_check_aborts);
#endif
}
