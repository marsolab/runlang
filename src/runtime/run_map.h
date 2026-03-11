#ifndef RUN_MAP_H
#define RUN_MAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct run_map run_map_t;

/* Hash function signature: takes key pointer and key size, returns hash. */
typedef uint64_t (*run_hash_fn)(const void *key, size_t key_size);

/* Comparison function: returns true if keys are equal. */
typedef bool (*run_eq_fn)(const void *a, const void *b, size_t key_size);

/* Built-in hash functions */
uint64_t run_hash_int(const void *key, size_t key_size);
uint64_t run_hash_string(const void *key, size_t key_size);

/* Built-in equality functions */
bool run_eq_int(const void *a, const void *b, size_t key_size);
bool run_eq_string(const void *a, const void *b, size_t key_size);

/* Create a new map.
 * key_size: size of key type in bytes
 * val_size: size of value type in bytes
 * hash_fn: hash function (NULL uses default byte-wise hash)
 * eq_fn: equality function (NULL uses memcmp) */
run_map_t *run_map_new(size_t key_size, size_t val_size, run_hash_fn hash_fn, run_eq_fn eq_fn);

/* Insert or update a key-value pair. */
void run_map_set(run_map_t *map, const void *key, const void *val);

/* Look up a key. Returns true if found, copies value to val_out. */
bool run_map_get(run_map_t *map, const void *key, void *val_out);

/* Delete a key. Returns true if the key was found and removed. */
bool run_map_delete(run_map_t *map, const void *key);

/* Return the number of entries in the map. */
size_t run_map_len(run_map_t *map);

/* Free the map and all its entries. */
void run_map_free(run_map_t *map);

/* ---------- Iteration ---------- */

typedef struct {
    run_map_t *map;
    size_t index; /* current bucket index */
} run_map_iter_t;

/* Initialize an iterator over the map. */
void run_map_iter_init(run_map_iter_t *iter, run_map_t *map);

/* Advance the iterator. Returns true if a key-value pair was found.
 * key_out and val_out are set to point into the map's internal storage
 * (valid until the next mutation). */
bool run_map_iter_next(run_map_iter_t *iter, const void **key_out, const void **val_out);

#endif
