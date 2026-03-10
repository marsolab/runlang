#include "test_framework.h"
#include "../run_scheduler.h"
#include <string.h>

/* --- Test helpers --- */

static volatile int g_counter = 0;

static void increment_fn(void *arg) {
    (void)arg;
    g_counter++;
}

static void increment_by_fn(void *arg) {
    int n = (int)(intptr_t)arg;
    g_counter += n;
}

static void yield_fn(void *arg) {
    (void)arg;
    g_counter++;
    run_yield();
    g_counter++;
}

/* --- Tests --- */

static void test_scheduler_init(void) {
    /* Scheduler was already initialized by test_main.
     * Just verify we can get the current M. */
    run_m_t *m = run_current_m();
    RUN_ASSERT(m != NULL);
}

static void test_spawn_single(void) {
    g_counter = 0;
    run_spawn(increment_fn, NULL);
    run_scheduler_run();
    RUN_ASSERT_EQ(g_counter, 1);
}

static void test_spawn_multiple(void) {
    g_counter = 0;
    for (int i = 0; i < 10; i++) {
        run_spawn(increment_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(g_counter, 10);
}

static void test_spawn_with_arg(void) {
    g_counter = 0;
    run_spawn(increment_by_fn, (void *)(intptr_t)42);
    run_scheduler_run();
    RUN_ASSERT_EQ(g_counter, 42);
}

static void test_yield(void) {
    g_counter = 0;
    run_spawn(yield_fn, NULL);
    run_spawn(yield_fn, NULL);
    run_scheduler_run();
    RUN_ASSERT_EQ(g_counter, 4);
}

static void test_spawn_many(void) {
    g_counter = 0;
    for (int i = 0; i < 100; i++) {
        run_spawn(increment_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(g_counter, 100);
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

void run_test_scheduler(void) {
    TEST_SUITE("run_scheduler");
    RUN_TEST(test_scheduler_init);
    RUN_TEST(test_g_queue_basic);
    RUN_TEST(test_g_queue_push_pop);
    RUN_TEST(test_g_queue_remove);
    RUN_TEST(test_spawn_single);
    RUN_TEST(test_spawn_multiple);
    RUN_TEST(test_spawn_with_arg);
    RUN_TEST(test_yield);
    RUN_TEST(test_spawn_many);
}
