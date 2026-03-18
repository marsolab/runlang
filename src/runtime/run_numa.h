#ifndef RUN_NUMA_H
#define RUN_NUMA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---------- Limits ---------- */

#define RUN_NUMA_MAX_NODES 64
#define RUN_NUMA_MAX_CPUS  1024

/* ---------- Topology Types ---------- */

typedef struct {
    uint32_t node_id;
    uint32_t cpu_ids[RUN_NUMA_MAX_CPUS];
    uint32_t cpu_count;
    uint64_t memory_bytes; /* total memory on this node (0 if unknown) */
} run_numa_node_t;

typedef struct {
    uint32_t node_count;
    run_numa_node_t nodes[RUN_NUMA_MAX_NODES];
    uint32_t distances[RUN_NUMA_MAX_NODES][RUN_NUMA_MAX_NODES];
    uint32_t cpu_to_node[RUN_NUMA_MAX_CPUS];
    uint32_t total_cpus;
    bool initialized;
} run_numa_topology_t;

/* ---------- Allocator Vtable ---------- */

typedef struct {
    void *(*alloc_fn)(void *ctx, size_t size);
    void (*free_fn)(void *ctx, void *ptr, size_t size);
    void *ctx;
} run_allocator_t;

/* ---------- Topology Discovery ---------- */

/* Initialize NUMA topology. Called once from run_scheduler_init(). */
void run_numa_init(void);

/* Number of NUMA nodes (>= 1). */
uint32_t run_numa_node_count(void);

/* NUMA node the current OS thread is running on. */
uint32_t run_numa_current_node(void);

/* CPU IDs belonging to a node. Returns pointer to internal array.
 * Sets *out_count to the number of CPUs. Returns NULL if node_id is invalid. */
const uint32_t *run_numa_cpus_on_node(uint32_t node_id, uint32_t *out_count);

/* Relative distance between two nodes (10 = local, higher = farther). */
uint32_t run_numa_distance(uint32_t node_a, uint32_t node_b);

/* Total memory on a node in bytes (0 if unknown). */
uint64_t run_numa_memory_on_node(uint32_t node_id);

/* ---------- NUMA-Aware Allocation ---------- */

/* Allocate page-aligned memory on a specific NUMA node.
 * Falls back to run_vmem_alloc() on UMA systems. Returns NULL on failure. */
void *run_numa_alloc_on_node(size_t size, uint32_t node_id);

/* Free memory allocated with run_numa_alloc_on_node(). */
void run_numa_free(void *ptr, size_t size);

/* Create an allocator bound to a specific NUMA node. */
run_allocator_t run_numa_allocator(uint32_t node_id);

#endif
