#include "run_fmt.h"

#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void run_fmt_println(run_string_t s) {
    if (s.len > 0) {
        fwrite(s.ptr, 1, s.len, stdout);
    }
    putchar('\n');
}

void run_fmt_print(run_string_t s) {
    if (s.len > 0) {
        fwrite(s.ptr, 1, s.len, stdout);
    }
}

void run_fmt_newline(void) {
    putchar('\n');
}

void run_fmt_print_int(int64_t v) {
    printf("%" PRId64, v);
}

void run_fmt_print_float(double v) {
    printf("%g", v);
}

void run_fmt_print_bool(bool v) {
    fputs(v ? "true" : "false", stdout);
}

static int run_fmt_vsnprintf(char *buf, size_t buf_size, const char *fmt, va_list args) {
    int n = vsnprintf(buf, buf_size, fmt, args);
    if (n < 0) {
        fprintf(stderr, "run: invalid format string\n");
        return -1;
    }
    return n;
}

static int run_fmt_vprintf(const char *fmt, va_list args) {
    int n = vprintf(fmt, args);
    if (n < 0) {
        fprintf(stderr, "run: invalid format string\n");
    }
    return n;
}

int run_fmt_printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int out = run_fmt_vprintf(fmt, args);
    va_end(args);
    return out;
}

int run_fmt_printfln(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int out = run_fmt_vprintf(fmt, args);
    va_end(args);

    if (out < 0) {
        return out;
    }

    putchar('\n');
    return out + 1;
}

run_string_t run_fmt_sprintf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    va_list args_copy;
    va_copy(args_copy, args);

    int needed = run_fmt_vsnprintf(NULL, 0, fmt, args);
    va_end(args);

    if (needed < 0) {
        va_end(args_copy);
        return (run_string_t){.ptr = NULL, .len = 0};
    }

    char *buf = malloc((size_t)needed + 1);
    if (!buf) {
        fprintf(stderr, "run: out of memory in run_fmt_sprintf\n");
        abort();
    }

    int written = run_fmt_vsnprintf(buf, (size_t)needed + 1, fmt, args_copy);
    va_end(args_copy);

    if (written < 0) {
        free(buf);
        return (run_string_t){.ptr = NULL, .len = 0};
    }

    return (run_string_t){
        .ptr = buf,
        .len = (size_t)written,
    };
}

int run_fmt_snprintf(char *buf, size_t buf_size, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int out = run_fmt_vsnprintf(buf, buf_size, fmt, args);
    va_end(args);
    return out;
}

// ── Dynamic buffer for building formatted strings ───────────────────────────

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} fmt_buf_t;

static void run_fmt_buf_init(fmt_buf_t *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static void run_fmt_buf_grow(fmt_buf_t *b, size_t extra) {
    if (b->len + extra <= b->cap) {
        return;
    }
    size_t new_cap = b->cap == 0 ? 64 : b->cap;
    while (new_cap < b->len + extra) {
        new_cap *= 2;
    }
    char *new_data = realloc(b->data, new_cap);
    if (!new_data) {
        fprintf(stderr, "run: out of memory\n");
        abort();
    }
    b->data = new_data;
    b->cap = new_cap;
}

static void run_fmt_buf_append(fmt_buf_t *b, const char *s, size_t n) {
    if (n == 0)
        return;
    run_fmt_buf_grow(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
}

static void run_fmt_buf_append_cstr(fmt_buf_t *b, const char *s) {
    run_fmt_buf_append(b, s, strlen(s));
}

static run_string_t run_fmt_buf_to_string(fmt_buf_t *b) {
    if (b->len == 0) {
        free(b->data);
        return (run_string_t){.ptr = NULL, .len = 0};
    }
    // Shrink to fit
    char *final = realloc(b->data, b->len);
    if (!final)
        final = b->data;
    return (run_string_t){.ptr = final, .len = b->len};
}

// ── Default formatting of any value ─────────────────────────────────────────

static void run_fmt_any_default(fmt_buf_t *b, const run_any_t *a) {
    char tmp[64];
    switch (a->tag) {
    case RUN_ANY_INT: {
        int n = snprintf(tmp, sizeof(tmp), "%" PRId64, a->val.i);
        if (n > 0)
            run_fmt_buf_append(b, tmp, (size_t)n);
        break;
    }
    case RUN_ANY_FLOAT: {
        int n = snprintf(tmp, sizeof(tmp), "%g", a->val.f);
        if (n > 0)
            run_fmt_buf_append(b, tmp, (size_t)n);
        break;
    }
    case RUN_ANY_STRING:
        run_fmt_buf_append(b, a->val.s.ptr, a->val.s.len);
        break;
    case RUN_ANY_BOOL:
        run_fmt_buf_append_cstr(b, a->val.b ? "true" : "false");
        break;
    }
}

// ── Go-style format verb processing ─────────────────────────────────────────

// Parse a format verb starting after '%'. Returns the number of chars consumed
// from fmt (not counting the '%'). Appends formatted output to buf.
// If arg_idx >= nargs, appends %!(MISSING) instead.
static size_t run_fmt_process_verb(fmt_buf_t *buf, const char *fmt, size_t fmt_len,
                                   const run_any_t *args, size_t nargs, size_t *arg_idx) {
    if (fmt_len == 0) {
        run_fmt_buf_append_cstr(buf, "%!(NOVERB)");
        return 0;
    }

    // Parse optional flags, width, precision into a C format spec
    char spec[32];
    size_t spec_len = 0;
    spec[spec_len++] = '%';

    size_t pos = 0;

    // Flags: -, +, 0, space, #
    while (pos < fmt_len) {
        char c = fmt[pos];
        if (c == '-' || c == '+' || c == '0' || c == ' ' || c == '#') {
            if (spec_len < sizeof(spec) - 4)
                spec[spec_len++] = c;
            pos++;
        } else {
            break;
        }
    }

    // Width
    while (pos < fmt_len && fmt[pos] >= '0' && fmt[pos] <= '9') {
        if (spec_len < sizeof(spec) - 4)
            spec[spec_len++] = fmt[pos];
        pos++;
    }

    // Precision
    if (pos < fmt_len && fmt[pos] == '.') {
        if (spec_len < sizeof(spec) - 4)
            spec[spec_len++] = '.';
        pos++;
        while (pos < fmt_len && fmt[pos] >= '0' && fmt[pos] <= '9') {
            if (spec_len < sizeof(spec) - 4)
                spec[spec_len++] = fmt[pos];
            pos++;
        }
    }

    if (pos >= fmt_len) {
        run_fmt_buf_append_cstr(buf, "%!(NOVERB)");
        return pos;
    }

    char verb = fmt[pos];
    pos++;

    // %% is a literal %
    if (verb == '%') {
        run_fmt_buf_append(buf, "%", 1);
        return pos;
    }

    // All other verbs consume an argument
    if (*arg_idx >= nargs) {
        run_fmt_buf_append_cstr(buf, "%!(MISSING)");
        return pos;
    }

    const run_any_t *a = &args[*arg_idx];
    (*arg_idx)++;

    char tmp[256];

    switch (verb) {
    case 'v': {
        // %v: default format — ignore width/precision for simplicity on v
        run_fmt_any_default(buf, a);
        break;
    }
    case 'd': {
        spec[spec_len++] = PRId64[0];
        if (sizeof(PRId64) > 1)
            spec[spec_len++] = PRId64[1];
        if (sizeof(PRId64) > 2)
            spec[spec_len++] = PRId64[2];
        spec[spec_len] = '\0';
        int64_t val = (a->tag == RUN_ANY_INT)     ? a->val.i
                      : (a->tag == RUN_ANY_FLOAT) ? (int64_t)a->val.f
                      : (a->tag == RUN_ANY_BOOL)  ? (int64_t)a->val.b
                                                  : 0;
        int n = snprintf(tmp, sizeof(tmp), spec, val);
        if (n > 0)
            run_fmt_buf_append(buf, tmp, (size_t)n);
        break;
    }
    case 's': {
        if (a->tag == RUN_ANY_STRING) {
            // Apply width formatting to string
            int width = 0;
            bool left_align = false;
            // Re-parse width from spec for manual padding
            size_t si = 1; // skip '%'
            if (si < spec_len && spec[si] == '-') {
                left_align = true;
                si++;
            }
            while (si < spec_len && spec[si] >= '0' && spec[si] <= '9') {
                width = width * 10 + (spec[si] - '0');
                si++;
            }
            if (width > 0 && (size_t)width > a->val.s.len) {
                size_t pad = (size_t)width - a->val.s.len;
                if (left_align) {
                    run_fmt_buf_append(buf, a->val.s.ptr, a->val.s.len);
                    for (size_t p = 0; p < pad; p++)
                        run_fmt_buf_append(buf, " ", 1);
                } else {
                    for (size_t p = 0; p < pad; p++)
                        run_fmt_buf_append(buf, " ", 1);
                    run_fmt_buf_append(buf, a->val.s.ptr, a->val.s.len);
                }
            } else {
                run_fmt_buf_append(buf, a->val.s.ptr, a->val.s.len);
            }
        } else {
            run_fmt_any_default(buf, a);
        }
        break;
    }
    case 'f': {
        spec[spec_len++] = 'f';
        spec[spec_len] = '\0';
        double val = (a->tag == RUN_ANY_FLOAT) ? a->val.f
                     : (a->tag == RUN_ANY_INT) ? (double)a->val.i
                                               : 0.0;
        int n = snprintf(tmp, sizeof(tmp), spec, val);
        if (n > 0)
            run_fmt_buf_append(buf, tmp, (size_t)n);
        break;
    }
    case 'e': {
        spec[spec_len++] = 'e';
        spec[spec_len] = '\0';
        double val = (a->tag == RUN_ANY_FLOAT) ? a->val.f
                     : (a->tag == RUN_ANY_INT) ? (double)a->val.i
                                               : 0.0;
        int n = snprintf(tmp, sizeof(tmp), spec, val);
        if (n > 0)
            run_fmt_buf_append(buf, tmp, (size_t)n);
        break;
    }
    case 'g': {
        spec[spec_len++] = 'g';
        spec[spec_len] = '\0';
        double val = (a->tag == RUN_ANY_FLOAT) ? a->val.f
                     : (a->tag == RUN_ANY_INT) ? (double)a->val.i
                                               : 0.0;
        int n = snprintf(tmp, sizeof(tmp), spec, val);
        if (n > 0)
            run_fmt_buf_append(buf, tmp, (size_t)n);
        break;
    }
    case 't': {
        bool val = (a->tag == RUN_ANY_BOOL)  ? a->val.b
                   : (a->tag == RUN_ANY_INT) ? (a->val.i != 0)
                                             : false;
        run_fmt_buf_append_cstr(buf, val ? "true" : "false");
        break;
    }
    case 'x': {
        spec[spec_len++] = PRIx64[0];
        if (sizeof(PRIx64) > 1)
            spec[spec_len++] = PRIx64[1];
        if (sizeof(PRIx64) > 2)
            spec[spec_len++] = PRIx64[2];
        spec[spec_len] = '\0';
        int64_t val = (a->tag == RUN_ANY_INT)     ? a->val.i
                      : (a->tag == RUN_ANY_FLOAT) ? (int64_t)a->val.f
                                                  : 0;
        int n = snprintf(tmp, sizeof(tmp), spec, val);
        if (n > 0)
            run_fmt_buf_append(buf, tmp, (size_t)n);
        break;
    }
    case 'o': {
        spec[spec_len++] = PRIo64[0];
        if (sizeof(PRIo64) > 1)
            spec[spec_len++] = PRIo64[1];
        if (sizeof(PRIo64) > 2)
            spec[spec_len++] = PRIo64[2];
        spec[spec_len] = '\0';
        int64_t val = (a->tag == RUN_ANY_INT)     ? a->val.i
                      : (a->tag == RUN_ANY_FLOAT) ? (int64_t)a->val.f
                                                  : 0;
        int n = snprintf(tmp, sizeof(tmp), spec, val);
        if (n > 0)
            run_fmt_buf_append(buf, tmp, (size_t)n);
        break;
    }
    case 'b': {
        // Binary format — not in C printf, do it manually
        uint64_t val = (a->tag == RUN_ANY_INT)     ? (uint64_t)a->val.i
                       : (a->tag == RUN_ANY_FLOAT) ? (uint64_t)a->val.f
                                                   : 0;
        if (val == 0) {
            run_fmt_buf_append(buf, "0", 1);
        } else {
            char bin[65];
            int bi = 64;
            bin[bi] = '\0';
            while (val > 0 && bi > 0) {
                bin[--bi] = (val & 1) ? '1' : '0';
                val >>= 1;
            }
            run_fmt_buf_append_cstr(buf, &bin[bi]);
        }
        break;
    }
    case 'c': {
        int64_t val = (a->tag == RUN_ANY_INT) ? a->val.i : 0;
        if (val >= 0 && val <= 127) {
            char ch = (char)val;
            run_fmt_buf_append(buf, &ch, 1);
        }
        break;
    }
    default: {
        // Unknown verb
        run_fmt_buf_append(buf, "%!", 2);
        run_fmt_buf_append(buf, &verb, 1);
        run_fmt_buf_append(buf, "(BAD)", 5);
        break;
    }
    }

    return pos;
}

// Core format function: parses Go-style format string and writes to buffer.
static void run_fmt_format_to_buf(fmt_buf_t *buf, const char *fmt, size_t fmt_len,
                                  const run_any_t *args, size_t nargs) {
    size_t arg_idx = 0;
    size_t i = 0;
    size_t literal_start = 0;

    while (i < fmt_len) {
        if (fmt[i] == '%') {
            // Flush literal segment
            if (i > literal_start) {
                run_fmt_buf_append(buf, fmt + literal_start, i - literal_start);
            }
            i++; // skip '%'
            size_t consumed =
                run_fmt_process_verb(buf, fmt + i, fmt_len - i, args, nargs, &arg_idx);
            i += consumed;
            literal_start = i;
        } else {
            i++;
        }
    }

    // Flush remaining literal
    if (i > literal_start) {
        run_fmt_buf_append(buf, fmt + literal_start, i - literal_start);
    }

    // Extra args
    while (arg_idx < nargs) {
        run_fmt_buf_append_cstr(buf, "%!(EXTRA ");
        run_fmt_any_default(buf, &args[arg_idx]);
        run_fmt_buf_append(buf, ")", 1);
        arg_idx++;
    }
}

void run_fmt_printf_args(run_string_t format, const run_any_t *args, size_t nargs) {
    fmt_buf_t buf;
    run_fmt_buf_init(&buf);
    run_fmt_format_to_buf(&buf, format.ptr, format.len, args, nargs);
    if (buf.len > 0) {
        fwrite(buf.data, 1, buf.len, stdout);
    }
    free(buf.data);
}

run_string_t run_fmt_sprintf_args(run_string_t format, const run_any_t *args, size_t nargs) {
    fmt_buf_t buf;
    run_fmt_buf_init(&buf);
    run_fmt_format_to_buf(&buf, format.ptr, format.len, args, nargs);
    return run_fmt_buf_to_string(&buf);
}

void run_fmt_println_args(const run_any_t *args, size_t nargs) {
    for (size_t i = 0; i < nargs; i++) {
        if (i > 0)
            putchar(' ');
        fmt_buf_t buf;
        run_fmt_buf_init(&buf);
        run_fmt_any_default(&buf, &args[i]);
        if (buf.len > 0)
            fwrite(buf.data, 1, buf.len, stdout);
        free(buf.data);
    }
    putchar('\n');
}

void run_fmt_print_args(const run_any_t *args, size_t nargs) {
    for (size_t i = 0; i < nargs; i++) {
        fmt_buf_t buf;
        run_fmt_buf_init(&buf);
        run_fmt_any_default(&buf, &args[i]);
        if (buf.len > 0)
            fwrite(buf.data, 1, buf.len, stdout);
        free(buf.data);
    }
}

run_string_t run_fmt_sprint_args(const run_any_t *args, size_t nargs) {
    fmt_buf_t buf;
    run_fmt_buf_init(&buf);
    for (size_t i = 0; i < nargs; i++) {
        run_fmt_any_default(&buf, &args[i]);
    }
    return run_fmt_buf_to_string(&buf);
}

run_string_t run_fmt_sprintln_args(const run_any_t *args, size_t nargs) {
    fmt_buf_t buf;
    run_fmt_buf_init(&buf);
    for (size_t i = 0; i < nargs; i++) {
        if (i > 0)
            run_fmt_buf_append(&buf, " ", 1);
        run_fmt_any_default(&buf, &args[i]);
    }
    run_fmt_buf_append(&buf, "\n", 1);
    return run_fmt_buf_to_string(&buf);
}
