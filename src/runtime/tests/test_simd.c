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

static void test_v4f32_sqrt(void) {
    run_simd_v4f32_t v = run_simd_v4f32_make(4.0f, 9.0f, 16.0f, 25.0f);
    run_simd_v4f32_t r = run_simd_v4f32_sqrt(v);
    RUN_ASSERT(r.lanes[0] == 2.0f);
    RUN_ASSERT(r.lanes[1] == 3.0f);
    RUN_ASSERT(r.lanes[2] == 4.0f);
    RUN_ASSERT(r.lanes[3] == 5.0f);
}

static void test_v4f32_abs(void) {
    run_simd_v4f32_t v = run_simd_v4f32_make(-1.0f, 2.0f, -3.0f, 4.0f);
    run_simd_v4f32_t r = run_simd_v4f32_abs(v);
    RUN_ASSERT(r.lanes[0] == 1.0f);
    RUN_ASSERT(r.lanes[1] == 2.0f);
    RUN_ASSERT(r.lanes[2] == 3.0f);
    RUN_ASSERT(r.lanes[3] == 4.0f);
}

static void test_v4f32_floor_ceil_round(void) {
    run_simd_v4f32_t v = run_simd_v4f32_make(1.3f, 2.7f, -1.3f, -2.7f);

    run_simd_v4f32_t fl = run_simd_v4f32_floor(v);
    RUN_ASSERT(fl.lanes[0] == 1.0f);
    RUN_ASSERT(fl.lanes[1] == 2.0f);
    RUN_ASSERT(fl.lanes[2] == -2.0f);
    RUN_ASSERT(fl.lanes[3] == -3.0f);

    run_simd_v4f32_t cl = run_simd_v4f32_ceil(v);
    RUN_ASSERT(cl.lanes[0] == 2.0f);
    RUN_ASSERT(cl.lanes[1] == 3.0f);
    RUN_ASSERT(cl.lanes[2] == -1.0f);
    RUN_ASSERT(cl.lanes[3] == -2.0f);

    run_simd_v4f32_t rn = run_simd_v4f32_round(v);
    RUN_ASSERT(rn.lanes[0] == 1.0f);
    RUN_ASSERT(rn.lanes[1] == 3.0f);
    RUN_ASSERT(rn.lanes[2] == -1.0f);
    RUN_ASSERT(rn.lanes[3] == -3.0f);
}

static void test_v4f32_fma(void) {
    run_simd_v4f32_t a = run_simd_v4f32_make(1.0f, 2.0f, 3.0f, 4.0f);
    run_simd_v4f32_t b = run_simd_v4f32_make(2.0f, 2.0f, 2.0f, 2.0f);
    run_simd_v4f32_t c = run_simd_v4f32_make(10.0f, 10.0f, 10.0f, 10.0f);
    run_simd_v4f32_t r = run_simd_v4f32_fma(a, b, c);
    RUN_ASSERT(r.lanes[0] == 12.0f);
    RUN_ASSERT(r.lanes[1] == 14.0f);
    RUN_ASSERT(r.lanes[2] == 16.0f);
    RUN_ASSERT(r.lanes[3] == 18.0f);
}

static void test_v4f32_clamp(void) {
    run_simd_v4f32_t v  = run_simd_v4f32_make(-5.0f, 0.5f, 1.5f, 10.0f);
    run_simd_v4f32_t lo = run_simd_v4f32_make(0.0f, 0.0f, 0.0f, 0.0f);
    run_simd_v4f32_t hi = run_simd_v4f32_make(1.0f, 1.0f, 1.0f, 1.0f);
    run_simd_v4f32_t r = run_simd_v4f32_clamp(v, lo, hi);
    RUN_ASSERT(r.lanes[0] == 0.0f);
    RUN_ASSERT(r.lanes[1] == 0.5f);
    RUN_ASSERT(r.lanes[2] == 1.0f);
    RUN_ASSERT(r.lanes[3] == 1.0f);
}

static void test_v4f32_broadcast(void) {
    run_simd_v4f32_t r = run_simd_v4f32_broadcast(42.0f);
    RUN_ASSERT(r.lanes[0] == 42.0f);
    RUN_ASSERT(r.lanes[1] == 42.0f);
    RUN_ASSERT(r.lanes[2] == 42.0f);
    RUN_ASSERT(r.lanes[3] == 42.0f);
}

static void test_v4i32_to_v4f32(void) {
    run_simd_v4i32_t v = run_simd_v4i32_make(1, -2, 3, 100);
    run_simd_v4f32_t r = run_simd_v4i32_to_v4f32(v);
    RUN_ASSERT(r.lanes[0] == 1.0f);
    RUN_ASSERT(r.lanes[1] == -2.0f);
    RUN_ASSERT(r.lanes[2] == 3.0f);
    RUN_ASSERT(r.lanes[3] == 100.0f);
}

static void test_v4f32_to_v4i32(void) {
    run_simd_v4f32_t v = run_simd_v4f32_make(1.9f, -2.1f, 3.0f, 100.5f);
    run_simd_v4i32_t r = run_simd_v4f32_to_v4i32(v);
    RUN_ASSERT(r.lanes[0] == 1 || r.lanes[0] == 2);
    RUN_ASSERT(r.lanes[1] == -2 || r.lanes[1] == -3);
    RUN_ASSERT(r.lanes[2] == 3);
}

static void test_v8f32_sqrt(void) {
    run_simd_v8f32_t v = run_simd_v8f32_make(1.0f, 4.0f, 9.0f, 16.0f, 25.0f, 36.0f, 49.0f, 64.0f);
    run_simd_v8f32_t r = run_simd_v8f32_sqrt(v);
    RUN_ASSERT(r.lanes[0] == 1.0f);
    RUN_ASSERT(r.lanes[1] == 2.0f);
    RUN_ASSERT(r.lanes[2] == 3.0f);
    RUN_ASSERT(r.lanes[3] == 4.0f);
    RUN_ASSERT(r.lanes[4] == 5.0f);
    RUN_ASSERT(r.lanes[5] == 6.0f);
    RUN_ASSERT(r.lanes[6] == 7.0f);
    RUN_ASSERT(r.lanes[7] == 8.0f);
}

void run_test_simd(void) {
    TEST_SUITE("run_simd");
    RUN_TEST(test_aligned_alloc_16);
    RUN_TEST(test_aligned_alloc_32);
    RUN_TEST(test_simd_width_matches_compiled_fast_path);
    RUN_TEST(test_v4f32_add_and_hadd);
    RUN_TEST(test_v4f32_sqrt);
    RUN_TEST(test_v4f32_abs);
    RUN_TEST(test_v4f32_floor_ceil_round);
    RUN_TEST(test_v4f32_fma);
    RUN_TEST(test_v4f32_clamp);
    RUN_TEST(test_v4f32_broadcast);
    RUN_TEST(test_v4i32_to_v4f32);
    RUN_TEST(test_v4f32_to_v4i32);
    RUN_TEST(test_v8f32_sqrt);
}
