#ifndef RUN_STACKTRACE_H
#define RUN_STACKTRACE_H

#include <stddef.h>
#include <stdint.h>

/* ========================================================================
 * Stack trace utilities
 *
 * Walks the current thread's call stack using libunwind where available
 * and symbolizes each frame with function name, binary path, and line
 * number when platform symbolication tools can resolve DWARF line tables.
 *
 * Supported platforms: macOS and Linux (both link against libunwind).
 * On unsupported platforms these functions return 0/empty and callers
 * should handle the empty result.
 * ======================================================================== */

typedef struct {
    void *ip;           /* instruction pointer of this frame */
    char function[256]; /* mangled symbol name, or empty */
    char file[512];     /* binary (module) path, or empty */
    int64_t line;       /* source line; 0 when DWARF is unavailable */
} run_stack_entry_t;

/* Capture up to `max_count` frames from the current thread's stack.
 * `skip` frames are skipped (0 includes the direct caller).
 * Returns the number of frames captured. */
size_t run_stacktrace_capture(run_stack_entry_t *out, size_t max_count, size_t skip);

#endif
