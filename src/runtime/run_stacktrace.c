#include "run_stacktrace.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__) || defined(__linux__)
#define UNW_LOCAL_ONLY
#include <dlfcn.h>
#include <libunwind.h>
#endif

#if defined(__APPLE__) || defined(__linux__)
static void run_stacktrace_apply_file_line(run_stack_entry_t *entry, char *text) {
    if (!entry || !text)
        return;

    text[strcspn(text, "\r\n")] = '\0';
    char *colon = strrchr(text, ':');
    if (!colon)
        return;

    char *line_start = colon + 1;
    char *line_end = line_start;
    while (*line_end >= '0' && *line_end <= '9') {
        line_end++;
    }
    if (line_end == line_start)
        return;

    char saved = *line_end;
    *line_end = '\0';
    long line = strtol(line_start, NULL, 10);
    *line_end = saved;
    if (line <= 0)
        return;

    char *file_start = text;
    char *open = NULL;
    for (char *p = text; p < colon; p++) {
        if (*p == '(') {
            open = p;
        }
    }
    if (open) {
        file_start = open + 1;
    }
    while (*file_start == ' ' || *file_start == '\t') {
        file_start++;
    }
    *colon = '\0';

    if (*file_start != '\0') {
        strncpy(entry->file, file_start, sizeof(entry->file) - 1);
        entry->file[sizeof(entry->file) - 1] = '\0';
    }
    entry->line = (int64_t)line;
}

static void run_stacktrace_symbolize_source(run_stack_entry_t *entry, const Dl_info *dl,
                                            unw_word_t ip) {
    if (!entry || !dl || !dl->dli_fname || !dl->dli_fbase)
        return;

    char cmd[2048];
#if defined(__APPLE__)
    int n = snprintf(cmd, sizeof(cmd), "atos -o '%s' -l 0x%llx 0x%llx", dl->dli_fname,
                     (unsigned long long)(uintptr_t)dl->dli_fbase, (unsigned long long)ip);
#else
    unsigned long long offset = (unsigned long long)(ip - (unw_word_t)(uintptr_t)dl->dli_fbase);
    int n = snprintf(cmd, sizeof(cmd), "addr2line -f -C -e '%s' 0x%llx", dl->dli_fname, offset);
#endif
    if (n <= 0 || (size_t)n >= sizeof(cmd))
        return;

    FILE *pipe = popen(cmd, "r");
    if (!pipe)
        return;

    char line[1024];
#if defined(__linux__)
    /* addr2line prints function name first, then file:line. */
    if (!fgets(line, sizeof(line), pipe)) {
        pclose(pipe);
        return;
    }
#endif
    if (fgets(line, sizeof(line), pipe)) {
        run_stacktrace_apply_file_line(entry, line);
    }
    pclose(pipe);
}
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
                run_stacktrace_symbolize_source(e, &dl, ip);
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
