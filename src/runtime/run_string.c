#include "run_string.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

run_string_t run_string_from_cstr(const char *s) {
    return (run_string_t){
        .ptr = s,
        .len = s ? strlen(s) : 0,
    };
}

run_string_t run_string_from_parts(const char *ptr, size_t len) {
    return (run_string_t){
        .ptr = ptr,
        .len = len,
    };
}

bool run_string_eq(run_string_t a, run_string_t b) {
    if (a.len != b.len)
        return false;
    if (a.ptr == b.ptr)
        return true;
    return memcmp(a.ptr, b.ptr, a.len) == 0;
}

run_string_t run_string_concat(run_string_t a, run_string_t b) {
    size_t total = a.len + b.len;
    char *buf = malloc(total);
    if (!buf) {
        fprintf(stderr, "run: out of memory in string concat\n");
        abort();
    }
    memcpy(buf, a.ptr, a.len);
    memcpy(buf + a.len, b.ptr, b.len);
    return (run_string_t){
        .ptr = buf,
        .len = total,
    };
}

void run_string_print(run_string_t s) {
    if (s.len > 0) {
        fwrite(s.ptr, 1, s.len, stdout);
    }
}
