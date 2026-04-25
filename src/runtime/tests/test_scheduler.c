#include "../run_scheduler.h"
#include "test_framework.h"

#include <stdatomic.h>
#include <string.h>

/* --- Test helpers --- */

static _Atomic int g_counter = 0;
static _Atomic int multi_p_counter = 0;
static _Atomic int tight_loop_entered = 0;
static _Atomic int tight_loop_stop = 0;
static volatile size_t stack_growth_committed = 0;
static volatile size_t stack_growth_watermark = 0;
static volatile size_t stack_shrink_before = 0;
static volatile size_t stack_shrink_after = 0;

static void increment_fn(void *arg) {
    (void)arg;
    atomic_fetch_add_explicit(&g_counter, 1, memory_order_relaxed);
}

static void increment_by_fn(void *arg) {
    int n = (int)(intptr_t)arg;
    atomic_fetch_add_explicit(&g_counter, n, memory_order_relaxed);
}

static void yield_fn(void *arg) {
    (void)arg;
    atomic_fetch_add_explicit(&g_counter, 1, memory_order_relaxed);
    run_yield();
    atomic_fetch_add_explicit(&g_counter, 1, memory_order_relaxed);
}

static void multi_p_yield_fn(void *arg) {
    (void)arg;
    for (int i = 0; i < 4; i++) {
        atomic_fetch_add_explicit(&multi_p_counter, 1, memory_order_relaxed);
        run_yield();
    }
}

static void tight_loop_fn(void *arg) {
    (void)arg;
    atomic_store_explicit(&tight_loop_entered, 1, memory_order_release);
    while (!atomic_load_explicit(&tight_loop_stop, memory_order_acquire)) {
    }
}

static void stop_tight_loop_fn(void *arg) {
    (void)arg;
    while (!atomic_load_explicit(&tight_loop_entered, memory_order_acquire)) {
        run_yield();
    }
    atomic_store_explicit(&tight_loop_stop, 1, memory_order_release);
}

static void consume_stack(int depth) {
    char probe;
    volatile char buf[2048];
    for (size_t i = 0; i < sizeof(buf); i++) {
        buf[i] = (char)(depth + (int)i);
    }
    run_stack_check(&probe);
    if (depth > 0) {
        consume_stack(depth - 1);
    }
}

static void stack_growth_fn(void *arg) {
    (void)arg;
    consume_stack(32);
    run_g_t *g = run_current_g();
    stack_growth_committed = g->stack_committed;
    stack_growth_watermark = g->stack_watermark;
}

static void stack_shrink_fn(void *arg) {
    (void)arg;
    consume_stack(32);
    run_yield();
    run_g_t *g = run_current_g();
    stack_shrink_before = g->stack_committed;
    run_yield();
    stack_shrink_after = g->stack_committed;
}

/* --- Tests --- */

static void test_scheduler_init(void) {
    /* Scheduler was already initialized by test_main.
     * Just verify we can get the current M. */
    run_m_t *m = run_current_m();
    RUN_ASSERT(m != NULL);
}

static void test_scheduler_maxprocs_config(void) {
    const char *env = getenv("RUN_MAXPROCS");
    int expected = env ? atoi(env) : 1;
    if (expected < 1 || expected > RUN_MAX_P_COUNT) {
        expected = 1;
    }
    RUN_ASSERT_EQ(run_scheduler_get_maxprocs(), expected);
}

static void test_spawn_single(void) {
    atomic_store_explicit(&g_counter, 0, memory_order_relaxed);
    run_spawn(increment_fn, NULL);
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load_explicit(&g_counter, memory_order_relaxed), 1);
}

static void test_spawn_multiple(void) {
    atomic_store_explicit(&g_counter, 0, memory_order_relaxed);
    for (int i = 0; i < 10; i++) {
        run_spawn(increment_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load_explicit(&g_counter, memory_order_relaxed), 10);
}

static void test_spawn_with_arg(void) {
    atomic_store_explicit(&g_counter, 0, memory_order_relaxed);
    run_spawn(increment_by_fn, (void *)(intptr_t)42);
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load_explicit(&g_counter, memory_order_relaxed), 42);
}

static void test_yield(void) {
    atomic_store_explicit(&g_counter, 0, memory_order_relaxed);
    run_spawn(yield_fn, NULL);
    run_spawn(yield_fn, NULL);
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load_explicit(&g_counter, memory_order_relaxed), 4);
}

static void test_spawn_many(void) {
    atomic_store_explicit(&g_counter, 0, memory_order_relaxed);
    for (int i = 0; i < 100; i++) {
        run_spawn(increment_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load_explicit(&g_counter, memory_order_relaxed), 100);
}

static void test_multi_p_progress(void) {
    if (run_scheduler_get_maxprocs() < 2) {
        return;
    }

    atomic_store_explicit(&multi_p_counter, 0, memory_order_relaxed);
    for (int i = 0; i < 64; i++) {
        run_spawn(multi_p_yield_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load_explicit(&multi_p_counter, memory_order_relaxed), 64 * 4);
}

static void test_stack_growth(void) {
    stack_growth_committed = 0;
    stack_growth_watermark = 0;
    run_spawn(stack_growth_fn, NULL);
    run_scheduler_run();
    RUN_ASSERT(stack_growth_committed > 8 * 1024);
    RUN_ASSERT(stack_growth_watermark > 8 * 1024);
}

static void test_stack_shrink(void) {
    stack_shrink_before = 0;
    stack_shrink_after = 0;
    run_spawn(stack_shrink_fn, NULL);
    run_scheduler_run();
    RUN_ASSERT(stack_shrink_before > 8 * 1024);
    RUN_ASSERT(stack_shrink_after < stack_shrink_before);
}

/* --- G Queue Tests --- */

static void test_g_queue_basic(void) {
    run_g_queue_t q;
    run_g_queue_init(&q);
    RUN_ASSERT_EQ(q.len, 0);
    RUN_ASSERT(run_g_queue_pop(&q) == NULL);
}

static void test_g_queue_push_pop(void) {
    run_g_queue_t q;
    run_g_queue_init(&q);

    run_g_t g1 = {.id = 1, .sched_next = NULL};
    run_g_t g2 = {.id = 2, .sched_next = NULL};
    run_g_t g3 = {.id = 3, .sched_next = NULL};

    run_g_queue_push(&q, &g1);
    run_g_queue_push(&q, &g2);
    run_g_queue_push(&q, &g3);
    RUN_ASSERT_EQ(q.len, 3);

    run_g_t *p = run_g_queue_pop(&q);
    RUN_ASSERT(p == &g1);
    RUN_ASSERT_EQ(q.len, 2);

    p = run_g_queue_pop(&q);
    RUN_ASSERT(p == &g2);

    p = run_g_queue_pop(&q);
    RUN_ASSERT(p == &g3);

    p = run_g_queue_pop(&q);
    RUN_ASSERT(p == NULL);
    RUN_ASSERT_EQ(q.len, 0);
}

static void test_g_queue_remove(void) {
    run_g_queue_t q;
    run_g_queue_init(&q);

    run_g_t g1 = {.id = 1, .sched_next = NULL};
    run_g_t g2 = {.id = 2, .sched_next = NULL};
    run_g_t g3 = {.id = 3, .sched_next = NULL};

    run_g_queue_push(&q, &g1);
    run_g_queue_push(&q, &g2);
    run_g_queue_push(&q, &g3);

    /* Remove middle element */
    bool removed = run_g_queue_remove(&q, &g2);
    RUN_ASSERT(removed);
    RUN_ASSERT_EQ(q.len, 2);

    run_g_t *p = run_g_queue_pop(&q);
    RUN_ASSERT(p == &g1);
    p = run_g_queue_pop(&q);
    RUN_ASSERT(p == &g3);
}

static void test_runtime_metrics(void) {
    /* Get baseline metrics */
    run_metrics_t before = run_runtime_metrics();

    /* Spawn a few Gs */
    atomic_store_explicit(&g_counter, 0, memory_order_relaxed);
    int spawn_n = 5;
    for (int i = 0; i < spawn_n; i++) {
        run_spawn(increment_fn, NULL);
    }

    /* Run the scheduler to completion */
    run_scheduler_run();

    /* Verify the Gs actually ran */
    RUN_ASSERT_EQ(atomic_load_explicit(&g_counter, memory_order_relaxed), spawn_n);

    /* Get metrics after */
    run_metrics_t after = run_runtime_metrics();

    /* spawn_count should have increased by exactly spawn_n */
    int64_t spawns = after.spawn_count - before.spawn_count;
    RUN_ASSERT_EQ((int)spawns, spawn_n);

    /* complete_count should have increased by at least spawn_n */
    int64_t completes = after.complete_count - before.complete_count;
    RUN_ASSERT((int)completes >= spawn_n);

    /* context_switches should have increased (at least one per G) */
    int64_t switches = after.context_switches - before.context_switches;
    RUN_ASSERT((int)switches >= spawn_n);
}

static void test_signal_preemption_tight_loop(void) {
#if defined(__linux__) || defined(__APPLE__)
    atomic_store_explicit(&tight_loop_entered, 0, memory_order_relaxed);
    atomic_store_explicit(&tight_loop_stop, 0, memory_order_relaxed);

    run_signal_preemption_start();
    run_spawn(stop_tight_loop_fn, NULL);
    run_spawn(tight_loop_fn, NULL);
    run_scheduler_run();

    RUN_ASSERT_EQ(atomic_load_explicit(&tight_loop_stop, memory_order_relaxed), 1);
#else
    RUN_ASSERT(1);
#endif
}

void run_test_scheduler(void) {
    TEST_SUITE("run_scheduler");
    RUN_TEST(test_scheduler_init);
    RUN_TEST(test_scheduler_maxprocs_config);
    RUN_TEST(test_g_queue_basic);
    RUN_TEST(test_g_queue_push_pop);
    RUN_TEST(test_g_queue_remove);
    RUN_TEST(test_spawn_single);
    RUN_TEST(test_spawn_multiple);
    RUN_TEST(test_spawn_with_arg);
    RUN_TEST(test_yield);
    RUN_TEST(test_spawn_many);
    RUN_TEST(test_multi_p_progress);
    RUN_TEST(test_stack_growth);
    RUN_TEST(test_stack_shrink);
    RUN_TEST(test_runtime_metrics);
    RUN_TEST(test_signal_preemption_tight_loop);
}
