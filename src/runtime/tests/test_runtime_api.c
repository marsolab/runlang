#include "test_framework.h"
#include "../run_runtime_api.h"
#include "../run_alloc.h"

#include <string.h>

static void test_runtime_num_cpu(void) {
    int64_t n = run_runtime_num_cpu();
    RUN_ASSERT(n >= 1);
}

static void test_runtime_num_goroutine(void) {
    /* Scheduler is initialized but no goroutines spawned in test context */
    int64_t n = run_runtime_num_goroutine();
    RUN_ASSERT(n >= 0);
}

static void test_runtime_gomaxprocs_get(void) {
    /* n < 1 returns current value without changing it */
    int64_t prev = run_runtime_gomaxprocs(0);
    RUN_ASSERT(prev >= 1);
}

static void test_runtime_gomaxprocs_set(void) {
    int64_t prev = run_runtime_gomaxprocs(4);
    RUN_ASSERT(prev >= 1);
    int64_t curr = run_runtime_gomaxprocs(0);
    RUN_ASSERT_EQ(curr, 4);
    /* Restore */
    run_runtime_gomaxprocs((int64_t)prev);
}

static void test_runtime_mem_stats(void) {
    /* Allocate and free to get non-zero stats */
    void *p = run_gen_alloc(64);
    run_gen_free(p);

    run_mem_stats_t stats = run_runtime_mem_stats();
    RUN_ASSERT(stats.alloc_count > 0);
    RUN_ASSERT(stats.free_count > 0);
    RUN_ASSERT(stats.bytes_allocated > 0);
    RUN_ASSERT(stats.bytes_freed > 0);
}

static void test_runtime_version(void) {
    run_string_t v = run_runtime_version();
    RUN_ASSERT(v.len > 0);
    RUN_ASSERT(v.ptr != NULL);
}

static void test_runtime_gc_disable_enable(void) {
    run_runtime_gc_disable();
    run_runtime_gc_enable();
    /* If we get here without crashing, it works */
    RUN_ASSERT(1);
}

static void test_runtime_yield(void) {
    /* Should not crash even without an active scheduler loop */
    run_runtime_yield();
    RUN_ASSERT(1);
}

static void test_runtime_caller(void) {
    run_caller_info_t info = run_runtime_caller(0);
    /* On test platforms with backtrace support, ok should be true */
    /* On unsupported platforms, ok will be false — both are acceptable */
    RUN_ASSERT(info.line >= 0);
}

static void test_runtime_stack(void) {
    run_string_t s = run_runtime_stack();
    RUN_ASSERT(s.ptr != NULL);
    RUN_ASSERT(s.len > 0);
}

void run_test_runtime_api(void) {
    TEST_SUITE("runtime_api");
    RUN_TEST(test_runtime_num_cpu);
    RUN_TEST(test_runtime_num_goroutine);
    RUN_TEST(test_runtime_gomaxprocs_get);
    RUN_TEST(test_runtime_gomaxprocs_set);
    RUN_TEST(test_runtime_mem_stats);
    RUN_TEST(test_runtime_version);
    RUN_TEST(test_runtime_gc_disable_enable);
    RUN_TEST(test_runtime_yield);
    RUN_TEST(test_runtime_caller);
    RUN_TEST(test_runtime_stack);
}
