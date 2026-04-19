#include "run_stacktrace.h"

#include <stddef.h>
#include <string.h>

#if defined(__APPLE__) || defined(__linux__)
#define UNW_LOCAL_ONLY
#include <dlfcn.h>
#include <libunwind.h>
#endif

size_t run_stacktrace_capture(run_stack_entry_t *out, size_t max_count, size_t skip) {
    if (!out || max_count == 0)
        return 0;

#if defined(__APPLE__) || defined(__linux__)
    unw_context_t ctx;
    unw_cursor_t cursor;

    if (unw_getcontext(&ctx) != 0)
        return 0;
    if (unw_init_local(&cursor, &ctx) != 0)
        return 0;

    /* unw_init_local places the cursor at unw_getcontext's caller (us).
     * Step once to skip this function itself. */
    if (unw_step(&cursor) <= 0)
        return 0;

    size_t skipped = 0;
    size_t count = 0;
    while (count < max_count) {
        unw_word_t ip = 0;
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) != 0 || ip == 0)
            break;

        if (skipped < skip) {
            skipped++;
        } else {
            run_stack_entry_t *e = &out[count];
            e->ip = (void *)(uintptr_t)ip;
            e->function[0] = '\0';
            e->file[0] = '\0';
            e->line = 0;

            unw_word_t offset = 0;
            /* unw_get_proc_name truncates on overflow (ENOMEM) but still
             * writes a null-terminated prefix, which is fine for display. */
            (void)unw_get_proc_name(&cursor, e->function, sizeof(e->function), &offset);

            Dl_info dl;
            if (dladdr(e->ip, &dl)) {
                if (dl.dli_fname) {
                    strncpy(e->file, dl.dli_fname, sizeof(e->file) - 1);
                    e->file[sizeof(e->file) - 1] = '\0';
                }
                /* Prefer dladdr's symbol name when libunwind couldn't resolve. */
                if (e->function[0] == '\0' && dl.dli_sname) {
                    strncpy(e->function, dl.dli_sname, sizeof(e->function) - 1);
                    e->function[sizeof(e->function) - 1] = '\0';
                }
            }

            count++;
        }

        if (unw_step(&cursor) <= 0)
            break;
    }

    return count;
#else
    (void)out;
    (void)max_count;
    (void)skip;
    return 0;
#endif
}
