#ifndef RUN_SIMD_H
#define RUN_SIMD_H

#include "run_alloc.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#endif

#define RUN_SIMD_DEFINE_TYPE(NAME, ELEM, LANES, ALIGNMENT) \
    typedef struct __attribute__((aligned(ALIGNMENT))) {   \
        ELEM lanes[LANES];                                 \
    } run_simd_##NAME##_t

RUN_SIMD_DEFINE_TYPE(v2bool, bool, 2, 16);
RUN_SIMD_DEFINE_TYPE(v4bool, bool, 4, 16);
RUN_SIMD_DEFINE_TYPE(v8bool, bool, 8, 16);
RUN_SIMD_DEFINE_TYPE(v16bool, bool, 16, 16);
RUN_SIMD_DEFINE_TYPE(v32bool, bool, 32, 32);

RUN_SIMD_DEFINE_TYPE(v4f32, float, 4, 16);
RUN_SIMD_DEFINE_TYPE(v2f64, double, 2, 16);
RUN_SIMD_DEFINE_TYPE(v4i32, int32_t, 4, 16);
RUN_SIMD_DEFINE_TYPE(v8i16, int16_t, 8, 16);
RUN_SIMD_DEFINE_TYPE(v16i8, int8_t, 16, 16);

RUN_SIMD_DEFINE_TYPE(v8f32, float, 8, 32);
RUN_SIMD_DEFINE_TYPE(v4f64, double, 4, 32);
RUN_SIMD_DEFINE_TYPE(v8i32, int32_t, 8, 32);
RUN_SIMD_DEFINE_TYPE(v16i16, int16_t, 16, 32);
RUN_SIMD_DEFINE_TYPE(v32i8, int8_t, 32, 32);

#undef RUN_SIMD_DEFINE_TYPE

#define RUN_SIMD_DEFINE_MAKE_2(NAME, ELEM)                                           \
    static inline run_simd_##NAME##_t run_simd_##NAME##_make(ELEM a0, ELEM a1) {     \
        return (run_simd_##NAME##_t){ .lanes = { a0, a1 } };                         \
    }

#define RUN_SIMD_DEFINE_MAKE_4(NAME, ELEM)                                                       \
    static inline run_simd_##NAME##_t run_simd_##NAME##_make(ELEM a0, ELEM a1, ELEM a2, ELEM a3) { \
        return (run_simd_##NAME##_t){ .lanes = { a0, a1, a2, a3 } };                            \
    }

#define RUN_SIMD_DEFINE_MAKE_8(NAME, ELEM)                                                                             \
    static inline run_simd_##NAME##_t run_simd_##NAME##_make(                                                         \
        ELEM a0, ELEM a1, ELEM a2, ELEM a3, ELEM a4, ELEM a5, ELEM a6, ELEM a7) {                                   \
        return (run_simd_##NAME##_t){ .lanes = { a0, a1, a2, a3, a4, a5, a6, a7 } };                                \
    }

#define RUN_SIMD_DEFINE_MAKE_16(NAME, ELEM)                                                                            \
    static inline run_simd_##NAME##_t run_simd_##NAME##_make(                                                         \
        ELEM a0, ELEM a1, ELEM a2, ELEM a3, ELEM a4, ELEM a5, ELEM a6, ELEM a7,                                      \
        ELEM a8, ELEM a9, ELEM a10, ELEM a11, ELEM a12, ELEM a13, ELEM a14, ELEM a15) {                             \
        return (run_simd_##NAME##_t){ .lanes = {                                                                      \
            a0, a1, a2, a3, a4, a5, a6, a7,                                                                           \
            a8, a9, a10, a11, a12, a13, a14, a15                                                                      \
        } };                                                                                                          \
    }

#define RUN_SIMD_DEFINE_MAKE_32(NAME, ELEM)                                                                            \
    static inline run_simd_##NAME##_t run_simd_##NAME##_make(                                                         \
        ELEM a0, ELEM a1, ELEM a2, ELEM a3, ELEM a4, ELEM a5, ELEM a6, ELEM a7,                                      \
        ELEM a8, ELEM a9, ELEM a10, ELEM a11, ELEM a12, ELEM a13, ELEM a14, ELEM a15,                               \
        ELEM a16, ELEM a17, ELEM a18, ELEM a19, ELEM a20, ELEM a21, ELEM a22, ELEM a23,                             \
        ELEM a24, ELEM a25, ELEM a26, ELEM a27, ELEM a28, ELEM a29, ELEM a30, ELEM a31) {                           \
        return (run_simd_##NAME##_t){ .lanes = {                                                                      \
            a0, a1, a2, a3, a4, a5, a6, a7,                                                                           \
            a8, a9, a10, a11, a12, a13, a14, a15,                                                                     \
            a16, a17, a18, a19, a20, a21, a22, a23,                                                                   \
            a24, a25, a26, a27, a28, a29, a30, a31                                                                    \
        } };                                                                                                          \
    }

#define RUN_SIMD_DEFINE_ACCESSORS(NAME, ELEM)                                                       \
    static inline ELEM run_simd_##NAME##_get_lane(run_simd_##NAME##_t value, int64_t index) {      \
        return value.lanes[(size_t)index];                                                          \
    }                                                                                                \
    static inline run_simd_##NAME##_t run_simd_##NAME##_set_lane(                                   \
        run_simd_##NAME##_t value, int64_t index, ELEM lane) {                                      \
        value.lanes[(size_t)index] = lane;                                                          \
        return value;                                                                                \
    }

#define RUN_SIMD_DEFINE_COMPARE_SELECT(NAME, ELEM, LANES, MASK_NAME)                                         \
    static inline run_simd_##MASK_NAME##_t run_simd_##NAME##_eq(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##MASK_NAME##_t out;                                                                       \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] == b.lanes[i];                     \
        return out;                                                                                         \
    }                                                                                                       \
    static inline run_simd_##MASK_NAME##_t run_simd_##NAME##_ne(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##MASK_NAME##_t out;                                                                       \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] != b.lanes[i];                     \
        return out;                                                                                         \
    }                                                                                                       \
    static inline run_simd_##MASK_NAME##_t run_simd_##NAME##_lt(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##MASK_NAME##_t out;                                                                       \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] < b.lanes[i];                      \
        return out;                                                                                         \
    }                                                                                                       \
    static inline run_simd_##MASK_NAME##_t run_simd_##NAME##_le(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##MASK_NAME##_t out;                                                                       \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] <= b.lanes[i];                     \
        return out;                                                                                         \
    }                                                                                                       \
    static inline run_simd_##MASK_NAME##_t run_simd_##NAME##_gt(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##MASK_NAME##_t out;                                                                       \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] > b.lanes[i];                      \
        return out;                                                                                         \
    }                                                                                                       \
    static inline run_simd_##MASK_NAME##_t run_simd_##NAME##_ge(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##MASK_NAME##_t out;                                                                       \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] >= b.lanes[i];                     \
        return out;                                                                                         \
    }                                                                                                       \
    static inline run_simd_##NAME##_t run_simd_##NAME##_select(                                             \
        run_simd_##MASK_NAME##_t mask, run_simd_##NAME##_t if_true, run_simd_##NAME##_t if_false) {       \
        run_simd_##NAME##_t out;                                                                            \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = mask.lanes[i] ? if_true.lanes[i] : if_false.lanes[i]; \
        return out;                                                                                         \
    }

#define RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(NAME, ELEM, LANES)                                      \
    static inline run_simd_##NAME##_t run_simd_##NAME##_add(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##NAME##_t out;                                                                    \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] + b.lanes[i];              \
        return out;                                                                                 \
    }                                                                                               \
    static inline run_simd_##NAME##_t run_simd_##NAME##_sub(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##NAME##_t out;                                                                    \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] - b.lanes[i];              \
        return out;                                                                                 \
    }                                                                                               \
    static inline run_simd_##NAME##_t run_simd_##NAME##_mul(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##NAME##_t out;                                                                    \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] * b.lanes[i];              \
        return out;                                                                                 \
    }                                                                                               \
    static inline run_simd_##NAME##_t run_simd_##NAME##_div(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##NAME##_t out;                                                                    \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] / b.lanes[i];              \
        return out;                                                                                 \
    }                                                                                               \
    static inline run_simd_##NAME##_t run_simd_##NAME##_min(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##NAME##_t out;                                                                    \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] < b.lanes[i] ? a.lanes[i] : b.lanes[i]; \
        return out;                                                                                 \
    }                                                                                               \
    static inline run_simd_##NAME##_t run_simd_##NAME##_max(run_simd_##NAME##_t a, run_simd_##NAME##_t b) { \
        run_simd_##NAME##_t out;                                                                    \
        for (size_t i = 0; i < (LANES); ++i) out.lanes[i] = a.lanes[i] > b.lanes[i] ? a.lanes[i] : b.lanes[i]; \
        return out;                                                                                 \
    }                                                                                               \
    static inline ELEM run_simd_##NAME##_hadd(run_simd_##NAME##_t value) {                         \
        ELEM out = (ELEM)0;                                                                         \
        for (size_t i = 0; i < (LANES); ++i) out += value.lanes[i];                                \
        return out;                                                                                 \
    }                                                                                               \
    static inline ELEM run_simd_##NAME##_dot(run_simd_##NAME##_t a, run_simd_##NAME##_t b) {      \
        ELEM out = (ELEM)0;                                                                         \
        for (size_t i = 0; i < (LANES); ++i) out += a.lanes[i] * b.lanes[i];                       \
        return out;                                                                                 \
    }

#define RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(NAME)                                                \
    static inline run_simd_##NAME##_t run_simd_##NAME##_load(run_gen_ref_t ptr) {              \
        run_simd_##NAME##_t out;                                                                \
        const void *raw = run_gen_ref_deref(ptr);                                               \
        memcpy(&out, raw, sizeof(out));                                                         \
        return out;                                                                             \
    }                                                                                           \
    static inline run_simd_##NAME##_t run_simd_##NAME##_load_unaligned(run_gen_ref_t ptr) {    \
        run_simd_##NAME##_t out;                                                                \
        const void *raw = run_gen_ref_deref(ptr);                                               \
        memcpy(&out, raw, sizeof(out));                                                         \
        return out;                                                                             \
    }                                                                                           \
    static inline void run_simd_##NAME##_store(run_gen_ref_t ptr, run_simd_##NAME##_t value) { \
        void *raw = run_gen_ref_deref(ptr);                                                     \
        memcpy(raw, &value, sizeof(value));                                                     \
    }

#define RUN_SIMD_DEFINE_SHUFFLE_2(NAME)                                                           \
    static inline run_simd_##NAME##_t run_simd_##NAME##_shuffle(run_simd_##NAME##_t value, int64_t i0, int64_t i1) { \
        run_simd_##NAME##_t out;                                                                  \
        const int64_t idxs[2] = { i0, i1 };                                                       \
        for (size_t i = 0; i < 2; ++i) out.lanes[i] = value.lanes[(size_t)idxs[i]];              \
        return out;                                                                                \
    }

#define RUN_SIMD_DEFINE_SHUFFLE_4(NAME)                                                           \
    static inline run_simd_##NAME##_t run_simd_##NAME##_shuffle(run_simd_##NAME##_t value, int64_t i0, int64_t i1, int64_t i2, int64_t i3) { \
        run_simd_##NAME##_t out;                                                                  \
        const int64_t idxs[4] = { i0, i1, i2, i3 };                                               \
        for (size_t i = 0; i < 4; ++i) out.lanes[i] = value.lanes[(size_t)idxs[i]];              \
        return out;                                                                                \
    }

#define RUN_SIMD_DEFINE_SHUFFLE_8(NAME)                                                           \
    static inline run_simd_##NAME##_t run_simd_##NAME##_shuffle(                                  \
        run_simd_##NAME##_t value,                                                                 \
        int64_t i0, int64_t i1, int64_t i2, int64_t i3, int64_t i4, int64_t i5, int64_t i6, int64_t i7) { \
        run_simd_##NAME##_t out;                                                                   \
        const int64_t idxs[8] = { i0, i1, i2, i3, i4, i5, i6, i7 };                               \
        for (size_t i = 0; i < 8; ++i) out.lanes[i] = value.lanes[(size_t)idxs[i]];               \
        return out;                                                                                 \
    }

#define RUN_SIMD_DEFINE_SHUFFLE_16(NAME)                                                          \
    static inline run_simd_##NAME##_t run_simd_##NAME##_shuffle(                                  \
        run_simd_##NAME##_t value,                                                                 \
        int64_t i0, int64_t i1, int64_t i2, int64_t i3, int64_t i4, int64_t i5, int64_t i6, int64_t i7, \
        int64_t i8, int64_t i9, int64_t i10, int64_t i11, int64_t i12, int64_t i13, int64_t i14, int64_t i15) { \
        run_simd_##NAME##_t out;                                                                   \
        const int64_t idxs[16] = { i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15 }; \
        for (size_t i = 0; i < 16; ++i) out.lanes[i] = value.lanes[(size_t)idxs[i]];              \
        return out;                                                                                 \
    }

#define RUN_SIMD_DEFINE_SHUFFLE_32(NAME)                                                          \
    static inline run_simd_##NAME##_t run_simd_##NAME##_shuffle(                                  \
        run_simd_##NAME##_t value,                                                                 \
        int64_t i0, int64_t i1, int64_t i2, int64_t i3, int64_t i4, int64_t i5, int64_t i6, int64_t i7, \
        int64_t i8, int64_t i9, int64_t i10, int64_t i11, int64_t i12, int64_t i13, int64_t i14, int64_t i15, \
        int64_t i16, int64_t i17, int64_t i18, int64_t i19, int64_t i20, int64_t i21, int64_t i22, int64_t i23, \
        int64_t i24, int64_t i25, int64_t i26, int64_t i27, int64_t i28, int64_t i29, int64_t i30, int64_t i31) { \
        run_simd_##NAME##_t out;                                                                   \
        const int64_t idxs[32] = {                                                                 \
            i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15,                \
            i16, i17, i18, i19, i20, i21, i22, i23, i24, i25, i26, i27, i28, i29, i30, i31       \
        };                                                                                         \
        for (size_t i = 0; i < 32; ++i) out.lanes[i] = value.lanes[(size_t)idxs[i]];              \
        return out;                                                                                 \
    }

RUN_SIMD_DEFINE_MAKE_2(v2bool, bool);
RUN_SIMD_DEFINE_MAKE_4(v4bool, bool);
RUN_SIMD_DEFINE_MAKE_8(v8bool, bool);
RUN_SIMD_DEFINE_MAKE_16(v16bool, bool);
RUN_SIMD_DEFINE_MAKE_32(v32bool, bool);
RUN_SIMD_DEFINE_ACCESSORS(v2bool, bool);
RUN_SIMD_DEFINE_ACCESSORS(v4bool, bool);
RUN_SIMD_DEFINE_ACCESSORS(v8bool, bool);
RUN_SIMD_DEFINE_ACCESSORS(v16bool, bool);
RUN_SIMD_DEFINE_ACCESSORS(v32bool, bool);

RUN_SIMD_DEFINE_MAKE_2(v2f64, double);
RUN_SIMD_DEFINE_MAKE_4(v4f32, float);
RUN_SIMD_DEFINE_MAKE_4(v4i32, int32_t);
RUN_SIMD_DEFINE_MAKE_8(v8i16, int16_t);
RUN_SIMD_DEFINE_MAKE_16(v16i8, int8_t);
RUN_SIMD_DEFINE_MAKE_8(v8f32, float);
RUN_SIMD_DEFINE_MAKE_4(v4f64, double);
RUN_SIMD_DEFINE_MAKE_8(v8i32, int32_t);
RUN_SIMD_DEFINE_MAKE_16(v16i16, int16_t);
RUN_SIMD_DEFINE_MAKE_32(v32i8, int8_t);

RUN_SIMD_DEFINE_ACCESSORS(v4f32, float);
RUN_SIMD_DEFINE_ACCESSORS(v2f64, double);
RUN_SIMD_DEFINE_ACCESSORS(v4i32, int32_t);
RUN_SIMD_DEFINE_ACCESSORS(v8i16, int16_t);
RUN_SIMD_DEFINE_ACCESSORS(v16i8, int8_t);
RUN_SIMD_DEFINE_ACCESSORS(v8f32, float);
RUN_SIMD_DEFINE_ACCESSORS(v4f64, double);
RUN_SIMD_DEFINE_ACCESSORS(v8i32, int32_t);
RUN_SIMD_DEFINE_ACCESSORS(v16i16, int16_t);
RUN_SIMD_DEFINE_ACCESSORS(v32i8, int8_t);

RUN_SIMD_DEFINE_COMPARE_SELECT(v4f32, float, 4, v4bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v2f64, double, 2, v2bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v4i32, int32_t, 4, v4bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v8i16, int16_t, 8, v8bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v16i8, int8_t, 16, v16bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v8f32, float, 8, v8bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v4f64, double, 4, v4bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v8i32, int32_t, 8, v8bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v16i16, int16_t, 16, v16bool);
RUN_SIMD_DEFINE_COMPARE_SELECT(v32i8, int8_t, 32, v32bool);

static inline run_simd_v4f32_t run_simd_v4f32_add(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    run_simd_v4f32_t out;
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vaddq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_add_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) out.lanes[i] = a.lanes[i] + b.lanes[i];
#endif
    return out;
}
static inline run_simd_v4f32_t run_simd_v4f32_sub(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    run_simd_v4f32_t out;
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vsubq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_sub_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) out.lanes[i] = a.lanes[i] - b.lanes[i];
#endif
    return out;
}
static inline run_simd_v4f32_t run_simd_v4f32_mul(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    run_simd_v4f32_t out;
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vmulq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_mul_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) out.lanes[i] = a.lanes[i] * b.lanes[i];
#endif
    return out;
}
static inline run_simd_v4f32_t run_simd_v4f32_div(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    run_simd_v4f32_t out;
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vdivq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_div_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) out.lanes[i] = a.lanes[i] / b.lanes[i];
#endif
    return out;
}
static inline run_simd_v4f32_t run_simd_v4f32_min(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    run_simd_v4f32_t out;
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vminq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_min_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) out.lanes[i] = a.lanes[i] < b.lanes[i] ? a.lanes[i] : b.lanes[i];
#endif
    return out;
}
static inline run_simd_v4f32_t run_simd_v4f32_max(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    run_simd_v4f32_t out;
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vmaxq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_max_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) out.lanes[i] = a.lanes[i] > b.lanes[i] ? a.lanes[i] : b.lanes[i];
#endif
    return out;
}
static inline float run_simd_v4f32_hadd(run_simd_v4f32_t value) {
    float tmp[4];
#if defined(__aarch64__)
    vst1q_f32(tmp, vld1q_f32(value.lanes));
#elif defined(__SSE__)
    _mm_storeu_ps(tmp, _mm_loadu_ps(value.lanes));
#else
    memcpy(tmp, value.lanes, sizeof(tmp));
#endif
    return tmp[0] + tmp[1] + tmp[2] + tmp[3];
}
static inline float run_simd_v4f32_dot(run_simd_v4f32_t a, run_simd_v4f32_t b) {
    float tmp[4];
#if defined(__aarch64__)
    vst1q_f32(tmp, vmulq_f32(vld1q_f32(a.lanes), vld1q_f32(b.lanes)));
#elif defined(__SSE__)
    _mm_storeu_ps(tmp, _mm_mul_ps(_mm_loadu_ps(a.lanes), _mm_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 4; ++i) tmp[i] = a.lanes[i] * b.lanes[i];
#endif
    return tmp[0] + tmp[1] + tmp[2] + tmp[3];
}
static inline run_simd_v4f32_t run_simd_v4f32_load(run_gen_ref_t ptr) {
    run_simd_v4f32_t out;
    const float *raw = (const float *)run_gen_ref_deref(ptr);
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vld1q_f32(raw));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_load_ps(raw));
#else
    memcpy(&out, raw, sizeof(out));
#endif
    return out;
}
static inline run_simd_v4f32_t run_simd_v4f32_load_unaligned(run_gen_ref_t ptr) {
    run_simd_v4f32_t out;
    const float *raw = (const float *)run_gen_ref_deref(ptr);
#if defined(__aarch64__)
    vst1q_f32(out.lanes, vld1q_f32(raw));
#elif defined(__SSE__)
    _mm_storeu_ps(out.lanes, _mm_loadu_ps(raw));
#else
    memcpy(&out, raw, sizeof(out));
#endif
    return out;
}
static inline void run_simd_v4f32_store(run_gen_ref_t ptr, run_simd_v4f32_t value) {
    float *raw = (float *)run_gen_ref_deref(ptr);
#if defined(__aarch64__)
    vst1q_f32(raw, vld1q_f32(value.lanes));
#elif defined(__SSE__)
    _mm_store_ps(raw, _mm_loadu_ps(value.lanes));
#else
    memcpy(raw, &value, sizeof(value));
#endif
}

RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v2f64, double, 2);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v2f64);
RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v4i32, int32_t, 4);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v4i32);
RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v8i16, int16_t, 8);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v8i16);
RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v16i8, int8_t, 16);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v16i8);

static inline run_simd_v8f32_t run_simd_v8f32_add(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    run_simd_v8f32_t out;
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_add_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) out.lanes[i] = a.lanes[i] + b.lanes[i];
#endif
    return out;
}
static inline run_simd_v8f32_t run_simd_v8f32_sub(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    run_simd_v8f32_t out;
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_sub_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) out.lanes[i] = a.lanes[i] - b.lanes[i];
#endif
    return out;
}
static inline run_simd_v8f32_t run_simd_v8f32_mul(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    run_simd_v8f32_t out;
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_mul_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) out.lanes[i] = a.lanes[i] * b.lanes[i];
#endif
    return out;
}
static inline run_simd_v8f32_t run_simd_v8f32_div(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    run_simd_v8f32_t out;
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_div_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) out.lanes[i] = a.lanes[i] / b.lanes[i];
#endif
    return out;
}
static inline run_simd_v8f32_t run_simd_v8f32_min(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    run_simd_v8f32_t out;
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_min_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) out.lanes[i] = a.lanes[i] < b.lanes[i] ? a.lanes[i] : b.lanes[i];
#endif
    return out;
}
static inline run_simd_v8f32_t run_simd_v8f32_max(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    run_simd_v8f32_t out;
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_max_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) out.lanes[i] = a.lanes[i] > b.lanes[i] ? a.lanes[i] : b.lanes[i];
#endif
    return out;
}
static inline float run_simd_v8f32_hadd(run_simd_v8f32_t value) {
    float tmp[8];
#if defined(__AVX__)
    _mm256_storeu_ps(tmp, _mm256_loadu_ps(value.lanes));
#else
    memcpy(tmp, value.lanes, sizeof(tmp));
#endif
    return tmp[0] + tmp[1] + tmp[2] + tmp[3] + tmp[4] + tmp[5] + tmp[6] + tmp[7];
}
static inline float run_simd_v8f32_dot(run_simd_v8f32_t a, run_simd_v8f32_t b) {
    float tmp[8];
#if defined(__AVX__)
    _mm256_storeu_ps(tmp, _mm256_mul_ps(_mm256_loadu_ps(a.lanes), _mm256_loadu_ps(b.lanes)));
#else
    for (size_t i = 0; i < 8; ++i) tmp[i] = a.lanes[i] * b.lanes[i];
#endif
    return tmp[0] + tmp[1] + tmp[2] + tmp[3] + tmp[4] + tmp[5] + tmp[6] + tmp[7];
}
static inline run_simd_v8f32_t run_simd_v8f32_load(run_gen_ref_t ptr) {
    run_simd_v8f32_t out;
    const float *raw = (const float *)run_gen_ref_deref(ptr);
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_load_ps(raw));
#else
    memcpy(&out, raw, sizeof(out));
#endif
    return out;
}
static inline run_simd_v8f32_t run_simd_v8f32_load_unaligned(run_gen_ref_t ptr) {
    run_simd_v8f32_t out;
    const float *raw = (const float *)run_gen_ref_deref(ptr);
#if defined(__AVX__)
    _mm256_storeu_ps(out.lanes, _mm256_loadu_ps(raw));
#else
    memcpy(&out, raw, sizeof(out));
#endif
    return out;
}
static inline void run_simd_v8f32_store(run_gen_ref_t ptr, run_simd_v8f32_t value) {
    float *raw = (float *)run_gen_ref_deref(ptr);
#if defined(__AVX__)
    _mm256_store_ps(raw, _mm256_loadu_ps(value.lanes));
#else
    memcpy(raw, &value, sizeof(value));
#endif
}

RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v4f64, double, 4);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v4f64);
RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v8i32, int32_t, 8);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v8i32);
RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v16i16, int16_t, 16);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v16i16);
RUN_SIMD_DEFINE_ARITH_REDUCE_GENERIC(v32i8, int8_t, 32);
RUN_SIMD_DEFINE_LOAD_STORE_GENERIC(v32i8);

RUN_SIMD_DEFINE_SHUFFLE_2(v2f64);
RUN_SIMD_DEFINE_SHUFFLE_4(v4f32);
RUN_SIMD_DEFINE_SHUFFLE_4(v4i32);
RUN_SIMD_DEFINE_SHUFFLE_8(v8i16);
RUN_SIMD_DEFINE_SHUFFLE_16(v16i8);
RUN_SIMD_DEFINE_SHUFFLE_8(v8f32);
RUN_SIMD_DEFINE_SHUFFLE_4(v4f64);
RUN_SIMD_DEFINE_SHUFFLE_8(v8i32);
RUN_SIMD_DEFINE_SHUFFLE_16(v16i16);
RUN_SIMD_DEFINE_SHUFFLE_32(v32i8);

int64_t run_simd_width(void);

#endif
