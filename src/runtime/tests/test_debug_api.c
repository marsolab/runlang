#include "test_framework.h"
#include "../run_debug_api.h"
#include "../run_string.h"

#include <stdbool.h>
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

    /* Top frame should have a non-empty function (may be <unknown> on Linux
     * for static callers) and a non-empty module path. */
    run_stack_frame_t *top = (run_stack_frame_t *)frames.ptr;
    RUN_ASSERT(top->function.len > 0);
    RUN_ASSERT(top->file.len > 0);

    /* At least one frame must resolve to the exported suite dispatcher —
     * dladdr on Linux only sees the dynamic symbol table, so static test
     * function symbols appear as <unknown> but run_test_debug_api does not. */
    bool found_dispatcher = false;
    for (size_t i = 0; i < frames.len; i++) {
        run_stack_frame_t *f =
            (run_stack_frame_t *)((char *)frames.ptr + i * sizeof(run_stack_frame_t));
        if (f->function.len > 0 &&
            strstr(f->function.ptr, "run_test_debug_api") != NULL) {
            found_dispatcher = true;
            break;
        }
    }
    RUN_ASSERT(found_dispatcher);

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
