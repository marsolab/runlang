#include "test_framework.h"
#include "../run_map.h"
#include <string.h>

static void test_map_create_free(void) {
    run_map_t *m = run_map_new(sizeof(int64_t), sizeof(int64_t), NULL, NULL);
    RUN_ASSERT(m != NULL);
    RUN_ASSERT_EQ(run_map_len(m), 0);
    run_map_free(m);
}

static void test_map_set_get(void) {
    run_map_t *m = run_map_new(sizeof(int64_t), sizeof(int64_t), run_hash_int, run_eq_int);

    int64_t key = 42, val = 100;
    run_map_set(m, &key, &val);
    RUN_ASSERT_EQ(run_map_len(m), 1);

    int64_t out = 0;
    bool found = run_map_get(m, &key, &out);
    RUN_ASSERT(found);
    RUN_ASSERT_EQ(out, 100);

    /* Non-existent key */
    int64_t missing = 999;
    found = run_map_get(m, &missing, &out);
    RUN_ASSERT(!found);

    run_map_free(m);
}

static void test_map_update(void) {
    run_map_t *m = run_map_new(sizeof(int64_t), sizeof(int64_t), run_hash_int, run_eq_int);

    int64_t key = 1, val1 = 10, val2 = 20;
    run_map_set(m, &key, &val1);
    run_map_set(m, &key, &val2);

    RUN_ASSERT_EQ(run_map_len(m), 1);

    int64_t out = 0;
    run_map_get(m, &key, &out);
    RUN_ASSERT_EQ(out, 20);

    run_map_free(m);
}

static void test_map_delete(void) {
    run_map_t *m = run_map_new(sizeof(int64_t), sizeof(int64_t), run_hash_int, run_eq_int);

    int64_t k1 = 1, v1 = 10;
    int64_t k2 = 2, v2 = 20;
    run_map_set(m, &k1, &v1);
    run_map_set(m, &k2, &v2);
    RUN_ASSERT_EQ(run_map_len(m), 2);

    bool deleted = run_map_delete(m, &k1);
    RUN_ASSERT(deleted);
    RUN_ASSERT_EQ(run_map_len(m), 1);

    int64_t out = 0;
    RUN_ASSERT(!run_map_get(m, &k1, &out));
    RUN_ASSERT(run_map_get(m, &k2, &out));
    RUN_ASSERT_EQ(out, 20);

    /* Delete non-existent */
    int64_t missing = 999;
    RUN_ASSERT(!run_map_delete(m, &missing));

    run_map_free(m);
}

static void test_map_many_entries(void) {
    run_map_t *m = run_map_new(sizeof(int64_t), sizeof(int64_t), run_hash_int, run_eq_int);

    /* Insert 100 entries — triggers multiple resizes */
    for (int64_t i = 0; i < 100; i++) {
        int64_t val = i * 10;
        run_map_set(m, &i, &val);
    }
    RUN_ASSERT_EQ(run_map_len(m), 100);

    /* Verify all entries */
    for (int64_t i = 0; i < 100; i++) {
        int64_t out = 0;
        bool found = run_map_get(m, &i, &out);
        RUN_ASSERT(found);
        RUN_ASSERT_EQ(out, i * 10);
    }

    /* Delete even keys */
    for (int64_t i = 0; i < 100; i += 2) {
        run_map_delete(m, &i);
    }
    RUN_ASSERT_EQ(run_map_len(m), 50);

    /* Verify odd keys still present, even keys gone */
    for (int64_t i = 0; i < 100; i++) {
        int64_t out = 0;
        bool found = run_map_get(m, &i, &out);
        if (i % 2 == 0) {
            RUN_ASSERT(!found);
        } else {
            RUN_ASSERT(found);
            RUN_ASSERT_EQ(out, i * 10);
        }
    }

    run_map_free(m);
}

static void test_map_iteration(void) {
    run_map_t *m = run_map_new(sizeof(int64_t), sizeof(int64_t), run_hash_int, run_eq_int);

    for (int64_t i = 0; i < 5; i++) {
        int64_t val = i * 100;
        run_map_set(m, &i, &val);
    }

    run_map_iter_t iter;
    run_map_iter_init(&iter, m);

    int count = 0;
    int64_t sum = 0;
    const void *key, *val;
    while (run_map_iter_next(&iter, &key, &val)) {
        sum += *(const int64_t *)val;
        count++;
    }

    RUN_ASSERT_EQ(count, 5);
    RUN_ASSERT_EQ(sum, 0 + 100 + 200 + 300 + 400);

    run_map_free(m);
}

void run_test_map(void) {
    TEST_SUITE("run_map");
    RUN_TEST(test_map_create_free);
    RUN_TEST(test_map_set_get);
    RUN_TEST(test_map_update);
    RUN_TEST(test_map_delete);
    RUN_TEST(test_map_many_entries);
    RUN_TEST(test_map_iteration);
}
