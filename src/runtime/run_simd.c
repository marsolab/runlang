#include "run_simd.h"

int64_t run_simd_width(void) {
#if defined(__AVX__)
    return 256;
#elif defined(__aarch64__) || defined(__SSE__)
    return 128;
#else
    return 0;
#endif
}
