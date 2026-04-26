#include "run_stacktrace.h"

#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__) || defined(__linux__)
#define UNW_LOCAL_ONLY
#include <dlfcn.h>
#include <fcntl.h>
#include <libunwind.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#if defined(__linux__)
/* dl_iterate_phdr lives in <link.h> and needs _GNU_SOURCE, which build.zig
 * already defines globally for runtime sources. */
#include <link.h>
#include <stdint.h>

typedef struct {
    uintptr_t ip;
    unsigned long long elf_vma;
    int found;
} run_phdr_lookup_t;

/* Convert a runtime IP into the ELF VMA the linker assigned to that
 * instruction — the address `addr2line` expects. The runtime IP differs from
 * the ELF VMA by the module's ASLR slide minus the first PT_LOAD's p_vaddr;
 * iterating program headers is the standard way to recover both. */
static int run_phdr_lookup_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    run_phdr_lookup_t *q = (run_phdr_lookup_t *)data;
    for (uint16_t i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD)
            continue;
        uintptr_t seg_start = (uintptr_t)info->dlpi_addr + (uintptr_t)ph->p_vaddr;
        uintptr_t seg_end = seg_start + (uintptr_t)ph->p_memsz;
        if (q->ip >= seg_start && q->ip < seg_end) {
            q->elf_vma = (unsigned long long)(q->ip - (uintptr_t)info->dlpi_addr) + ph->p_vaddr;
            q->found = 1;
            return 1; /* stop iteration */
        }
    }
    return 0;
}
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

/* Spawn argv[0] with the given argv, capturing stdout into out_buf and stderr
 * into /dev/null. Replaces popen(3) so we don't invoke a command processor
 * (cert-env33-c) and don't have to escape the binary path into a shell string.
 * Returns the number of bytes read into out_buf (0 on any failure). */
static size_t run_stacktrace_spawn_capture(char *const argv[], char *out_buf, size_t out_cap) {
    if (out_cap == 0)
        return 0;
    out_buf[0] = '\0';

    int pipefd[2];
    if (pipe(pipefd) != 0)
        return 0;

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return 0;
    }
    if (pid == 0) {
        /* Child: only async-signal-safe calls between fork and exec. */
        close(pipefd[0]);
        if (dup2(pipefd[1], STDOUT_FILENO) < 0)
            _exit(127);
        if (pipefd[1] != STDOUT_FILENO)
            close(pipefd[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            (void)dup2(devnull, STDERR_FILENO);
            if (devnull != STDERR_FILENO)
                close(devnull);
        }
        execvp(argv[0], argv);
        _exit(127);
    }

    close(pipefd[1]);
    size_t total = 0;
    for (;;) {
        if (total + 1 >= out_cap)
            break;
        ssize_t n = read(pipefd[0], out_buf + total, out_cap - 1 - total);
        if (n > 0) {
            total += (size_t)n;
            continue;
        }
        if (n == 0)
            break;
        if (errno == EINTR)
            continue;
        break;
    }
    /* Drain anything still buffered so the child doesn't get SIGPIPE. */
    char drain[256];
    while (read(pipefd[0], drain, sizeof(drain)) > 0) {
    }
    close(pipefd[0]);
    out_buf[total] = '\0';

    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    return total;
}

static void run_stacktrace_symbolize_source(run_stack_entry_t *entry, const Dl_info *dl,
                                            unw_word_t ip) {
    if (!entry || !dl || !dl->dli_fname || !dl->dli_fbase)
        return;

    char addr_buf[32];
#if defined(__APPLE__)
    char load_buf[32];
    snprintf(load_buf, sizeof(load_buf), "0x%llx", (unsigned long long)(uintptr_t)dl->dli_fbase);
    snprintf(addr_buf, sizeof(addr_buf), "0x%llx", (unsigned long long)ip);
    char *argv[] = {(char *)"atos", (char *)"-o", (char *)dl->dli_fname, (char *)"-l",
                    load_buf,       addr_buf,     (char *)NULL};
#else
    run_phdr_lookup_t q = {.ip = (uintptr_t)ip, .elf_vma = 0, .found = 0};
    dl_iterate_phdr(run_phdr_lookup_cb, &q);
    unsigned long long addr =
        q.found ? q.elf_vma : (unsigned long long)(ip - (unw_word_t)(uintptr_t)dl->dli_fbase);
    snprintf(addr_buf, sizeof(addr_buf), "0x%llx", addr);
    char *argv[] = {(char *)"addr2line",   (char *)"-f", (char *)"-C", (char *)"-e",
                    (char *)dl->dli_fname, addr_buf,     (char *)NULL};
#endif

    char output[1024];
    if (run_stacktrace_spawn_capture(argv, output, sizeof(output)) == 0)
        return;

#if defined(__linux__)
    /* addr2line prints function name first, then file:line. Skip the first
     * line and apply the second. */
    char *nl = strchr(output, '\n');
    if (!nl)
        return;
    char *file_line = nl + 1;
    char *end = strchr(file_line, '\n');
    if (end)
        *end = '\0';
    run_stacktrace_apply_file_line(entry, file_line);
#else
    /* atos prints a single line. */
    char *end = strchr(output, '\n');
    if (end)
        *end = '\0';
    run_stacktrace_apply_file_line(entry, output);
#endif
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
