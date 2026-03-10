#include "run_map.h"

#include "run_string.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ========================================================================
 * Hash Map — Open Addressing with Robin Hood Hashing
 *
 * Robin Hood hashing improves clustering by stealing from rich buckets
 * (those close to their home) to give to poor ones (those far displaced).
 * This gives O(1) amortized lookups with good cache behavior.
 * ======================================================================== */

#define RUN_MAP_INITIAL_CAP 8
#define RUN_MAP_LOAD_FACTOR 75 /* percentage: resize at 75% full */
#define RUN_MAP_TOMBSTONE_FLAG 0x80000000u

typedef struct {
    uint64_t hash; /* cached hash value */
    uint32_t psl;  /* probe sequence length (distance from home bucket) */
    bool occupied; /* true if this bucket holds a live entry */
    /* Followed in memory by: key bytes, then value bytes (stored in entries array) */
} run_map_bucket_t;

struct run_map {
    run_map_bucket_t *buckets; /* array of bucket metadata */
    char *entries;             /* packed array of (key, value) pairs */
    size_t capacity;           /* number of buckets */
    size_t count;              /* number of live entries */
    size_t key_size;
    size_t val_size;
    size_t entry_size; /* key_size + val_size */
    run_hash_fn hash_fn;
    run_eq_fn eq_fn;
};

/* ========================================================================
 * Built-in Hash Functions
 * ======================================================================== */

/* FNV-1a hash for arbitrary bytes */
static uint64_t fnv1a(const void *data, size_t len) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < len; i++) {
        hash ^= bytes[i];
        hash *= 0x100000001b3ULL;
    }
    return hash;
}

uint64_t run_hash_int(const void *key, size_t key_size) {
    return fnv1a(key, key_size);
}

uint64_t run_hash_string(const void *key, size_t key_size) {
    (void)key_size;
    /* key is a run_string_t */
    const run_string_t *s = (const run_string_t *)key;
    return fnv1a(s->ptr, s->len);
}

bool run_eq_int(const void *a, const void *b, size_t key_size) {
    return memcmp(a, b, key_size) == 0;
}

bool run_eq_string(const void *a, const void *b, size_t key_size) {
    (void)key_size;
    const run_string_t *sa = (const run_string_t *)a;
    const run_string_t *sb = (const run_string_t *)b;
    if (sa->len != sb->len)
        return false;
    return memcmp(sa->ptr, sb->ptr, sa->len) == 0;
}

/* ========================================================================
 * Internal Helpers
 * ======================================================================== */

static inline void *entry_key(run_map_t *map, size_t idx) {
    return map->entries + idx * map->entry_size;
}

static inline void *entry_val(run_map_t *map, size_t idx) {
    return map->entries + idx * map->entry_size + map->key_size;
}

static uint64_t map_hash(run_map_t *map, const void *key) {
    if (map->hash_fn)
        return map->hash_fn(key, map->key_size);
    return fnv1a(key, map->key_size);
}

static bool map_eq(run_map_t *map, const void *a, const void *b) {
    if (map->eq_fn)
        return map->eq_fn(a, b, map->key_size);
    return memcmp(a, b, map->key_size) == 0;
}

static void map_resize(run_map_t *map, size_t new_cap);

/* ========================================================================
 * Map Creation / Destruction
 * ======================================================================== */

run_map_t *run_map_new(size_t key_size, size_t val_size, run_hash_fn hash_fn, run_eq_fn eq_fn) {
    run_map_t *map = (run_map_t *)calloc(1, sizeof(run_map_t));
    if (!map) {
        fprintf(stderr, "run: failed to allocate map\n");
        abort();
    }

    map->key_size = key_size;
    map->val_size = val_size;
    map->entry_size = key_size + val_size;
    map->hash_fn = hash_fn;
    map->eq_fn = eq_fn;
    map->capacity = RUN_MAP_INITIAL_CAP;
    map->count = 0;

    map->buckets = (run_map_bucket_t *)calloc(map->capacity, sizeof(run_map_bucket_t));
    map->entries = (char *)calloc(map->capacity, map->entry_size);
    if (!map->buckets || !map->entries) {
        fprintf(stderr, "run: failed to allocate map storage\n");
        abort();
    }

    return map;
}

void run_map_free(run_map_t *map) {
    if (!map)
        return;
    free(map->buckets);
    free(map->entries);
    free(map);
}

/* ========================================================================
 * Resize
 * ======================================================================== */

static void map_resize(run_map_t *map, size_t new_cap) {
    run_map_bucket_t *old_buckets = map->buckets;
    char *old_entries = map->entries;
    size_t old_cap = map->capacity;

    map->capacity = new_cap;
    map->count = 0;
    map->buckets = (run_map_bucket_t *)calloc(new_cap, sizeof(run_map_bucket_t));
    map->entries = (char *)calloc(new_cap, map->entry_size);
    if (!map->buckets || !map->entries) {
        fprintf(stderr, "run: failed to resize map\n");
        abort();
    }

    /* Re-insert all entries */
    for (size_t i = 0; i < old_cap; i++) {
        if (old_buckets[i].occupied) {
            void *key = old_entries + i * map->entry_size;
            void *val = old_entries + i * map->entry_size + map->key_size;
            run_map_set(map, key, val);
        }
    }

    free(old_buckets);
    free(old_entries);
}

/* ========================================================================
 * Set (Insert / Update)
 * ======================================================================== */

void run_map_set(run_map_t *map, const void *key, const void *val) {
    /* Check load factor */
    if (map->count * 100 >= map->capacity * RUN_MAP_LOAD_FACTOR) {
        map_resize(map, map->capacity * 2);
    }

    uint64_t hash = map_hash(map, key);
    size_t idx = hash & (map->capacity - 1); /* capacity is power of 2 */
    uint32_t psl = 0;

    /* Temporary entry for Robin Hood swapping */
    char *temp_entry = NULL;
    uint64_t insert_hash = hash;
    uint32_t insert_psl = psl;

    /* Copy key+val into a temp buffer for potential swapping */
    char entry_buf[512]; /* stack buffer for small entries */
    char *insert_data;
    if (map->entry_size <= sizeof(entry_buf)) {
        insert_data = entry_buf;
    } else {
        temp_entry = (char *)malloc(map->entry_size);
        insert_data = temp_entry;
    }
    memcpy(insert_data, key, map->key_size);
    memcpy(insert_data + map->key_size, val, map->val_size);

    while (1) {
        if (!map->buckets[idx].occupied) {
            /* Empty bucket — insert here */
            map->buckets[idx].hash = insert_hash;
            map->buckets[idx].psl = insert_psl;
            map->buckets[idx].occupied = true;
            memcpy(entry_key(map, idx), insert_data, map->entry_size);
            map->count++;
            free(temp_entry);
            return;
        }

        /* Check if this is the same key (update) */
        if (map->buckets[idx].hash == insert_hash &&
            map_eq(map, entry_key(map, idx), insert_data)) {
            /* Update value in place */
            memcpy(entry_val(map, idx), insert_data + map->key_size, map->val_size);
            free(temp_entry);
            return;
        }

        /* Robin Hood: if current entry is richer (lower PSL), swap */
        if (map->buckets[idx].psl < insert_psl) {
            /* Swap bucket metadata */
            uint64_t tmp_hash = map->buckets[idx].hash;
            uint32_t tmp_psl = map->buckets[idx].psl;
            map->buckets[idx].hash = insert_hash;
            map->buckets[idx].psl = insert_psl;
            insert_hash = tmp_hash;
            insert_psl = tmp_psl;

            /* Swap entry data */
            /* Use a second temp buffer */
            char swap_buf[512];
            char *swap_data;
            if (map->entry_size <= sizeof(swap_buf)) {
                swap_data = swap_buf;
            } else {
                swap_data = (char *)malloc(map->entry_size);
            }
            memcpy(swap_data, entry_key(map, idx), map->entry_size);
            memcpy(entry_key(map, idx), insert_data, map->entry_size);
            memcpy(insert_data, swap_data, map->entry_size);
            if (swap_data != swap_buf)
                free(swap_data);
        }

        idx = (idx + 1) & (map->capacity - 1);
        insert_psl++;
    }
}

/* ========================================================================
 * Get (Lookup)
 * ======================================================================== */

bool run_map_get(run_map_t *map, const void *key, void *val_out) {
    if (map->count == 0)
        return false;

    uint64_t hash = map_hash(map, key);
    size_t idx = hash & (map->capacity - 1);
    uint32_t psl = 0;

    while (1) {
        if (!map->buckets[idx].occupied)
            return false;
        if (map->buckets[idx].psl < psl)
            return false; /* Robin Hood early termination */

        if (map->buckets[idx].hash == hash && map_eq(map, entry_key(map, idx), key)) {
            if (val_out) {
                memcpy(val_out, entry_val(map, idx), map->val_size);
            }
            return true;
        }

        idx = (idx + 1) & (map->capacity - 1);
        psl++;
    }
}

/* ========================================================================
 * Delete
 * ======================================================================== */

bool run_map_delete(run_map_t *map, const void *key) {
    if (map->count == 0)
        return false;

    uint64_t hash = map_hash(map, key);
    size_t idx = hash & (map->capacity - 1);
    uint32_t psl = 0;

    while (1) {
        if (!map->buckets[idx].occupied)
            return false;
        if (map->buckets[idx].psl < psl)
            return false;

        if (map->buckets[idx].hash == hash && map_eq(map, entry_key(map, idx), key)) {
            /* Found — remove and backward-shift */
            map->buckets[idx].occupied = false;
            map->count--;

            /* Backward shift: move subsequent entries back to fill the gap */
            size_t next = (idx + 1) & (map->capacity - 1);
            while (map->buckets[next].occupied && map->buckets[next].psl > 0) {
                map->buckets[idx] = map->buckets[next];
                map->buckets[idx].psl--;
                memcpy(entry_key(map, idx), entry_key(map, next), map->entry_size);

                map->buckets[next].occupied = false;
                idx = next;
                next = (next + 1) & (map->capacity - 1);
            }

            return true;
        }

        idx = (idx + 1) & (map->capacity - 1);
        psl++;
    }
}

/* ========================================================================
 * Length
 * ======================================================================== */

size_t run_map_len(run_map_t *map) {
    return map->count;
}

/* ========================================================================
 * Iteration
 * ======================================================================== */

void run_map_iter_init(run_map_iter_t *iter, run_map_t *map) {
    iter->map = map;
    iter->index = 0;
}

bool run_map_iter_next(run_map_iter_t *iter, const void **key_out, const void **val_out) {
    run_map_t *map = iter->map;
    while (iter->index < map->capacity) {
        size_t i = iter->index++;
        if (map->buckets[i].occupied) {
            if (key_out)
                *key_out = entry_key(map, i);
            if (val_out)
                *val_out = entry_val(map, i);
            return true;
        }
    }
    return false;
}
