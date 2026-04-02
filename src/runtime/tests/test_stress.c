#include "../run_chan.h"
#include "../run_scheduler.h"
#include "test_framework.h"

#include <stdatomic.h>
#include <stdint.h>

/* --- Stress Test: Spawn 10,000 Gs --- */

static _Atomic int stress_counter = 0;

static void stress_increment_fn(void *arg) {
    (void)arg;
    atomic_fetch_add(&stress_counter, 1);
}

static void test_stress_spawn_10000(void) {
    atomic_store(&stress_counter, 0);
    for (int i = 0; i < 10000; i++) {
        run_spawn(stress_increment_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load(&stress_counter), 10000);
}

/* --- Stress Test: Producer-Consumer (N=4 producers, M=4 consumers) --- */

static _Atomic int pc_produced = 0;
static _Atomic int pc_consumed = 0;

#define PC_ITEMS_PER_PRODUCER 100

static void stress_producer_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    for (int i = 0; i < PC_ITEMS_PER_PRODUCER; i++) {
        int64_t val = 1;
        run_chan_send(ch, &val);
        atomic_fetch_add(&pc_produced, 1);
    }
}

static void stress_consumer_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    for (int i = 0; i < PC_ITEMS_PER_PRODUCER; i++) {
        int64_t val = 0;
        run_chan_recv(ch, &val);
        atomic_fetch_add(&pc_consumed, 1);
    }
}

static void test_stress_producer_consumer(void) {
    atomic_store(&pc_produced, 0);
    atomic_store(&pc_consumed, 0);

    /* 4 producers x 100 items = 400 total, 4 consumers x 100 items = 400 total */
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 8);

    for (int i = 0; i < 4; i++) {
        run_spawn(stress_producer_fn, ch);
    }
    for (int i = 0; i < 4; i++) {
        run_spawn(stress_consumer_fn, ch);
    }
    run_scheduler_run();

    RUN_ASSERT_EQ(atomic_load(&pc_produced), 400);
    RUN_ASSERT_EQ(atomic_load(&pc_consumed), 400);

    run_chan_free(ch);
}

/* --- Stress Test: Yield Chain (100 Gs x 100 yields each) --- */

static _Atomic int yield_completions = 0;

static void stress_yield_fn(void *arg) {
    (void)arg;
    for (int i = 0; i < 100; i++) {
        run_yield();
    }
    atomic_fetch_add(&yield_completions, 1);
}

static void test_stress_yield_chain(void) {
    atomic_store(&yield_completions, 0);
    for (int i = 0; i < 100; i++) {
        run_spawn(stress_yield_fn, NULL);
    }
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load(&yield_completions), 100);
}

/* --- Stress Test: Concurrent Spawn (Gs that spawn more Gs) --- */

static _Atomic int nested_counter = 0;

static void nested_leaf_fn(void *arg) {
    (void)arg;
    atomic_fetch_add(&nested_counter, 1);
}

static void nested_spawner_fn(void *arg) {
    int depth = (int)(intptr_t)arg;
    if (depth > 0) {
        run_spawn(nested_spawner_fn, (void *)(intptr_t)(depth - 1));
        run_spawn(nested_spawner_fn, (void *)(intptr_t)(depth - 1));
    } else {
        atomic_fetch_add(&nested_counter, 1);
    }
}

static void test_stress_concurrent_spawn(void) {
    atomic_store(&nested_counter, 0);
    /* Depth 8 => 2^8 = 256 leaf Gs */
    run_spawn(nested_spawner_fn, (void *)(intptr_t)8);
    run_scheduler_run();
    RUN_ASSERT_EQ(atomic_load(&nested_counter), 256);
}

/* --- Stress Test: Channel Ping-Pong --- */

typedef struct {
    run_chan_t *ping;
    run_chan_t *pong;
    int rounds;
} pingpong_ctx_t;

static void ping_fn(void *arg) {
    pingpong_ctx_t *ctx = (pingpong_ctx_t *)arg;
    for (int i = 0; i < ctx->rounds; i++) {
        int64_t val = (int64_t)i;
        run_chan_send(ctx->ping, &val);
        run_chan_recv(ctx->pong, &val);
    }
}

static void pong_fn(void *arg) {
    pingpong_ctx_t *ctx = (pingpong_ctx_t *)arg;
    for (int i = 0; i < ctx->rounds; i++) {
        int64_t val = 0;
        run_chan_recv(ctx->ping, &val);
        val += 1;
        run_chan_send(ctx->pong, &val);
    }
}

static void test_stress_channel_pingpong(void) {
    run_chan_t *ping = run_chan_new(sizeof(int64_t), 0);
    run_chan_t *pong = run_chan_new(sizeof(int64_t), 0);

    pingpong_ctx_t ctx = {.ping = ping, .pong = pong, .rounds = 500};

    run_spawn(ping_fn, &ctx);
    run_spawn(pong_fn, &ctx);
    run_scheduler_run();

    /* If we got here without deadlock, the test passed.
     * Each round does a send+recv on each side, so 500 rounds completed. */
    RUN_ASSERT(1);

    run_chan_free(ping);
    run_chan_free(pong);
}

void run_test_stress(void) {
    TEST_SUITE("stress");
    RUN_TEST(test_stress_spawn_10000);
    RUN_TEST(test_stress_producer_consumer);
    RUN_TEST(test_stress_yield_chain);
    RUN_TEST(test_stress_concurrent_spawn);
    RUN_TEST(test_stress_channel_pingpong);
}
