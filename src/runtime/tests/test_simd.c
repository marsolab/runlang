#include "test_framework.h"
#include "../run_alloc.h"
#include "../run_simd.h"

#include <stdint.h>

static void test_aligned_alloc_16(void) {
    void *ptr = run_gen_alloc_aligned(1, 16);
    RUN_ASSERT(ptr != NULL);
    RUN_ASSERT_EQ(((uintptr_t)ptr) % 16, 0);
    run_gen_free(ptr);
}

static void test_aligned_alloc_32(void) {
    void *ptr = run_gen_alloc_aligned(1, 32);
    RUN_ASSERT(ptr != NULL);
    RUN_ASSERT_EQ(((uintptr_t)ptr) % 32, 0);
    run_gen_free(ptr);
}

static void test_simd_width_matches_compiled_fast_path(void) {
    const int64_t width = run_simd_width();
#if defined(__AVX__)
    RUN_ASSERT_EQ(width, 256);
#elif defined(__aarch64__) || defined(__SSE__)
    RUN_ASSERT_EQ(width, 128);
#else
    RUN_ASSERT_EQ(width, 0);
#endif
}

static void test_v4f32_add_and_hadd(void) {
    run_simd_v4f32_t a = run_simd_v4f32_make(1.0f, 2.0f, 3.0f, 4.0f);
    run_simd_v4f32_t b = run_simd_v4f32_make(10.0f, 20.0f, 30.0f, 40.0f);
    run_simd_v4f32_t sum = run_simd_v4f32_add(a, b);

    RUN_ASSERT(sum.lanes[0] == 11.0f);
    RUN_ASSERT(sum.lanes[1] == 22.0f);
    RUN_ASSERT(sum.lanes[2] == 33.0f);
    RUN_ASSERT(sum.lanes[3] == 44.0f);
    RUN_ASSERT(run_simd_v4f32_hadd(sum) == 110.0f);
}

void run_test_simd(void) {
    TEST_SUITE("run_simd");
    RUN_TEST(test_aligned_alloc_16);
    RUN_TEST(test_aligned_alloc_32);
    RUN_TEST(test_simd_width_matches_compiled_fast_path);
    RUN_TEST(test_v4f32_add_and_hadd);
}
