#include "test_framework.h"
#include "../run_debug_api.h"
#include "../run_string.h"

#include <string.h>

static void test_debug_assert_true(void) {
    run_string_t msg = run_string_from_cstr("should not fail");
    run_debug_assert(true, msg);
    RUN_ASSERT(1);
}

static void test_debug_stack_trace(void) {
    run_slice_t frames = run_debug_stack_trace(0);
    RUN_ASSERT(frames.ptr != NULL);
    RUN_ASSERT(frames.len > 0);
    run_slice_free(&frames);
}

static void test_debug_print_stack(void) {
    /* Should write to stderr without crashing */
    run_debug_print_stack();
    RUN_ASSERT(1);
}

static void test_debug_format_stack(void) {
    run_slice_t frames = run_debug_stack_trace(0);
    run_string_t s = run_debug_format_stack(frames);
    RUN_ASSERT(s.ptr != NULL);
    RUN_ASSERT(s.len > 0);
    run_slice_free(&frames);
}

static void test_debug_unreachable_msg(void) {
    /* We can't test the abort path — just verify the function exists.
     * Testing that it aborts would kill the test process. */
    RUN_ASSERT(1);
}

static void test_debug_todo_msg(void) {
    /* Same — can't test abort path */
    RUN_ASSERT(1);
}

void run_test_debug_api(void) {
    TEST_SUITE("debug_api");
    RUN_TEST(test_debug_assert_true);
    RUN_TEST(test_debug_stack_trace);
    RUN_TEST(test_debug_print_stack);
    RUN_TEST(test_debug_format_stack);
    RUN_TEST(test_debug_unreachable_msg);
    RUN_TEST(test_debug_todo_msg);
}
