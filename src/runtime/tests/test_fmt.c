#include "test_framework.h"
#include "../run_fmt.h"

#include <stdlib.h>

static void test_sprintf_basic_types(void) {
    run_string_t out = run_fmt_sprintf("int=%d float=%.2f bool=%s char=%c str=%s", 42, 3.14159, "true", 'x', "ok");
    RUN_ASSERT(out.ptr != NULL);
    RUN_ASSERT_EQ(out.len, 41);
    RUN_ASSERT_STR_EQ(out.ptr, "int=42 float=3.14 bool=true char=x str=ok");
    free((void *)out.ptr);
}

static void test_snprintf_width_precision(void) {
    char buf[32] = {0};
    int n = run_fmt_snprintf(buf, sizeof(buf), "|%8.2f|", 12.3);
    RUN_ASSERT_EQ(n, 10);
    RUN_ASSERT_STR_EQ(buf, "|   12.30|");
}

static void test_snprintf_truncation_reports_full_size(void) {
    char buf[6] = {0};
    int n = run_fmt_snprintf(buf, sizeof(buf), "abcdefghi");
    RUN_ASSERT_EQ(n, 9);
    RUN_ASSERT_STR_EQ(buf, "abcde");
}

static void test_printf_and_printfln_counts(void) {
    int n1 = run_fmt_printf("%s", "");
    RUN_ASSERT_EQ(n1, 0);

    int n2 = run_fmt_printfln("%s", "");
    RUN_ASSERT_EQ(n2, 1);
}

void run_test_fmt(void) {
    TEST_SUITE("fmt");
    RUN_TEST(test_sprintf_basic_types);
    RUN_TEST(test_snprintf_width_precision);
    RUN_TEST(test_snprintf_truncation_reports_full_size);
    RUN_TEST(test_printf_and_printfln_counts);
}
