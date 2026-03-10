#ifndef TEST_FRAMEWORK_H
#define TEST_FRAMEWORK_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Minimal C test framework for the Run runtime.
 * Counters are extern — defined in test_main.c. */

extern int _test_total;
extern int _test_passed;
extern int _test_failed;
extern const char *_test_current;

#define RUN_TEST(name)                              \
    do {                                            \
        _test_total++;                              \
        _test_current = #name;                      \
        printf("  %-50s ", #name);                  \
        fflush(stdout);                             \
        name();                                     \
        _test_passed++;                             \
        printf("[PASS]\n");                         \
    } while (0)

#define RUN_ASSERT(cond)                            \
    do {                                            \
        if (!(cond)) {                              \
            printf("[FAIL]\n");                     \
            fprintf(stderr,                         \
                "    ASSERT FAILED: %s\n"           \
                "    at %s:%d in %s\n",             \
                #cond, __FILE__, __LINE__,          \
                _test_current);                     \
            _test_failed++;                         \
            _test_passed--; /* undo pre-increment */\
            return;                                 \
        }                                           \
    } while (0)

#define RUN_ASSERT_EQ(a, b)                         \
    do {                                            \
        long long _a = (long long)(a);              \
        long long _b = (long long)(b);              \
        if (_a != _b) {                             \
            printf("[FAIL]\n");                     \
            fprintf(stderr,                         \
                "    ASSERT_EQ FAILED: %s == %s\n"  \
                "    expected: %lld\n"               \
                "    actual:   %lld\n"               \
                "    at %s:%d\n",                    \
                #a, #b, _b, _a,                     \
                __FILE__, __LINE__);                 \
            _test_failed++;                         \
            _test_passed--;                         \
            return;                                 \
        }                                           \
    } while (0)

#define RUN_ASSERT_STR_EQ(a, b)                     \
    do {                                            \
        if (strcmp((a), (b)) != 0) {                \
            printf("[FAIL]\n");                     \
            fprintf(stderr,                         \
                "    ASSERT_STR_EQ FAILED\n"        \
                "    expected: \"%s\"\n"             \
                "    actual:   \"%s\"\n"             \
                "    at %s:%d\n",                    \
                (b), (a), __FILE__, __LINE__);       \
            _test_failed++;                         \
            _test_passed--;                         \
            return;                                 \
        }                                           \
    } while (0)

#define TEST_SUITE(name)                            \
    printf("\n=== %s ===\n", name)

#define TEST_SUMMARY()                              \
    do {                                            \
        printf("\n--- Results ---\n");              \
        printf("Total:  %d\n", _test_total);       \
        printf("Passed: %d\n", _test_passed);      \
        printf("Failed: %d\n", _test_failed);      \
        return _test_failed > 0 ? 1 : 0;           \
    } while (0)

#endif
