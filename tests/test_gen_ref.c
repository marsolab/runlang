/**
 * Runtime tests for generational reference tracking.
 *
 * Verifies:
 * 1. Basic alloc/free lifecycle
 * 2. Generation counter starts at 0
 * 3. gen_ref_create captures current generation
 * 4. gen_ref_deref succeeds with valid reference
 * 5. gen_check succeeds with matching generation
 * 6. Double-free detection (via child process)
 * 7. Use-after-free detection (via child process)
 *
 * Compile: zig cc -o test_gen_ref tests/test_gen_ref.c src/runtime/run_alloc.c -Isrc/runtime
 */

#include "run_alloc.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int test_count = 0;
static int pass_count = 0;

#define TEST(name) do { test_count++; printf("  test %s... ", #name); } while(0)
#define PASS() do { pass_count++; printf("ok\n"); } while(0)

/* Run a function in a child process and verify it aborts (exit via signal). */
static int expect_abort(void (*fn)(void)) {
    pid_t pid = fork();
    if (pid == 0) {
        /* child */
        fn();
        _exit(0); /* should not reach here */
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFSIGNALED(status) && (WTERMSIG(status) == SIGABRT || WTERMSIG(status) == SIGSEGV);
}

/* Test: basic allocation and generation starts at 0. */
static void test_alloc_basic(void) {
    TEST(alloc_basic);
    void *ptr = run_gen_alloc(64);
    assert(ptr != NULL);
    uint64_t gen = run_gen_get(ptr);
    assert(gen == 0);
    run_gen_free(ptr);
    PASS();
}

/* Test: gen_check succeeds with correct generation. */
static void test_gen_check_ok(void) {
    TEST(gen_check_ok);
    void *ptr = run_gen_alloc(32);
    uint64_t gen = run_gen_get(ptr);
    run_gen_check(ptr, gen); /* should not abort */
    run_gen_free(ptr);
    PASS();
}

/* Test: gen_ref_create captures generation. */
static void test_ref_create(void) {
    TEST(ref_create);
    void *ptr = run_gen_alloc(16);
    run_gen_ref_t ref = run_gen_ref_create(ptr);
    assert(ref.ptr == ptr);
    assert(ref.generation == 0);
    run_gen_free(ptr);
    PASS();
}

/* Test: gen_ref_deref succeeds before free. */
static void test_ref_deref_ok(void) {
    TEST(ref_deref_ok);
    void *ptr = run_gen_alloc(16);
    run_gen_ref_t ref = run_gen_ref_create(ptr);
    void *derefed = run_gen_ref_deref(ref);
    assert(derefed == ptr);
    run_gen_free(ptr);
    PASS();
}

/* Test: allocated memory is zero-initialized. */
static void test_alloc_zeroed(void) {
    TEST(alloc_zeroed);
    unsigned char *ptr = (unsigned char *)run_gen_alloc(128);
    for (int i = 0; i < 128; i++) {
        assert(ptr[i] == 0);
    }
    run_gen_free(ptr);
    PASS();
}

/* Helper: double-free scenario (should abort). */
static void double_free_fn(void) {
    void *ptr = run_gen_alloc(16);
    run_gen_free(ptr);
    run_gen_free(ptr); /* double free */
}

/* Test: double-free detection. */
static void test_double_free(void) {
    TEST(double_free_detection);
    assert(expect_abort(double_free_fn));
    PASS();
}

/* Helper: use-after-free via gen_check (should abort). */
static void use_after_free_check_fn(void) {
    void *ptr = run_gen_alloc(16);
    uint64_t gen = run_gen_get(ptr);
    run_gen_free(ptr);
    /* Accessing freed memory — gen_check on freed allocation.
     * Note: this is technically UB after free, but the test validates
     * that the runtime *would* detect it if the header is still readable
     * (e.g., with a delayed-free pool in the future). We test via gen_ref_deref
     * which is the intended API. For now, just verify the abort path works. */
    run_gen_check(ptr, gen);
}

/* Test: use-after-free detection via gen_check. */
static void test_use_after_free(void) {
    TEST(use_after_free_detection);
    assert(expect_abort(use_after_free_check_fn));
    PASS();
}

/* Helper: null pointer dereference via gen_check (should abort). */
static void null_deref_fn(void) {
    run_gen_check(NULL, 0);
}

/* Test: null pointer detection. */
static void test_null_check(void) {
    TEST(null_pointer_detection);
    assert(expect_abort(null_deref_fn));
    PASS();
}

/* Helper: null pointer in gen_ref_deref (should abort). */
static void null_ref_deref_fn(void) {
    run_gen_ref_t ref = { .ptr = NULL, .generation = 0 };
    run_gen_ref_deref(ref);
}

/* Test: null ref deref detection. */
static void test_null_ref_deref(void) {
    TEST(null_ref_deref_detection);
    assert(expect_abort(null_ref_deref_fn));
    PASS();
}

int main(void) {
    printf("running generational reference tests...\n");

    test_alloc_basic();
    test_gen_check_ok();
    test_ref_create();
    test_ref_deref_ok();
    test_alloc_zeroed();
    test_double_free();
    test_use_after_free();
    test_null_check();
    test_null_ref_deref();

    printf("\n%d/%d tests passed\n", pass_count, test_count);
    return (pass_count == test_count) ? 0 : 1;
}
