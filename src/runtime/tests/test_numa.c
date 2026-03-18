#include "test_framework.h"

#include "../run_numa.h"
#include "../run_scheduler.h"

#include <string.h>

/* ---------- Topology Tests ---------- */

static void test_numa_node_count(void) {
    RUN_ASSERT(run_numa_node_count() >= 1);
}

static void test_numa_current_node(void) {
    uint32_t node = run_numa_current_node();
    RUN_ASSERT(node < run_numa_node_count());
}

static void test_numa_cpus_on_node(void) {
    uint32_t count = 0;
    const uint32_t *cpus = run_numa_cpus_on_node(0, &count);
    RUN_ASSERT(cpus != NULL);
    RUN_ASSERT(count > 0);
}

static void test_numa_cpus_on_node_invalid(void) {
    uint32_t count = 99;
    const uint32_t *cpus = run_numa_cpus_on_node(9999, &count);
    RUN_ASSERT(cpus == NULL);
    RUN_ASSERT_EQ(count, 0);
}

static void test_numa_distance_self(void) {
    uint32_t d = run_numa_distance(0, 0);
    RUN_ASSERT_EQ(d, 10);
}

static void test_numa_distance_invalid(void) {
    uint32_t d = run_numa_distance(9999, 0);
    RUN_ASSERT_EQ(d, 0);
}

static void test_numa_distance_symmetric(void) {
    if (run_numa_node_count() < 2)
        return; /* Skip on UMA */
    uint32_t d01 = run_numa_distance(0, 1);
    uint32_t d10 = run_numa_distance(1, 0);
    RUN_ASSERT_EQ(d01, d10);
}

/* ---------- Allocation Tests ---------- */

static void test_numa_alloc_on_node(void) {
    void *p = run_numa_alloc_on_node(4096, 0);
    RUN_ASSERT(p != NULL);
    memset(p, 0xAB, 4096); /* Verify accessible */
    RUN_ASSERT(((unsigned char *)p)[0] == 0xAB);
    run_numa_free(p, 4096);
}

static void test_numa_allocator_vtable(void) {
    run_allocator_t a = run_numa_allocator(0);
    RUN_ASSERT(a.alloc_fn != NULL);
    RUN_ASSERT(a.free_fn != NULL);
    void *p = a.alloc_fn(a.ctx, 4096);
    RUN_ASSERT(p != NULL);
    memset(p, 0xCD, 4096);
    a.free_fn(a.ctx, p, 4096);
}

/* ---------- Extended API Tests ---------- */

static void test_numa_available(void) {
    bool avail = run_numa_available();
    RUN_ASSERT(avail == (run_numa_node_count() > 1));
}

static void test_numa_preferred_node_default(void) {
    /* Outside green thread context, should return -1 */
    int32_t node = run_numa_preferred_node();
    RUN_ASSERT_EQ(node, -1);
}

static void test_numa_local_alloc(void) {
    void *p = run_numa_local_alloc(4096);
    RUN_ASSERT(p != NULL);
    memset(p, 0xEF, 4096);
    RUN_ASSERT(((unsigned char *)p)[0] == 0xEF);
    run_numa_free(p, 4096);
}

static void test_numa_node_alloc(void) {
    void *p = run_numa_node_alloc(0, 4096);
    RUN_ASSERT(p != NULL);
    memset(p, 0xDC, 4096);
    RUN_ASSERT(((unsigned char *)p)[0] == 0xDC);
    run_numa_free(p, 4096);
}

static void test_numa_interleave_alloc(void) {
    void *p1 = run_numa_interleave_alloc(4096);
    void *p2 = run_numa_interleave_alloc(4096);
    RUN_ASSERT(p1 != NULL);
    RUN_ASSERT(p2 != NULL);
    run_numa_free(p1, 4096);
    run_numa_free(p2, 4096);
}

static void test_numa_bind_thread_valid(void) {
    int ret = run_numa_bind_thread(0);
    RUN_ASSERT_EQ(ret, 0);
}

static void test_numa_bind_thread_invalid(void) {
    int ret = run_numa_bind_thread(9999);
    /* On macOS, bind_thread is a no-op (returns 0).
     * On Linux/Windows, invalid node returns -1. */
#if defined(__APPLE__)
    RUN_ASSERT_EQ(ret, 0);
#else
    RUN_ASSERT_EQ(ret, -1);
#endif
}

static void test_numa_cpu_count_valid(void) {
    uint32_t count = run_numa_cpu_count(0);
    RUN_ASSERT(count > 0);
}

static void test_numa_cpu_count_invalid(void) {
    uint32_t count = run_numa_cpu_count(9999);
    RUN_ASSERT_EQ(count, 0);
}

static void test_numa_set_memory_policy_local(void) {
    int ret = run_numa_set_memory_policy(RUN_NUMA_POLICY_LOCAL, 0);
    RUN_ASSERT_EQ(ret, 0);
}

/* ---------- Scheduler Integration Tests ---------- */

static volatile int numa_spawn_counter = 0;

static void numa_increment_fn(void *arg) {
    (void)arg;
    numa_spawn_counter++;
}

static void test_numa_spawn_on_node(void) {
    numa_spawn_counter = 0;
    run_spawn_on_node(numa_increment_fn, NULL, 0);
    run_scheduler_run();
    RUN_ASSERT_EQ(numa_spawn_counter, 1);
}

static void test_numa_spawn_no_preference(void) {
    numa_spawn_counter = 0;
    run_spawn_on_node(numa_increment_fn, NULL, -1);
    run_scheduler_run();
    RUN_ASSERT_EQ(numa_spawn_counter, 1);
}

/* ---------- Test Suite ---------- */

void run_test_numa(void) {
    TEST_SUITE("run_numa");

    /* Topology */
    RUN_TEST(test_numa_node_count);
    RUN_TEST(test_numa_current_node);
    RUN_TEST(test_numa_cpus_on_node);
    RUN_TEST(test_numa_cpus_on_node_invalid);
    RUN_TEST(test_numa_distance_self);
    RUN_TEST(test_numa_distance_invalid);
    RUN_TEST(test_numa_distance_symmetric);

    /* Allocation */
    RUN_TEST(test_numa_alloc_on_node);
    RUN_TEST(test_numa_allocator_vtable);

    /* Extended API */
    RUN_TEST(test_numa_available);
    RUN_TEST(test_numa_preferred_node_default);
    RUN_TEST(test_numa_local_alloc);
    RUN_TEST(test_numa_node_alloc);
    RUN_TEST(test_numa_interleave_alloc);
    RUN_TEST(test_numa_bind_thread_valid);
    RUN_TEST(test_numa_bind_thread_invalid);
    RUN_TEST(test_numa_cpu_count_valid);
    RUN_TEST(test_numa_cpu_count_invalid);
    RUN_TEST(test_numa_set_memory_policy_local);

    /* Scheduler integration */
    RUN_TEST(test_numa_spawn_on_node);
    RUN_TEST(test_numa_spawn_no_preference);
}
