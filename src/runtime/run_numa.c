#include "run_numa.h"

#include "run_scheduler.h"
#include "run_vmem.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ========================================================================
 * Global Topology State
 * ======================================================================== */

static run_numa_topology_t topology;

/* ========================================================================
 * Linux Implementation
 * ======================================================================== */

#if defined(__linux__)

#include <sched.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

/* mbind constants — defined inline to avoid requiring numaif.h / libnuma-dev */
#define RUN_MPOL_BIND 2

/* Parse a CPU list string like "0-3,8-11" into cpu_ids array.
 * Returns the number of CPUs parsed. */
static uint32_t parse_cpulist(const char *str, uint32_t *cpu_ids, uint32_t max_cpus) {
    uint32_t count = 0;
    const char *p = str;

    while (*p && count < max_cpus) {
        char *end;
        unsigned long start = strtoul(p, &end, 10);
        if (end == p)
            break;

        if (*end == '-') {
            p = end + 1;
            unsigned long range_end = strtoul(p, &end, 10);
            for (unsigned long cpu = start; cpu <= range_end && count < max_cpus; cpu++) {
                cpu_ids[count++] = (uint32_t)cpu;
            }
        } else {
            cpu_ids[count++] = (uint32_t)start;
        }

        p = end;
        if (*p == ',')
            p++;
    }
    return count;
}

/* Read a small sysfs file into buf. Returns bytes read or -1 on error. */
static int read_sysfs(const char *path, char *buf, size_t buf_size) {
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    size_t n = fread(buf, 1, buf_size - 1, f);
    fclose(f);
    buf[n] = '\0';
    /* Strip trailing newline */
    if (n > 0 && buf[n - 1] == '\n')
        buf[n - 1] = '\0';
    return (int)n;
}

void run_numa_init(void) {
    if (topology.initialized)
        return;

    memset(&topology, 0, sizeof(topology));
    char path[256];
    char buf[4096];

    /* Discover nodes by probing /sys/devices/system/node/node<N> */
    for (uint32_t n = 0; n < RUN_NUMA_MAX_NODES; n++) {
        snprintf(path, sizeof(path), "/sys/devices/system/node/node%u/cpulist", n);
        if (read_sysfs(path, buf, sizeof(buf)) < 0)
            break;

        run_numa_node_t *node = &topology.nodes[topology.node_count];
        node->node_id = n;
        node->cpu_count = parse_cpulist(buf, node->cpu_ids, RUN_NUMA_MAX_CPUS);

        /* Build reverse mapping */
        for (uint32_t i = 0; i < node->cpu_count; i++) {
            uint32_t cpu = node->cpu_ids[i];
            if (cpu < RUN_NUMA_MAX_CPUS) {
                topology.cpu_to_node[cpu] = n;
                if (cpu + 1 > topology.total_cpus)
                    topology.total_cpus = cpu + 1;
            }
        }

        /* Read memory info */
        snprintf(path, sizeof(path), "/sys/devices/system/node/node%u/meminfo", n);
        if (read_sysfs(path, buf, sizeof(buf)) >= 0) {
            /* Look for "MemTotal:" line */
            const char *mt = strstr(buf, "MemTotal:");
            if (mt) {
                mt += 9; /* skip "MemTotal:" */
                while (*mt == ' ')
                    mt++;
                node->memory_bytes = (uint64_t)strtoull(mt, NULL, 10) * 1024; /* kB -> bytes */
            }
        }

        topology.node_count++;
    }

    /* Read inter-node distances */
    for (uint32_t n = 0; n < topology.node_count; n++) {
        snprintf(path, sizeof(path), "/sys/devices/system/node/node%u/distance", n);
        if (read_sysfs(path, buf, sizeof(buf)) >= 0) {
            const char *p = buf;
            for (uint32_t m = 0; m < topology.node_count && *p; m++) {
                char *end;
                unsigned long d = strtoul(p, &end, 10);
                topology.distances[n][m] = (uint32_t)d;
                p = end;
                while (*p == ' ')
                    p++;
            }
        }
    }

    /* Fallback: if no nodes found, create a single UMA node */
    if (topology.node_count == 0) {
        topology.node_count = 1;
        topology.nodes[0].node_id = 0;
        long ncpus = sysconf(_SC_NPROCESSORS_ONLN);
        if (ncpus <= 0)
            ncpus = 1;
        topology.nodes[0].cpu_count = (uint32_t)ncpus;
        for (uint32_t i = 0; i < (uint32_t)ncpus && i < RUN_NUMA_MAX_CPUS; i++) {
            topology.nodes[0].cpu_ids[i] = i;
            topology.cpu_to_node[i] = 0;
        }
        topology.total_cpus = (uint32_t)ncpus;
        topology.distances[0][0] = 10;
    }

    topology.initialized = true;
}

uint32_t run_numa_current_node(void) {
    int cpu = sched_getcpu();
    if (cpu < 0 || (uint32_t)cpu >= RUN_NUMA_MAX_CPUS)
        return 0;
    return topology.cpu_to_node[(uint32_t)cpu];
}

void *run_numa_alloc_on_node(size_t size, uint32_t node_id) {
    void *ptr = run_vmem_alloc(size);
    if (!ptr)
        return NULL;

    if (topology.node_count <= 1)
        return ptr; /* UMA — no binding needed */

    /* Build nodemask for mbind */
    unsigned long nodemask = 0;
    if (node_id < 64) {
        nodemask = 1UL << node_id;
    }

    /* mbind(ptr, size, MPOL_BIND, &nodemask, maxnode, 0) */
    long ret =
        syscall(__NR_mbind, ptr, size, RUN_MPOL_BIND, &nodemask, (unsigned long)node_id + 2, 0);
    if (ret != 0) {
        /* mbind failed — memory still usable, just not bound to node */
        fprintf(stderr, "run: numa mbind failed for node %u (non-fatal)\n", node_id);
    }

    return ptr;
}

void run_numa_free(void *ptr, size_t size) {
    run_vmem_free(ptr, size);
}

int run_numa_bind_thread(uint32_t node_id) {
    uint32_t cpu_count;
    const uint32_t *cpus = run_numa_cpus_on_node(node_id, &cpu_count);
    if (!cpus || cpu_count == 0)
        return -1;

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    for (uint32_t i = 0; i < cpu_count; i++) {
        CPU_SET(cpus[i], &cpuset);
    }
    if (pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset) != 0)
        return -1;
    return 0;
}

int run_numa_set_memory_policy(uint32_t policy, uint32_t node_id) {
    unsigned long nodemask = 0;
    unsigned long maxnode = 0;
    int linux_policy;

    switch (policy) {
    case RUN_NUMA_POLICY_LOCAL:
        linux_policy = 0; /* MPOL_DEFAULT */
        break;
    case RUN_NUMA_POLICY_BIND:
        linux_policy = 2; /* MPOL_BIND */
        if (node_id < 64)
            nodemask = 1UL << node_id;
        maxnode = (unsigned long)node_id + 2;
        break;
    case RUN_NUMA_POLICY_INTERLEAVE:
        linux_policy = 3; /* MPOL_INTERLEAVE */
        for (uint32_t i = 0; i < topology.node_count && i < 64; i++)
            nodemask |= (1UL << i);
        maxnode = topology.node_count + 1;
        break;
    case RUN_NUMA_POLICY_PREFERRED:
        linux_policy = 1; /* MPOL_PREFERRED */
        if (node_id < 64)
            nodemask = 1UL << node_id;
        maxnode = (unsigned long)node_id + 2;
        break;
    default:
        return -1;
    }

    long ret = syscall(__NR_set_mempolicy, linux_policy, nodemask ? &nodemask : NULL, maxnode);
    return (ret == 0) ? 0 : -1;
}

/* ========================================================================
 * macOS Implementation (UMA)
 * ======================================================================== */

#elif defined(__APPLE__)

#include <unistd.h>

void run_numa_init(void) {
    if (topology.initialized)
        return;

    memset(&topology, 0, sizeof(topology));

    /* Apple Silicon is UMA — single node with all CPUs */
    topology.node_count = 1;
    topology.nodes[0].node_id = 0;

    long ncpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpus <= 0)
        ncpus = 1;

    topology.nodes[0].cpu_count = (uint32_t)ncpus;
    for (uint32_t i = 0; i < (uint32_t)ncpus && i < RUN_NUMA_MAX_CPUS; i++) {
        topology.nodes[0].cpu_ids[i] = i;
        topology.cpu_to_node[i] = 0;
    }
    topology.total_cpus = (uint32_t)ncpus;
    topology.distances[0][0] = 10;
    topology.nodes[0].memory_bytes = 0; /* Not easily queryable */

    topology.initialized = true;
}

uint32_t run_numa_current_node(void) {
    return 0; /* Always node 0 on UMA */
}

void *run_numa_alloc_on_node(size_t size, uint32_t node_id) {
    (void)node_id;
    return run_vmem_alloc(size);
}

void run_numa_free(void *ptr, size_t size) {
    run_vmem_free(ptr, size);
}

int run_numa_bind_thread(uint32_t node_id) {
    (void)node_id;
    return 0; /* No per-thread CPU pinning API on macOS */
}

int run_numa_set_memory_policy(uint32_t policy, uint32_t node_id) {
    (void)policy;
    (void)node_id;
    return 0; /* UMA — no memory policy on macOS */
}

/* ========================================================================
 * Windows Implementation
 * ======================================================================== */

#elif defined(_WIN32)

void run_numa_init(void) {
    if (topology.initialized)
        return;

    memset(&topology, 0, sizeof(topology));
    topology.node_count = 1;
    topology.total_cpus = (uint32_t)run_cpu_count();
    if (topology.total_cpus == 0)
        topology.total_cpus = 1;
    if (topology.total_cpus > RUN_NUMA_MAX_CPUS)
        topology.total_cpus = RUN_NUMA_MAX_CPUS;
    topology.nodes[0].node_id = 0;
    topology.nodes[0].cpu_count = topology.total_cpus;
    for (uint32_t cpu = 0; cpu < topology.total_cpus; cpu++) {
        topology.nodes[0].cpu_ids[cpu] = cpu;
        topology.cpu_to_node[cpu] = 0;
    }
    topology.distances[0][0] = 10;
    topology.initialized = true;
}

uint32_t run_numa_current_node(void) {
    return 0;
}

void *run_numa_alloc_on_node(size_t size, uint32_t node_id) {
    (void)node_id;
    return run_vmem_alloc(size);
}

void run_numa_free(void *ptr, size_t size) {
    run_vmem_free(ptr, size);
}

int run_numa_bind_thread(uint32_t node_id) {
    return node_id == 0 ? 0 : -1;
}

int run_numa_set_memory_policy(uint32_t policy, uint32_t node_id) {
    (void)policy;
    (void)node_id;
    return 0; /* Windows does not expose per-thread memory policy */
}

#elif defined(__wasi__)

void run_numa_init(void) {
    if (topology.initialized)
        return;

    memset(&topology, 0, sizeof(topology));
    topology.node_count = 1;
    topology.total_cpus = 1;
    topology.nodes[0].node_id = 0;
    topology.nodes[0].cpu_count = 1;
    topology.nodes[0].cpu_ids[0] = 0;
    topology.cpu_to_node[0] = 0;
    topology.distances[0][0] = 10;
    topology.initialized = true;
}

uint32_t run_numa_current_node(void) {
    return 0;
}

void *run_numa_alloc_on_node(size_t size, uint32_t node_id) {
    (void)node_id;
    return run_vmem_alloc(size);
}

void run_numa_free(void *ptr, size_t size) {
    run_vmem_free(ptr, size);
}

int run_numa_bind_thread(uint32_t node_id) {
    (void)node_id;
    return 0;
}

int run_numa_set_memory_policy(uint32_t policy, uint32_t node_id) {
    (void)policy;
    (void)node_id;
    return 0;
}

#endif

/* ========================================================================
 * Platform-Independent Query Functions
 * ======================================================================== */

uint32_t run_numa_node_count(void) {
    return topology.node_count;
}

const uint32_t *run_numa_cpus_on_node(uint32_t node_id, uint32_t *out_count) {
    if (node_id >= topology.node_count) {
        if (out_count)
            *out_count = 0;
        return NULL;
    }
    if (out_count)
        *out_count = topology.nodes[node_id].cpu_count;
    return topology.nodes[node_id].cpu_ids;
}

uint32_t run_numa_distance(uint32_t node_a, uint32_t node_b) {
    if (node_a >= topology.node_count || node_b >= topology.node_count)
        return 0;
    return topology.distances[node_a][node_b];
}

uint64_t run_numa_memory_on_node(uint32_t node_id) {
    if (node_id >= topology.node_count)
        return 0;
    return topology.nodes[node_id].memory_bytes;
}

/* ========================================================================
 * NUMA Allocator Vtable
 * ======================================================================== */

static void *run_numa_alloc_fn(void *ctx, size_t size) {
    uint32_t node_id = (uint32_t)(uintptr_t)ctx;
    return run_numa_alloc_on_node(size, node_id);
}

static void run_numa_free_fn(void *ctx, void *ptr, size_t size) {
    (void)ctx;
    run_numa_free(ptr, size);
}

run_allocator_t run_numa_allocator(uint32_t node_id) {
    return (run_allocator_t){
        .alloc_fn = run_numa_alloc_fn,
        .free_fn = run_numa_free_fn,
        // NOLINTNEXTLINE(performance-no-int-to-ptr): node_id packed into ctx pointer
        .ctx = (void *)(uintptr_t)node_id,
    };
}

/* ========================================================================
 * Extended NUMA API (Platform-Independent)
 * ======================================================================== */

bool run_numa_available(void) {
    return topology.node_count > 1;
}

int32_t run_numa_preferred_node(void) {
    run_g_t *g = run_current_g();
    if (!g)
        return -1;
    return g->preferred_node;
}

void *run_numa_local_alloc(size_t size) {
    return run_numa_alloc_on_node(size, run_numa_current_node());
}

void *run_numa_node_alloc(uint32_t node_id, size_t size) {
    return run_numa_alloc_on_node(size, node_id);
}

void *run_numa_interleave_alloc(size_t size) {
    static _Thread_local uint32_t next_node = 0;
    uint32_t node = next_node % topology.node_count;
    next_node++;
    return run_numa_alloc_on_node(size, node);
}

uint32_t run_numa_cpu_count(uint32_t node_id) {
    uint32_t count = 0;
    run_numa_cpus_on_node(node_id, &count);
    return count;
}
