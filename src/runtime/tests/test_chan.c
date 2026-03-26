#include "test_framework.h"
#include "../run_scheduler.h"
#include "../run_chan.h"
#include <string.h>

/* --- Helpers --- */

typedef struct {
    run_chan_t *ch;
    int64_t value;
} chan_test_ctx_t;

static void sender_fn(void *arg) {
    chan_test_ctx_t *ctx = (chan_test_ctx_t *)arg;
    run_chan_send(ctx->ch, &ctx->value);
}

static void receiver_fn(void *arg) {
    chan_test_ctx_t *ctx = (chan_test_ctx_t *)arg;
    run_chan_recv(ctx->ch, &ctx->value);
}

static volatile int64_t test_result = 0;

static void recv_and_store_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    int64_t val = 0;
    run_chan_recv(ch, &val);
    test_result = val;
}

static void send_42_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    int64_t val = 42;
    run_chan_send(ch, &val);
}

/* --- Buffered Channel Tests --- */

static void test_chan_buffered_basic(void) {
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 2);
    RUN_ASSERT(ch != NULL);

    int64_t val = 100;
    /* Buffered send should not block */
    run_chan_send(ch, &val);

    int64_t recv_val = 0;
    run_chan_recv(ch, &recv_val);
    RUN_ASSERT_EQ(recv_val, 100);

    run_chan_free(ch);
}

static void test_chan_buffered_fifo(void) {
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 3);

    int64_t v1 = 10, v2 = 20, v3 = 30;
    run_chan_send(ch, &v1);
    run_chan_send(ch, &v2);
    run_chan_send(ch, &v3);

    int64_t out = 0;
    run_chan_recv(ch, &out); RUN_ASSERT_EQ(out, 10);
    run_chan_recv(ch, &out); RUN_ASSERT_EQ(out, 20);
    run_chan_recv(ch, &out); RUN_ASSERT_EQ(out, 30);

    run_chan_free(ch);
}

static void test_chan_try_send_would_block(void) {
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 1);
    int64_t value = 7;

    RUN_ASSERT_EQ(run_chan_try_send(ch, &value), RUN_CHAN_SEND_OK);
    RUN_ASSERT_EQ(run_chan_try_send(ch, &value), RUN_CHAN_SEND_WOULD_BLOCK);

    run_chan_close(ch);
    run_chan_free(ch);
}

static void test_chan_try_send_closed(void) {
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 1);
    int64_t value = 9;

    run_chan_close(ch);
    RUN_ASSERT_EQ(run_chan_try_send(ch, &value), RUN_CHAN_SEND_CLOSED);

    run_chan_free(ch);
}

/* --- Unbuffered Channel Tests --- */

static void test_chan_unbuffered(void) {
    test_result = 0;
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 0);

    /* Spawn a receiver first, then a sender.
     * Receiver will block until sender sends. */
    run_spawn(recv_and_store_fn, ch);
    run_spawn(send_42_fn, ch);
    run_scheduler_run();

    RUN_ASSERT_EQ(test_result, 42);
    run_chan_free(ch);
}

/* --- Producer-Consumer Pattern --- */

static void producer_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    for (int64_t i = 1; i <= 5; i++) {
        run_chan_send(ch, &i);
    }
}

static volatile int64_t consumer_sum = 0;

static void consumer_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    for (int i = 0; i < 5; i++) {
        int64_t val = 0;
        run_chan_recv(ch, &val);
        consumer_sum += val;
    }
}

static void test_chan_producer_consumer(void) {
    consumer_sum = 0;
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 2);

    run_spawn(producer_fn, ch);
    run_spawn(consumer_fn, ch);
    run_scheduler_run();

    /* Sum of 1+2+3+4+5 = 15 */
    RUN_ASSERT_EQ(consumer_sum, 15);
    run_chan_free(ch);
}

/* --- Close Tests --- */

static volatile int64_t close_recv_val = -1;

static void recv_after_close_fn(void *arg) {
    run_chan_t *ch = (run_chan_t *)arg;
    int64_t val = -1;
    run_chan_recv(ch, &val);
    close_recv_val = val;
}

static void test_chan_close_recv_zero(void) {
    close_recv_val = -1;
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 0);

    /* Close the channel, then spawn a receiver.
     * The receiver should get zero value. */
    run_chan_close(ch);

    /* Direct call (not from a green thread) */
    int64_t val = -1;
    run_chan_recv(ch, &val);
    RUN_ASSERT_EQ(val, 0);

    run_chan_free(ch);
}

static void test_chan_close_wakes_receivers(void) {
    close_recv_val = -1;
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 0);

    /* Spawn a receiver that will block */
    run_spawn(recv_after_close_fn, ch);

    /* Spawn a goroutine that closes the channel after the receiver blocks */
    static run_chan_t *close_ch;
    close_ch = ch;
    run_spawn((void (*)(void *))run_chan_close, close_ch);

    run_scheduler_run();

    /* Receiver should have gotten zero value */
    RUN_ASSERT_EQ(close_recv_val, 0);
    run_chan_free(ch);
}

void run_test_chan(void) {
    TEST_SUITE("run_chan");
    RUN_TEST(test_chan_buffered_basic);
    RUN_TEST(test_chan_buffered_fifo);
    RUN_TEST(test_chan_try_send_would_block);
    RUN_TEST(test_chan_try_send_closed);
    RUN_TEST(test_chan_unbuffered);
    RUN_TEST(test_chan_producer_consumer);
    RUN_TEST(test_chan_close_recv_zero);
    RUN_TEST(test_chan_close_wakes_receivers);
}
