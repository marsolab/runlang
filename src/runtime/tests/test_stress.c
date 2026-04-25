#include "../run_chan.h"
#include "../run_poller.h"
#include "../run_scheduler.h"
#include "test_framework.h"

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

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

/* --- Stress Test: Work stealing under asymmetric load --- */

#define STEAL_STRESS_GS 1024
#define STEAL_STRESS_SPINS 256

static _Atomic int steal_total = 0;
static _Atomic int steal_hits[RUN_MAX_P_COUNT];

static bool stress_strict_multip(void) {
    const char *env = getenv("RUN_STRESS_MULTIP");
    return env != NULL && env[0] == '1';
}

static void reset_steal_hits(void) {
    for (uint32_t i = 0; i < RUN_MAX_P_COUNT; i++) {
        atomic_store(&steal_hits[i], 0);
    }
}

static int count_active_ps(void) {
    int active = 0;
    for (uint32_t i = 0; i < RUN_MAX_P_COUNT; i++) {
        if (atomic_load(&steal_hits[i]) > 0) {
            active++;
        }
    }
    return active;
}

static void steal_record_fn(void *arg) {
    int spins = (int)(intptr_t)arg;
    run_m_t *m = run_current_m();
    if (m != NULL && m->current_p != NULL && m->current_p->id < RUN_MAX_P_COUNT) {
        atomic_fetch_add(&steal_hits[m->current_p->id], 1);
    }
    for (int i = 0; i < spins; i++) {
        run_yield();
    }
    atomic_fetch_add(&steal_total, 1);
}

static void test_stress_work_stealing_asymmetric(void) {
    atomic_store(&steal_total, 0);
    reset_steal_hits();

    for (int i = 0; i < STEAL_STRESS_GS; i++) {
        run_spawn(steal_record_fn, (void *)(intptr_t)STEAL_STRESS_SPINS);
    }
    run_scheduler_run();

    RUN_ASSERT_EQ(atomic_load(&steal_total), STEAL_STRESS_GS);

    if (run_scheduler_get_maxprocs() > 1 && stress_strict_multip()) {
        RUN_ASSERT(count_active_ps() >= 2);
    }
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

/* --- Stress Test: Tight-loop preemption/progress --- */

static _Atomic int preempt_started = 0;
static _Atomic int preempt_tight_done = 0;
static _Atomic int preempt_observer_done = 0;
static _Atomic int preempt_observed_progress = 0;
static _Atomic uint64_t preempt_sink = 0;

static bool stress_strict_preempt(void) {
    const char *env = getenv("RUN_STRESS_PREEMPT");
    return env != NULL && env[0] == '1';
}

static void tight_loop_fn(void *arg) {
    int loops = (int)(intptr_t)arg;
    uint64_t acc = 0;
    atomic_fetch_add(&preempt_started, 1);
    for (int i = 0; i < loops; i++) {
        acc += ((uint64_t)i * 1103515245u) ^ (acc >> 7);
    }
    atomic_fetch_xor(&preempt_sink, acc);
    atomic_fetch_add(&preempt_tight_done, 1);
}

static void preempt_observer_fn(void *arg) {
    int expected_tight = (int)(intptr_t)arg;
    while (atomic_load(&preempt_tight_done) < expected_tight) {
        atomic_fetch_add(&preempt_observed_progress, 1);
        run_yield();
        if (atomic_load(&preempt_observed_progress) > 1024) {
            break;
        }
    }
    atomic_store(&preempt_observer_done, 1);
}

static void test_stress_tight_loop_preemption(void) {
    uint32_t maxprocs = run_scheduler_get_maxprocs();
    int tight_count = maxprocs > 1 ? (int)maxprocs : 1;

    atomic_store(&preempt_started, 0);
    atomic_store(&preempt_tight_done, 0);
    atomic_store(&preempt_observer_done, 0);
    atomic_store(&preempt_observed_progress, 0);

    run_spawn(preempt_observer_fn, (void *)(intptr_t)tight_count);
    for (int i = 0; i < tight_count; i++) {
        run_spawn(tight_loop_fn, (void *)(intptr_t)2000000);
    }
    run_scheduler_run();

    RUN_ASSERT_EQ(atomic_load(&preempt_started), tight_count);
    RUN_ASSERT_EQ(atomic_load(&preempt_tight_done), tight_count);
    RUN_ASSERT_EQ(atomic_load(&preempt_observer_done), 1);

    if (stress_strict_preempt()) {
        RUN_ASSERT(atomic_load(&preempt_observed_progress) > 0);
    }
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

/* --- Stress Test: Mixed poller I/O and CPU-bound Gs --- */

#define MIXED_CPU_GS 64
#define MIXED_CPU_YIELDS 32

static _Atomic int mixed_cpu_done = 0;
static _Atomic int mixed_io_done = 0;

typedef struct {
    run_poll_desc_t *pd;
    int read_fd;
} mixed_reader_ctx_t;

static void mixed_cpu_fn(void *arg) {
    (void)arg;
    uint64_t acc = 0;
    for (int i = 0; i < MIXED_CPU_YIELDS; i++) {
        acc += (uint64_t)i;
        run_yield();
    }
    atomic_fetch_xor(&preempt_sink, acc);
    atomic_fetch_add(&mixed_cpu_done, 1);
}

static void mixed_reader_fn(void *arg) {
    mixed_reader_ctx_t *ctx = (mixed_reader_ctx_t *)arg;
    run_poll_wait(ctx->pd, RUN_POLL_READ);

    char c = 0;
    ssize_t n = read(ctx->read_fd, &c, 1);
    if (n == 1 && c == 'm') {
        atomic_store(&mixed_io_done, 1);
    }
}

static void test_stress_mixed_io_cpu(void) {
    atomic_store(&mixed_cpu_done, 0);
    atomic_store(&mixed_io_done, 0);

    int fds[2];
    int rc = pipe(fds);
    RUN_ASSERT(rc == 0);

    run_poll_desc_t pd;
    memset(&pd, 0, sizeof(pd));
    pd.fd = fds[0];
    rc = run_poll_open(&pd);
    RUN_ASSERT(rc == 0);

    char c = 'm';
    ssize_t n = write(fds[1], &c, 1);
    RUN_ASSERT_EQ(n, 1);

    mixed_reader_ctx_t reader = {.pd = &pd, .read_fd = fds[0]};
    for (int i = 0; i < MIXED_CPU_GS; i++) {
        run_spawn(mixed_cpu_fn, NULL);
    }
    run_spawn(mixed_reader_fn, &reader);

    run_scheduler_run();

    RUN_ASSERT_EQ(atomic_load(&mixed_cpu_done), MIXED_CPU_GS);
    RUN_ASSERT_EQ(atomic_load(&mixed_io_done), 1);

    run_poll_close(&pd);
    close(fds[0]);
    close(fds[1]);
}

void run_test_stress(void) {
    TEST_SUITE("stress");
    RUN_TEST(test_stress_spawn_10000);
    RUN_TEST(test_stress_producer_consumer);
    RUN_TEST(test_stress_work_stealing_asymmetric);
    RUN_TEST(test_stress_tight_loop_preemption);
    RUN_TEST(test_stress_yield_chain);
    RUN_TEST(test_stress_concurrent_spawn);
    RUN_TEST(test_stress_channel_pingpong);
    RUN_TEST(test_stress_mixed_io_cpu);
}
