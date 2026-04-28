#include "run_scheduler.h"

#include "run_numa.h"
#include "run_poller.h"
#include "run_vmem.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__linux__) || defined(__APPLE__)
#include <signal.h>
#include <sys/time.h>
#endif

#if defined(__linux__)
#include <sched.h>
#include <ucontext.h>
#endif

/* ========================================================================
 * Configuration
 * ======================================================================== */

#define RUN_FIXED_STACK_SIZE ((size_t)64 * 1024) /* 64 KB per G (Phase 1) */
#define RUN_GUARD_PAGE_SIZE ((size_t)4 * 1024)   /* 4 KB guard at bottom */
#define RUN_SCHEDULER_STACK ((size_t)256 * 1024) /* 256 KB for g0 scheduler stack */
#define RUN_MAX_M_COUNT 10000
#define RUN_PREEMPT_INTERVAL_US 10000 /* 10ms preemption timer */

/* Default max for growable stacks */
#define RUN_DEFAULT_STACK_MAX ((size_t)1024 * 1024) /* 1 MB */
#define RUN_GROWABLE_INITIAL ((size_t)8 * 1024)     /* 8 KB initial commit */
#define RUN_STACK_SHRINK_THRESHOLD 4                /* shrink below 25% usage */
#define RUN_STACK_SHRINK_HYSTERESIS 2               /* keep 2x live usage */

/* ========================================================================
 * Thread-Local Storage
 * ======================================================================== */

static RUN_THREAD_LOCAL run_m_t *tls_current_m = NULL;

run_g_t *run_current_g(void) {
    return tls_current_m ? tls_current_m->current_g : NULL;
}

run_m_t *run_current_m(void) {
    return tls_current_m;
}

/* ========================================================================
 * Global Scheduler State
 * ======================================================================== */

static run_p_t all_ps[RUN_MAX_P_COUNT];
static uint32_t num_ps = 0;

/* Global run queue */
static run_g_queue_t global_queue;
static run_mutex_t global_queue_lock = RUN_MUTEX_INITIALIZER;

/* Idle lists */
static uint32_t idle_p_stack[RUN_MAX_P_COUNT]; /* stack of idle P indices */
static uint32_t idle_p_count = 0;
static run_mutex_t idle_p_lock = RUN_MUTEX_INITIALIZER;

/* All Ms */
static run_m_t *all_ms = NULL;
static uint32_t num_ms = 0;
static run_mutex_t all_ms_lock = RUN_MUTEX_INITIALIZER;

/* Idle Ms waiting to be woken */
static run_m_t *idle_m_head = NULL;
static run_mutex_t idle_m_lock = RUN_MUTEX_INITIALIZER;

/* G ID counter */
static _Atomic uint64_t next_g_id = 1;

/* Total live (non-DEAD) Gs — when this drops to 0, scheduler exits */
static _Atomic int64_t live_g_count = 0;

/* Growable stacks enabled flag */
#if defined(_WIN32)
static bool growable_stacks_enabled = false;
#else
static bool growable_stacks_enabled = true;
#endif
static size_t stack_max_size_cached = 0;

/* Multi-P scheduling enabled — lock-free local queues and atomic state. */
static bool scheduler_initialized = false;

/* Preemption timer active */
static bool preemption_timer_active = false;
#if defined(_WIN32)
static run_platform_timer_t preemption_timer;
#endif

/* Signal preemption active */
#if defined(__linux__) || defined(__APPLE__)
static bool signal_preemption_active = false;
static pthread_t signal_preemption_thread;
static _Atomic bool signal_preemption_thread_running = false;
#endif

/* Runtime metrics (#410) */
static run_metrics_t scheduler_metrics = {0};

/* Trace output enabled via RUN_TRACE=1 (#410) */
static bool trace_enabled = false;

static int64_t run_metrics_global_queue_len(void) {
    return (int64_t)run_global_queue_len();
}

static int64_t run_metrics_local_queue_len(void) {
    int64_t len = 0;
    for (uint32_t i = 0; i < num_ps; i++) {
        len += (int64_t)run_local_queue_len(&all_ps[i].local_queue);
    }
    return len;
}

static int64_t run_metrics_poll_waiter_count(void) {
    if (!scheduler_initialized)
        return 0;
    return run_poller_has_waiters() ? 1 : 0;
}

/* ========================================================================
 * G Queue Operations
 * ======================================================================== */

void run_g_queue_init(run_g_queue_t *q) {
    q->head = NULL;
    q->tail = NULL;
    q->len = 0;
}

void run_g_queue_push(run_g_queue_t *q, run_g_t *g) {
    g->sched_next = NULL;
    if (q->tail) {
        q->tail->sched_next = g;
    } else {
        q->head = g;
    }
    q->tail = g;
    q->len++;
}

run_g_t *run_g_queue_pop(run_g_queue_t *q) {
    run_g_t *g = q->head;
    if (g == NULL)
        return NULL;
    q->head = g->sched_next;
    if (q->head == NULL) {
        q->tail = NULL;
    }
    g->sched_next = NULL;
    q->len--;
    return g;
}

bool run_g_queue_remove(run_g_queue_t *q, run_g_t *g) {
    if (q->head == NULL)
        return false;

    if (q->head == g) {
        q->head = g->sched_next;
        if (q->head == NULL)
            q->tail = NULL;
        g->sched_next = NULL;
        q->len--;
        return true;
    }

    run_g_t *prev = q->head;
    while (prev->sched_next != NULL) {
        if (prev->sched_next == g) {
            prev->sched_next = g->sched_next;
            if (q->tail == g)
                q->tail = prev;
            g->sched_next = NULL;
            q->len--;
            return true;
        }
        prev = prev->sched_next;
    }
    return false;
}

/* ========================================================================
 * Lock-Free Local Run Queue (Chase-Lev deque)
 * ======================================================================== */

void run_local_queue_init(run_local_queue_t *q) {
    atomic_store_explicit(&q->head, 0, memory_order_relaxed);
    atomic_store_explicit(&q->tail, 0, memory_order_relaxed);
    memset((void *)q->buf, 0, sizeof(q->buf));
}

bool run_local_queue_push(run_local_queue_t *q, run_g_t *g) {
    uint32_t t = atomic_load_explicit(&q->tail, memory_order_relaxed);
    uint32_t h = atomic_load_explicit(&q->head, memory_order_acquire);
    if (t - h >= RUN_LOCAL_QUEUE_SIZE)
        return false; /* full */
    q->buf[t % RUN_LOCAL_QUEUE_SIZE] = g;
    atomic_store_explicit(&q->tail, t + 1, memory_order_release);
    return true;
}

run_g_t *run_local_queue_pop(run_local_queue_t *q) {
    uint32_t t = atomic_load_explicit(&q->tail, memory_order_relaxed);
    if (t == 0)
        return NULL;
    t--;
    atomic_store_explicit(&q->tail, t, memory_order_relaxed);
    atomic_thread_fence(memory_order_seq_cst);
    uint32_t h = atomic_load_explicit(&q->head, memory_order_relaxed);
    if ((int32_t)(t - h) < 0) {
        /* Queue was empty, restore tail */
        atomic_store_explicit(&q->tail, t + 1, memory_order_relaxed);
        return NULL;
    }
    run_g_t *g = q->buf[t % RUN_LOCAL_QUEUE_SIZE];
    if (t == h) {
        /* Last element — race with stealers */
        if (!atomic_compare_exchange_strong_explicit(&q->head, &h, h + 1, memory_order_seq_cst,
                                                     memory_order_relaxed)) {
            g = NULL;
        }
        atomic_store_explicit(&q->tail, t + 1, memory_order_relaxed);
    }
    return g;
}

run_g_t *run_local_queue_steal(run_local_queue_t *src, run_local_queue_t *dst) {
    uint32_t h = atomic_load_explicit(&src->head, memory_order_acquire);
    uint32_t t = atomic_load_explicit(&src->tail, memory_order_acquire);
    if ((int32_t)(t - h) <= 0)
        return NULL;
    run_g_t *g = src->buf[h % RUN_LOCAL_QUEUE_SIZE];
    if (!atomic_compare_exchange_strong_explicit(&src->head, &h, h + 1, memory_order_seq_cst,
                                                 memory_order_relaxed))
        return NULL;
    (void)dst; /* single-item steal for simplicity */
    return g;
}

uint32_t run_local_queue_len(run_local_queue_t *q) {
    uint32_t h = atomic_load_explicit(&q->head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&q->tail, memory_order_relaxed);
    return (int32_t)(t - h) > 0 ? t - h : 0;
}

/* ========================================================================
 * NUMA Thread Pinning
 * ======================================================================== */

static void run_pin_m_to_node(run_m_t *m, uint32_t node_id) {
#if defined(__linux__)
    uint32_t cpu_count;
    const uint32_t *cpus = run_numa_cpus_on_node(node_id, &cpu_count);
    if (cpu_count == 0)
        return;
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    for (uint32_t i = 0; i < cpu_count; i++) {
        CPU_SET((int)cpus[i], &cpuset);
    }
    pthread_setaffinity_np(m->thread, sizeof(cpuset), &cpuset);
#elif defined(_WIN32)
    (void)m;
    (void)node_id;
#else
    /* macOS: no per-thread CPU pinning API */
    (void)m;
    (void)node_id;
#endif
}

/* ========================================================================
 * Stack Allocation
 * ======================================================================== */

size_t run_stack_max_size(void) {
    if (stack_max_size_cached > 0)
        return stack_max_size_cached;
    const char *env = getenv("RUN_STACK_MAX");
    if (env) {
        size_t val = (size_t)strtol(env, NULL, 10);
        if (val >= RUN_GROWABLE_INITIAL) {
            stack_max_size_cached = val;
            return val;
        }
    }
    stack_max_size_cached = RUN_DEFAULT_STACK_MAX;
    return RUN_DEFAULT_STACK_MAX;
}

static void *run_stack_alloc(size_t *out_size, size_t *out_committed) {
    if (growable_stacks_enabled) {
        size_t max_size = run_stack_max_size();
        /* Reserve entire address range */
        void *mem = run_vmem_reserve(max_size);
        if (!mem) {
            fprintf(stderr, "run: failed to reserve stack (%zu bytes)\n", max_size);
            abort();
        }
        /* Commit initial pages at the TOP of the stack (stack grows down) */
        size_t initial = RUN_GROWABLE_INITIAL;
        void *commit_start = (char *)mem + max_size - initial;
        run_vmem_protect(commit_start, initial, RUN_VMEM_READWRITE);
        /* Guard page at the very bottom */
        /* (the rest of reserved-but-uncommitted space acts as guard) */
        *out_size = max_size;
        *out_committed = initial;
        return mem;
    } else {
        void *mem = run_vmem_alloc(RUN_FIXED_STACK_SIZE);
        if (!mem) {
            fprintf(stderr, "run: failed to allocate stack (%zu bytes)\n", RUN_FIXED_STACK_SIZE);
            abort();
        }
        /* Guard page at the bottom */
        run_vmem_protect(mem, RUN_GUARD_PAGE_SIZE, RUN_VMEM_NONE);
        *out_size = RUN_FIXED_STACK_SIZE;
        *out_committed = RUN_FIXED_STACK_SIZE;
        return mem;
    }
}

static void run_stack_free(void *base, size_t size) {
    run_vmem_free(base, size);
}

static char *run_stack_top(run_g_t *g) {
    return (char *)g->stack_base + g->stack_size;
}

static size_t run_align_up_size(size_t value, size_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static void *run_context_sp(run_context_t *ctx) {
#if defined(__aarch64__) || defined(__arm64__)
    return ctx->sp;
#else
    return ctx->rsp;
#endif
}

static void run_stack_record_sp(run_g_t *g, void *sp) {
    if (!g || !g->stack_base || !sp)
        return;
    char *top = run_stack_top(g);
    char *cur = (char *)sp;
    if (cur < (char *)g->stack_base || cur > top)
        return;
    size_t used = (size_t)(top - cur);
    if (used > g->stack_watermark) {
        g->stack_watermark = used;
    }
}

static void run_stack_grow_to_sp(run_g_t *g, void *sp) {
    if (!growable_stacks_enabled || !g || !g->stack_base || !sp)
        return;

    char *top = run_stack_top(g);
    char *cur = (char *)sp;
    if (cur < (char *)g->stack_base || cur > top) {
        fprintf(stderr, "run: stack overflow in green thread %llu (sp outside stack)\n",
                (unsigned long long)g->id);
        abort();
    }

    size_t page_size = run_vmem_page_size();
    size_t used = (size_t)(top - cur);
    size_t needed = run_align_up_size(used + page_size, page_size);
    if (needed <= g->stack_committed)
        return;

    size_t new_committed = g->stack_committed;
    while (new_committed < needed && new_committed < g->stack_size) {
        new_committed *= 2;
    }
    if (new_committed < needed || new_committed > g->stack_size) {
        fprintf(stderr, "run: stack overflow in green thread %llu (max %zu bytes)\n",
                (unsigned long long)g->id, g->stack_size);
        abort();
    }

    char *old_lo = top - g->stack_committed;
    char *new_lo = top - new_committed;
    run_vmem_protect(new_lo, (size_t)(old_lo - new_lo), RUN_VMEM_READWRITE);
    g->stack_committed = new_committed;
    g->stack_lo = new_lo;
}

static size_t run_stack_used_by_sp(run_g_t *g, void *sp) {
    if (!g || !g->stack_base || !sp)
        return 0;
    char *top = run_stack_top(g);
    char *cur = (char *)sp;
    if (cur < (char *)g->stack_base || cur > top)
        return 0;
    return (size_t)(top - cur);
}

static void run_stack_maybe_shrink(run_g_t *g, void *sp) {
    if (!growable_stacks_enabled || !g || !g->stack_base)
        return;
    if (g->stack_committed <= RUN_GROWABLE_INITIAL)
        return;

    size_t current_used = run_stack_used_by_sp(g, sp);
    size_t page_size = run_vmem_page_size();
    size_t watermark = run_align_up_size(g->stack_watermark, page_size);
    if (watermark < RUN_GROWABLE_INITIAL) {
        watermark = RUN_GROWABLE_INITIAL;
    }
    if (watermark * RUN_STACK_SHRINK_THRESHOLD > g->stack_committed) {
        g->stack_watermark = current_used;
        return;
    }

    size_t target = g->stack_committed / 2;
    size_t minimum = watermark * RUN_STACK_SHRINK_HYSTERESIS;
    if (target < minimum) {
        target = run_align_up_size(minimum, page_size);
    }
    if (target < RUN_GROWABLE_INITIAL) {
        target = RUN_GROWABLE_INITIAL;
    }
    if (target >= g->stack_committed)
        return;

    char *top = run_stack_top(g);
    char *old_lo = top - g->stack_committed;
    char *new_lo = top - target;
    size_t release_size = (size_t)(new_lo - old_lo);
    run_vmem_release(old_lo, release_size);
    run_vmem_protect(old_lo, release_size, RUN_VMEM_NONE);
    g->stack_committed = target;
    g->stack_lo = new_lo;
    g->stack_watermark = current_used;
}

/* Push to a P's local queue with overflow to the global queue. */
static void run_local_push_or_global(run_local_queue_t *lq, run_g_t *g) {
    if (!run_local_queue_push(lq, g)) {
        run_global_queue_push(g);
    }
}

/* ========================================================================
 * G Lifecycle
 * ======================================================================== */

static uint64_t run_alloc_g_id(void) {
    return atomic_fetch_add_explicit(&next_g_id, 1, memory_order_relaxed);
}

static run_g_t *run_g_alloc(void (*fn)(void *), void *arg) {
    run_g_t *g = (run_g_t *)calloc(1, sizeof(run_g_t));
    if (!g) {
        fprintf(stderr, "run: failed to allocate G struct\n");
        abort();
    }

    g->id = run_alloc_g_id();
    g->status = G_IDLE;
    g->entry_fn = fn;
    g->entry_arg = arg;
    g->preferred_node = -1;

    /* Allocate stack */
    g->stack_base = run_stack_alloc(&g->stack_size, &g->stack_committed);

    /* Stack top = base + size (stack grows downward) */
    void *stack_top = (char *)g->stack_base + g->stack_size;
    if (growable_stacks_enabled) {
        g->stack_lo = (char *)stack_top - g->stack_committed;
    } else {
        g->stack_lo = (char *)g->stack_base + RUN_GUARD_PAGE_SIZE;
    }
    g->stack_watermark = 0;

    /* Initialize context to start at entry function */
    run_context_init(&g->context, stack_top, fn, arg);

    g->status = G_RUNNABLE;
    return g;
}

static void run_g_free(run_g_t *g) {
    if (g->stack_base) {
        run_stack_free(g->stack_base, g->stack_size);
    }
    free(g);
}

/* ========================================================================
 * M Lifecycle
 * ======================================================================== */

static run_m_t *run_m_alloc(void) {
    run_m_t *m = (run_m_t *)calloc(1, sizeof(run_m_t));
    if (!m) {
        fprintf(stderr, "run: failed to allocate M struct\n");
        abort();
    }

    run_mutex_lock(&all_ms_lock);
    m->id = num_ms++;
    m->all_next = all_ms;
    all_ms = m;
    run_mutex_unlock(&all_ms_lock);

    run_mutex_init(&m->park_mutex);
    run_cond_init(&m->park_cond);
    m->parked = false;

    /* Allocate g0 (scheduler goroutine) with its own stack */
    m->g0 = (run_g_t *)calloc(1, sizeof(run_g_t));
    if (!m->g0)
        abort();
    m->g0->stack_base = run_vmem_alloc(RUN_SCHEDULER_STACK);
    if (!m->g0->stack_base) {
        fprintf(stderr, "run: failed to allocate scheduler stack\n");
        abort();
    }
    m->g0->stack_size = RUN_SCHEDULER_STACK;
    m->g0->status = G_RUNNING;
    m->g0->id = 0; /* special scheduler G */

    return m;
}

/* ========================================================================
 * P Operations
 * ======================================================================== */

static run_p_t *run_acquire_idle_p(void) {
    run_mutex_lock(&idle_p_lock);
    if (idle_p_count == 0) {
        run_mutex_unlock(&idle_p_lock);
        return NULL;
    }
    uint32_t idx = idle_p_stack[--idle_p_count];
    run_mutex_unlock(&idle_p_lock);

    run_p_t *p = &all_ps[idx];
    p->status = P_RUNNING;
    return p;
}

static bool run_has_idle_p(void) {
    run_mutex_lock(&idle_p_lock);
    bool has_idle = idle_p_count > 0;
    run_mutex_unlock(&idle_p_lock);
    return has_idle;
}

static void run_release_p(run_p_t *p) {
    p->status = P_IDLE;
    p->bound_m = NULL;
    run_mutex_lock(&idle_p_lock);
    idle_p_stack[idle_p_count++] = p->id;
    run_mutex_unlock(&idle_p_lock);
}

/* ========================================================================
 * Global Run Queue
 * ======================================================================== */

void run_global_queue_push(run_g_t *g) {
    run_mutex_lock(&global_queue_lock);
    run_g_queue_push(&global_queue, g);
    run_mutex_unlock(&global_queue_lock);
}

run_g_t *run_global_queue_pop(void) {
    run_mutex_lock(&global_queue_lock);
    run_g_t *g = run_g_queue_pop(&global_queue);
    run_mutex_unlock(&global_queue_lock);
    return g;
}

uint32_t run_global_queue_len(void) {
    run_mutex_lock(&global_queue_lock);
    uint32_t len = global_queue.len;
    run_mutex_unlock(&global_queue_lock);
    return len;
}

/* ========================================================================
 * Work Stealing (#86)
 * ======================================================================== */

/* Simple xorshift RNG for work stealing victim selection. */
static RUN_THREAD_LOCAL uint32_t steal_rng_state = 0;

static uint32_t run_steal_random(void) {
    if (steal_rng_state == 0) {
        /* Seed from thread ID */
        steal_rng_state = (uint32_t)run_thread_seed() ^ 0xDEADBEEF;
    }
    uint32_t x = steal_rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    steal_rng_state = x;
    return x;
}

/* Steal half of a victim P's local queue. Returns one G to run directly,
 * pushes the rest to self_p's queue. Returns NULL if nothing to steal. */
static run_g_t *run_steal_from_p(run_p_t *self_p, run_p_t *victim) {
    run_g_t *g = run_local_queue_steal(&victim->local_queue, &self_p->local_queue);
    if (g) {
        atomic_fetch_add_explicit(&scheduler_metrics.steal_count, 1, memory_order_relaxed);
        if (trace_enabled) {
            fprintf(stderr, "{\"event\":\"steal\",\"from_p\":%u,\"to_p\":%u}\n", victim->id,
                    self_p->id);
        }
    }
    return g;
}

static run_g_t *run_try_steal(run_p_t *self_p) {
    if (num_ps <= 1)
        return NULL;

    uint32_t my_node = self_p->numa_node;

    /* Phase 1: Try same-NUMA-node Ps first */
    uint32_t start = run_steal_random() % num_ps;
    for (uint32_t i = 0; i < num_ps; i++) {
        uint32_t idx = (start + i) % num_ps;
        if (idx == self_p->id)
            continue;
        if (all_ps[idx].numa_node != my_node)
            continue;

        run_g_t *g = run_steal_from_p(self_p, &all_ps[idx]);
        if (g)
            return g;
    }

    /* Phase 2: Try cross-NUMA-node Ps */
    start = run_steal_random() % num_ps;
    for (uint32_t i = 0; i < num_ps; i++) {
        uint32_t idx = (start + i) % num_ps;
        if (idx == self_p->id)
            continue;
        if (all_ps[idx].numa_node == my_node)
            continue; /* already tried */

        run_g_t *g = run_steal_from_p(self_p, &all_ps[idx]);
        if (g)
            return g;
    }

    return NULL;
}

/* ========================================================================
 * M Parking / Waking (#86)
 * ======================================================================== */

static void run_park_m(run_m_t *m) {
    atomic_fetch_add_explicit(&scheduler_metrics.park_count, 1, memory_order_relaxed);
    if (trace_enabled) {
        fprintf(stderr,
                "{\"event\":\"park\",\"m_id\":%llu,\"live_g\":%lld,"
                "\"global_queue\":%lld,\"local_queue\":%lld,\"poll_waiters\":%lld}\n",
                (unsigned long long)m->id,
                (long long)atomic_load_explicit(&live_g_count, memory_order_relaxed),
                (long long)run_metrics_global_queue_len(), (long long)run_metrics_local_queue_len(),
                (long long)run_metrics_poll_waiter_count());
    }
    run_mutex_lock(&m->park_mutex);
    m->parked = true;

    /* Add to idle M list */
    run_mutex_lock(&idle_m_lock);
    m->idle_next = idle_m_head;
    idle_m_head = m;
    run_mutex_unlock(&idle_m_lock);

    while (m->parked) {
        run_cond_wait(&m->park_cond, &m->park_mutex);
    }
    run_mutex_unlock(&m->park_mutex);
}

static void run_unpark_m(run_m_t *m) {
    atomic_fetch_add_explicit(&scheduler_metrics.unpark_count, 1, memory_order_relaxed);
    if (trace_enabled) {
        fprintf(stderr,
                "{\"event\":\"unpark\",\"m_id\":%llu,\"global_queue\":%lld,"
                "\"local_queue\":%lld,\"poll_waiters\":%lld}\n",
                (unsigned long long)m->id, (long long)run_metrics_global_queue_len(),
                (long long)run_metrics_local_queue_len(),
                (long long)run_metrics_poll_waiter_count());
    }
    run_mutex_lock(&m->park_mutex);
    m->parked = false;
    run_cond_signal(&m->park_cond);
    run_mutex_unlock(&m->park_mutex);
}

static void run_unpark_all_idle_ms(void) {
    run_mutex_lock(&idle_m_lock);
    run_m_t *m = idle_m_head;
    idle_m_head = NULL;
    run_mutex_unlock(&idle_m_lock);

    while (m != NULL) {
        run_m_t *next = m->idle_next;
        m->idle_next = NULL;
        run_unpark_m(m);
        m = next;
    }
}

void run_wake_m(void) {
    /* Try to wake an idle M */
    run_mutex_lock(&idle_m_lock);
    run_m_t *m = idle_m_head;
    if (m) {
        idle_m_head = m->idle_next;
        m->idle_next = NULL;
    }
    run_mutex_unlock(&idle_m_lock);

    if (m) {
        /* Get an idle P for this M */
        run_p_t *p = run_acquire_idle_p();
        if (p) {
            m->current_p = p;
            p->bound_m = m;
            run_unpark_m(m);
        } else {
            /* No idle P — put M back */
            run_mutex_lock(&idle_m_lock);
            m->idle_next = idle_m_head;
            idle_m_head = m;
            run_mutex_unlock(&idle_m_lock);
        }
        return;
    }

    /* No idle M — create a new one if under limit */
    run_mutex_lock(&all_ms_lock);
    uint32_t current_ms = num_ms;
    run_mutex_unlock(&all_ms_lock);

    if (current_ms >= RUN_MAX_M_COUNT)
        return;

    run_p_t *p = run_acquire_idle_p();
    if (!p)
        return;

    /* Forward declaration of the M thread entry */
    extern void *run_m_thread_entry(void *arg);

    run_m_t *new_m = run_m_alloc();
    new_m->current_p = p;
    p->bound_m = new_m;

    if (run_thread_create(&new_m->thread, run_m_thread_entry, new_m) != 0) {
        p->bound_m = NULL;
        run_release_p(p);
        return;
    }
    run_thread_detach(new_m->thread);
}

/* ========================================================================
 * Scheduling Core
 * ======================================================================== */

/* run_find_runnable: try local queue -> global queue -> poll I/O -> work stealing */
static run_g_t *run_find_runnable(run_p_t *p) {
    /* 1. Local queue */
    run_g_t *g = run_local_queue_pop(&p->local_queue);
    if (g)
        return g;

    /* 2. Global queue — take one (or batch) */
    g = run_global_queue_pop();
    if (g)
        return g;

    /* 3. Poll for I/O completions (non-blocking).
     * This may make Gs runnable by pushing them to run queues. */
    atomic_fetch_add_explicit(&scheduler_metrics.poll_count, 1, memory_order_relaxed);
    if (trace_enabled) {
        fprintf(stderr,
                "{\"event\":\"poll\",\"p_id\":%u,\"global_queue\":%lld,"
                "\"local_queue\":%lld,\"poll_waiters\":%lld}\n",
                p->id, (long long)run_metrics_global_queue_len(),
                (long long)run_metrics_local_queue_len(),
                (long long)run_metrics_poll_waiter_count());
    }
    if (run_poller_poll() > 0) {
        g = run_local_queue_pop(&p->local_queue);
        if (g)
            return g;
        g = run_global_queue_pop();
        if (g)
            return g;
    }

    /* 4. Work stealing */
    g = run_try_steal(p);
    if (g)
        return g;

    return NULL;
}

/* The core scheduling loop, runs on g0's stack. */
static void run_schedule_loop(run_m_t *m) {
    while (1) {
        run_p_t *p = m->current_p;
        if (!p) {
            /* Try to acquire an idle P */
            p = run_acquire_idle_p();
            if (!p) {
                /* Check if there's still work to do */
                int64_t count = atomic_load_explicit(&live_g_count, memory_order_acquire);
                if (count <= 0)
                    return; /* All done */

                /* Park this M until woken */
                run_park_m(m);
                continue;
            }
            m->current_p = p;
            p->bound_m = m;
        }

        run_g_t *g = run_find_runnable(p);
        if (!g) {
            /* No work found — check if all Gs are done */
            int64_t count = atomic_load_explicit(&live_g_count, memory_order_acquire);
            if (count <= 0) {
                run_release_p(p);
                m->current_p = NULL;
                return;
            }

            /* Before parking or aborting, check if Gs are waiting on I/O.
             * If so, do a blocking poll to wait for completions. */
            if (run_poller_has_waiters()) {
                if (run_poller_poll_blocking(-1) > 0) {
                    continue; /* Gs were woken — re-enter run_find_runnable */
                }
            }

            /* For multi-threaded: release P and park.
             * For single-threaded: just return (all Gs must be waiting). */
            if (num_ps > 1) {
                run_release_p(p);
                m->current_p = NULL;
                run_park_m(m);
                continue;
            } else {
                /* Single-threaded: if there are live Gs but none runnable
                 * and no I/O waiters, they are deadlocked. */
                fprintf(stderr, "run: all green threads are deadlocked\n");
                abort();
            }
        }

        /* Execute g */
        g->status = G_RUNNING;
        g->last_p = p;
        m->current_g = g;

        /* Context switch from g0 to g */
        atomic_fetch_add_explicit(&scheduler_metrics.context_switches, 1, memory_order_relaxed);
        if (trace_enabled) {
            fprintf(stderr,
                    "{\"event\":\"context_switch\",\"g_id\":%llu,\"p_id\":%u,"
                    "\"global_queue\":%lld,\"local_queue\":%lld}\n",
                    (unsigned long long)g->id, p->id, (long long)run_metrics_global_queue_len(),
                    (long long)run_metrics_local_queue_len());
        }
        run_context_switch(&m->g0->context, &g->context);

        /* Returned here: g yielded or completed */
        m->current_g = NULL;
        void *saved_sp = run_context_sp(&g->context);
        run_stack_record_sp(g, saved_sp);

        if (g->status == G_DEAD) {
            atomic_fetch_add_explicit(&scheduler_metrics.complete_count, 1, memory_order_relaxed);
            if (trace_enabled) {
                fprintf(stderr, "{\"event\":\"complete\",\"g_id\":%llu,\"live_g\":%lld}\n",
                        (unsigned long long)g->id,
                        (long long)atomic_load_explicit(&live_g_count, memory_order_relaxed) - 1);
            }
            int64_t remaining =
                atomic_fetch_sub_explicit(&live_g_count, 1, memory_order_release) - 1;
            if (remaining <= 0) {
                run_poller_wakeup();
                run_unpark_all_idle_ms();
            }
            run_g_free(g);
        } else {
            run_stack_maybe_shrink(g, saved_sp);
        }
        /* If g->status is G_RUNNABLE (yield), it's already re-enqueued.
         * If g->status is G_WAITING (channel), the channel code handles it. */
    }
}

/* M thread entry point (for dynamically created Ms in multi-threaded mode) */
void *run_m_thread_entry(void *arg) {
    run_m_t *m = (run_m_t *)arg;
    tls_current_m = m;

    /* Pin this M to CPUs on its P's NUMA node */
    if (m->current_p) {
        run_pin_m_to_node(m, m->current_p->numa_node);
    }

    run_schedule_loop(m);
    return NULL;
}

/* ========================================================================
 * Public API
 * ======================================================================== */

void run_scheduler_init(void) {
    if (scheduler_initialized)
        return;

    /* Discover NUMA topology before creating Ps */
    run_numa_init();

    /* Multi-P: default to CPU count. */
    {
        long cpus = run_cpu_count();
        num_ps = (cpus > 0 && cpus <= RUN_MAX_P_COUNT) ? (uint32_t)cpus : 1;
    }
    const char *maxprocs_env = getenv("RUN_MAXPROCS");
    if (maxprocs_env) {
        int n = (int)strtol(maxprocs_env, NULL, 10);
        if (n >= 1 && n <= RUN_MAX_P_COUNT) {
            num_ps = (uint32_t)n;
        }
    }

    /* Initialize all Ps and assign NUMA nodes round-robin */
    uint32_t numa_nodes = run_numa_node_count();
    for (uint32_t i = 0; i < num_ps; i++) {
        all_ps[i].id = i;
        all_ps[i].status = P_IDLE;
        run_local_queue_init(&all_ps[i].local_queue);
        all_ps[i].bound_m = NULL;
        all_ps[i].numa_node = i % numa_nodes;
    }

    /* Initialize global run queue */
    run_g_queue_init(&global_queue);

    /* All Ps except P[0] go to idle list */
    idle_p_count = 0;
    for (uint32_t i = 1; i < num_ps; i++) {
        idle_p_stack[idle_p_count++] = i;
    }

    /* Create M0 wrapping the main OS thread */
    run_m_t *m0 = run_m_alloc();
    m0->thread = run_thread_self();
    m0->current_p = &all_ps[0];
    all_ps[0].status = P_RUNNING;
    all_ps[0].bound_m = m0;

    tls_current_m = m0;

    /* Pin M0 to its P's NUMA node */
    run_pin_m_to_node(m0, all_ps[0].numa_node);

    /* Initialize the network poller (io_uring on Linux, kqueue on macOS) */
    run_poller_init();

    /* Install growable stack fault handling. RUN_STACK_MAX can override the
     * default reservation size, but stacks are growable by default. */
    run_stack_growth_init();

    /* Check for trace output (#410) */
    const char *trace_env = getenv("RUN_TRACE");
    if (trace_env && trace_env[0] == '1') {
        trace_enabled = true;
        fprintf(stderr, "{\"event\":\"scheduler_init\",\"num_ps\":%u}\n", num_ps);
    }

    scheduler_initialized = true;
}

void run_scheduler_run(void) {
    run_m_t *m = tls_current_m;
    if (!m)
        return;

    /* Start cooperative preemption timer if RUN_PREEMPT is set.
     * Cooperative preemption is only useful when codegen emits
     * run_preemption_check() at function prologues. */
    const char *preempt_env = getenv("RUN_PREEMPT");
    bool use_preemption = (preempt_env != NULL && preempt_env[0] == '1');

    if (use_preemption) {
        run_preemption_start();
    }

    /* Signal-based async preemption is always active for multi-P
     * configurations. It rewrites the PC to a trampoline that yields,
     * so it works even in tight loops without function calls. */
    if (num_ps > 1) {
        run_signal_preemption_start();
    }

    /* Ensure main M has a P before entering the schedule loop.
     * After a previous run, the P was released — re-acquire it. */
    if (!m->current_p) {
        run_p_t *p = run_acquire_idle_p();
        if (p) {
            m->current_p = p;
            p->bound_m = m;
        }
    }

    /* Run the scheduling loop */
    run_schedule_loop(m);

    /* Cleanup: stop preemption timers, but keep the poller alive.
     * The poller is initialized once in run_scheduler_init() and lives
     * for the process lifetime — closing it here would break subsequent
     * run_scheduler_run() calls (e.g. across tests) that still need to
     * register fds. The OS reclaims poller resources on process exit. */
    if (use_preemption) {
        run_preemption_stop();
    }
    run_signal_preemption_stop();
}

void run_spawn(void (*fn)(void *), void *arg) {
    atomic_fetch_add_explicit(&scheduler_metrics.spawn_count, 1, memory_order_relaxed);
    run_g_t *g = run_g_alloc(fn, arg);
    atomic_fetch_add_explicit(&live_g_count, 1, memory_order_release);

    /* Enqueue to current P's local queue, or global queue */
    run_m_t *m = tls_current_m;
    if (m && m->current_p) {
        run_local_push_or_global(&m->current_p->local_queue, g);
    } else if (m && m->current_g == NULL) {
        /* Called from main thread (outside scheduler loop).
         * Try to re-acquire an idle P so the G goes to the local queue
         * rather than spawning a new M thread for it. */
        run_p_t *p = run_acquire_idle_p();
        if (p) {
            m->current_p = p;
            p->bound_m = m;
            run_local_push_or_global(&p->local_queue, g);
        } else {
            run_global_queue_push(g);
        }
    } else {
        run_global_queue_push(g);
    }

    if (trace_enabled) {
        fprintf(stderr,
                "{\"event\":\"spawn\",\"g_id\":%llu,\"live_g\":%lld,"
                "\"global_queue\":%lld,\"local_queue\":%lld}\n",
                (unsigned long long)g->id,
                (long long)atomic_load_explicit(&live_g_count, memory_order_relaxed),
                (long long)run_metrics_global_queue_len(),
                (long long)run_metrics_local_queue_len());
    }

    /* If there are idle Ps, wake an M to handle the new work.
     * Only safe from the main thread or scheduler context. */
    if (m && m->current_g == NULL && run_has_idle_p()) {
        run_wake_m();
    }
}

void run_yield(void) {
    run_m_t *m = tls_current_m;
    if (!m || !m->current_g)
        return;

    run_g_t *g = m->current_g;
    g->status = G_RUNNABLE;
    bool was_preempted = g->preempt;
    g->preempt = false;

    /* Voluntary yields preserve local LIFO behavior. Preemptive yields go
     * through the global FIFO queue so another runnable G on this P can run. */
    if (!was_preempted && m->current_p) {
        run_local_push_or_global(&m->current_p->local_queue, g);
    } else {
        run_global_queue_push(g);
    }

    /* Switch back to scheduler */
    run_context_switch(&g->context, &m->g0->context);
}

void run_schedule(void) {
    run_m_t *m = tls_current_m;
    if (!m || !m->current_g)
        return;

    run_g_t *g = m->current_g;
    /* Caller must have already set g->status (e.g., G_WAITING) */

    /* Switch back to scheduler */
    run_context_switch(&g->context, &m->g0->context);

    /* Resumed: check if we were woken due to channel close panic */
    if (g->chan_panic) {
        g->chan_panic = false;
        fprintf(stderr, "run: send on closed channel\n");
        abort();
    }
}

void run_g_exit(void) {
    run_m_t *m = tls_current_m;
    if (!m || !m->current_g) {
        fprintf(stderr, "run: run_g_exit called with no current G\n");
        abort();
    }

    m->current_g->status = G_DEAD;

    /* Switch back to scheduler (never returns) */
    run_context_switch(&m->current_g->context, &m->g0->context);

    /* Unreachable */
    __builtin_unreachable();
}

void run_g_ready(run_g_t *g) {
    g->status = G_RUNNABLE;

    run_m_t *m = tls_current_m;

    /* Prefer last_p if it's on the right NUMA node */
    if (g->last_p && g->last_p->status == P_RUNNING) {
        if (g->preferred_node < 0 || g->last_p->numa_node == (uint32_t)g->preferred_node) {
            run_local_push_or_global(&g->last_p->local_queue, g);
            goto wake;
        }
    }

    /* If NUMA preference set, find a P on that node */
    if (g->preferred_node >= 0) {
        for (uint32_t i = 0; i < num_ps; i++) {
            if (all_ps[i].numa_node == (uint32_t)g->preferred_node &&
                all_ps[i].status == P_RUNNING) {
                run_local_push_or_global(&all_ps[i].local_queue, g);
                goto wake;
            }
        }
    }

    /* Fallback: current P or global */
    if (m && m->current_p) {
        run_local_push_or_global(&m->current_p->local_queue, g);
    } else {
        run_global_queue_push(g);
    }

wake:
    /* Wake an M if there are idle Ps. */
    if (run_has_idle_p()) {
        run_poller_wakeup(); /* Unblock M in poll_blocking */
        run_wake_m();
    }
}

/* ========================================================================
 * NUMA-Aware Spawn and Pin
 * ======================================================================== */

void run_spawn_on_node(void (*fn)(void *), void *arg, int32_t node_id) {
    atomic_fetch_add_explicit(&scheduler_metrics.spawn_count, 1, memory_order_relaxed);
    run_g_t *g = run_g_alloc(fn, arg);
    g->preferred_node = node_id;
    atomic_fetch_add_explicit(&live_g_count, 1, memory_order_release);

    run_m_t *m = tls_current_m;

    /* Place in a P on the preferred node if possible */
    if (node_id >= 0) {
        for (uint32_t i = 0; i < num_ps; i++) {
            if (all_ps[i].numa_node == (uint32_t)node_id && all_ps[i].status == P_RUNNING) {
                run_local_push_or_global(&all_ps[i].local_queue, g);
                goto wake;
            }
        }
    }

    /* Fallback: same logic as run_spawn */
    if (m && m->current_p) {
        run_local_push_or_global(&m->current_p->local_queue, g);
    } else if (m && m->current_g == NULL) {
        /* Called from main thread (outside scheduler loop).
         * Try to re-acquire an idle P so the G goes to the local queue. */
        run_p_t *p = run_acquire_idle_p();
        if (p) {
            m->current_p = p;
            p->bound_m = m;
            run_local_push_or_global(&p->local_queue, g);
        } else {
            run_global_queue_push(g);
        }
    } else {
        run_global_queue_push(g);
    }

wake:
    if (trace_enabled) {
        fprintf(stderr,
                "{\"event\":\"spawn_on_node\",\"g_id\":%llu,\"node_id\":%d,"
                "\"live_g\":%lld,\"global_queue\":%lld,\"local_queue\":%lld}\n",
                (unsigned long long)g->id, node_id,
                (long long)atomic_load_explicit(&live_g_count, memory_order_relaxed),
                (long long)run_metrics_global_queue_len(),
                (long long)run_metrics_local_queue_len());
    }

    /* Wake an M if there are idle Ps. */
    if (run_has_idle_p()) {
        run_poller_wakeup(); /* Unblock M in poll_blocking */
        run_wake_m();
    }
}

void run_numa_pin(uint32_t node_id) {
    run_g_t *g = run_current_g();
    if (!g)
        return;
    g->preferred_node = (int32_t)node_id;
    /* Yield so the scheduler can reschedule on the right NUMA node */
    run_yield();
}

/* ========================================================================
 * Cooperative Preemption (#84) — Timer-based
 * ======================================================================== */

#if defined(_WIN32)

static void run_preempt_timer_callback(void *arg) {
    (void)arg;

    run_mutex_lock(&all_ms_lock);
    for (run_m_t *m = all_ms; m != NULL; m = m->all_next) {
        run_g_t *g = m->current_g;
        if (g && g->status == G_RUNNING) {
            g->preempt = true;
        }
    }
    run_mutex_unlock(&all_ms_lock);
}

void run_preemption_start(void) {
    if (preemption_timer_active)
        return;

    if (run_timer_start(&preemption_timer, RUN_PREEMPT_INTERVAL_US, run_preempt_timer_callback,
                        NULL)) {
        preemption_timer_active = true;
    }
}

void run_preemption_stop(void) {
    if (!preemption_timer_active)
        return;

    run_timer_stop(&preemption_timer);
    preemption_timer_active = false;
}

#elif defined(__linux__) || defined(__APPLE__)

static void run_preempt_timer_handler(int sig) {
    (void)sig;
    run_g_t *g = run_current_g();
    if (g && g->status == G_RUNNING) {
        g->preempt = true;
    }
}

void run_preemption_start(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = run_preempt_timer_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGALRM, &sa, NULL);

    struct itimerval timer;
    timer.it_value.tv_sec = 0;
    timer.it_value.tv_usec = RUN_PREEMPT_INTERVAL_US;
    timer.it_interval.tv_sec = 0;
    timer.it_interval.tv_usec = RUN_PREEMPT_INTERVAL_US;
    setitimer(ITIMER_REAL, &timer, NULL);

    preemption_timer_active = true;
}

void run_preemption_stop(void) {
    if (!preemption_timer_active)
        return;

    struct itimerval timer;
    memset(&timer, 0, sizeof(timer));
    setitimer(ITIMER_REAL, &timer, NULL);

    signal(SIGALRM, SIG_DFL);
    preemption_timer_active = false;
}

#else

void run_preemption_start(void) {}
void run_preemption_stop(void) {}

#endif

/* ========================================================================
 * Syscall-aware Scheduling (#85)
 * ======================================================================== */

void run_entersyscall(void) {
    run_m_t *m = tls_current_m;
    if (!m || !m->current_p || !m->current_g)
        return;

    run_g_t *g = m->current_g;
    run_p_t *p = m->current_p;

    g->in_syscall = true;
    p->status = P_SYSCALL;

    /* Detach M from P — another M can acquire this P */
    m->current_p = NULL;
    p->bound_m = NULL;

    /* Put P in idle list so another M can pick it up */
    run_mutex_lock(&idle_p_lock);
    idle_p_stack[idle_p_count++] = p->id;
    run_mutex_unlock(&idle_p_lock);

    /* Wake an M to take over this P's work */
    if (run_local_queue_len(&p->local_queue) > 0) {
        run_wake_m();
    }
}

void run_exitsyscall(void) {
    run_m_t *m = tls_current_m;
    if (!m || !m->current_g)
        return;

    run_g_t *g = m->current_g;
    g->in_syscall = false;

    /* Try to reacquire a P */
    run_p_t *p = run_acquire_idle_p();
    if (p) {
        m->current_p = p;
        p->bound_m = m;
        p->status = P_RUNNING;
        return;
    }

    /* No P available — put G in global queue and park M */
    g->status = G_RUNNABLE;
    run_global_queue_push(g);
    m->current_g = NULL;

    /* Park this M until there's a P available */
    run_park_m(m);
}

/* ========================================================================
 * Signal-based Preemption (#87) — SIGURG
 * ======================================================================== */

#if defined(__linux__) || defined(__APPLE__)

extern void run_async_preempt(void);

static bool run_install_async_preempt_frame(ucontext_t *uc) {
#if defined(__APPLE__)
#if defined(__aarch64__)
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    uint64_t sp = uc->uc_mcontext->__ss.__sp - 16;
    *(uint64_t *)sp = uc->uc_mcontext->__ss.__lr;
    uc->uc_mcontext->__ss.__sp = sp;
    uc->uc_mcontext->__ss.__lr = pc;
    uc->uc_mcontext->__ss.__pc = (uint64_t)run_async_preempt;
    return true;
#elif defined(__x86_64__)
    uint64_t pc = uc->uc_mcontext->__ss.__rip;
    uint64_t sp = uc->uc_mcontext->__ss.__rsp - sizeof(uint64_t);
    *(uint64_t *)sp = pc;
    uc->uc_mcontext->__ss.__rsp = sp;
    uc->uc_mcontext->__ss.__rip = (uint64_t)run_async_preempt;
    return true;
#else
    return false;
#endif
#elif defined(__linux__)
#if defined(__aarch64__)
    uint64_t pc = uc->uc_mcontext.pc;
    uint64_t sp = uc->uc_mcontext.sp - 16;
    *(uint64_t *)sp = uc->uc_mcontext.regs[30];
    uc->uc_mcontext.sp = sp;
    uc->uc_mcontext.regs[30] = pc;
    uc->uc_mcontext.pc = (uint64_t)run_async_preempt;
    return true;
#elif defined(__x86_64__)
    greg_t pc = uc->uc_mcontext.gregs[REG_RIP];
    greg_t sp = uc->uc_mcontext.gregs[REG_RSP] - (greg_t)sizeof(greg_t);
    *(greg_t *)sp = pc;
    uc->uc_mcontext.gregs[REG_RSP] = sp;
    uc->uc_mcontext.gregs[REG_RIP] = (greg_t)(uintptr_t)run_async_preempt;
    return true;
#else
    return false;
#endif
#else
    (void)uc;
    return false;
#endif
}

static void run_sigurg_handler(int sig, siginfo_t *info, void *uctx) {
    (void)sig;
    (void)info;

    run_m_t *m = tls_current_m;
    if (!m || !m->current_g)
        return;

    run_g_t *g = m->current_g;
    if (g->status != G_RUNNING)
        return;
    if (g->in_syscall || g->preempt_safe)
        return;

    /* Set preempt flag for cooperative check */
    g->preempt = true;

    /* Rewrite PC to async preemption trampoline. */
    ucontext_t *uc = (ucontext_t *)uctx;
    if (!run_install_async_preempt_frame(uc))
        return;
    g->preempt_safe = true;
}

void run_async_preempt_done(void) {
    run_g_t *g = run_current_g();
    if (g != NULL) {
        g->preempt_safe = false;
    }
}

static void *run_signal_preemption_thread_entry(void *arg) {
    (void)arg;
    const struct timespec interval = {
        .tv_sec = 0,
        .tv_nsec = (long)RUN_PREEMPT_INTERVAL_US * 1000L,
    };

    while (atomic_load_explicit(&signal_preemption_thread_running, memory_order_acquire)) {
        nanosleep(&interval, NULL);

        run_mutex_lock(&all_ms_lock);
        for (run_m_t *m = all_ms; m != NULL; m = m->all_next) {
            run_g_t *g = m->current_g;
            if (g == NULL || g->status != G_RUNNING)
                continue;
            if (g->in_syscall || g->preempt_safe)
                continue;
            pthread_kill(m->thread, SIGURG);
        }
        run_mutex_unlock(&all_ms_lock);
    }

    return NULL;
}

void run_signal_preemption_start(void) {
    if (signal_preemption_active)
        return;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = run_sigurg_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigaction(SIGURG, &sa, NULL);

    atomic_store_explicit(&signal_preemption_thread_running, true, memory_order_release);
    if (pthread_create(&signal_preemption_thread, NULL, run_signal_preemption_thread_entry, NULL) !=
        0) {
        atomic_store_explicit(&signal_preemption_thread_running, false, memory_order_release);
        signal(SIGURG, SIG_DFL);
        return;
    }

    signal_preemption_active = true;
}

void run_signal_preemption_stop(void) {
    if (!signal_preemption_active)
        return;
    atomic_store_explicit(&signal_preemption_thread_running, false, memory_order_release);
    pthread_join(signal_preemption_thread, NULL);
    signal(SIGURG, SIG_DFL);
    signal_preemption_active = false;
}

#else /* Windows stub */

void run_signal_preemption_start(void) {}
void run_signal_preemption_stop(void) {}

#endif

/* ========================================================================
 * Growable Stacks (#88) — SIGSEGV handler
 * ======================================================================== */

#if defined(__linux__) || defined(__APPLE__)

/* Find the G whose stack contains the faulting address. */
static run_g_t *run_find_g_by_fault_addr(void *addr) {
    /* Walk through all Ps' local queues and the global queue.
     * Also check the current G on each M.
     * This is O(n) but only runs on stack overflow (rare). */
    for (uint32_t i = 0; i < num_ps; i++) {
        run_m_t *m = all_ps[i].bound_m;
        if (m && m->current_g) {
            run_g_t *g = m->current_g;
            if (g->stack_base && (char *)addr >= (char *)g->stack_base &&
                (char *)addr < (char *)g->stack_base + g->stack_size) {
                return g;
            }
        }
    }
    return NULL;
}

static void run_stack_growth_handler(int sig, siginfo_t *info, void *uctx) {
    (void)uctx;

    void *fault_addr = info->si_addr;
    run_g_t *g = run_find_g_by_fault_addr(fault_addr);

    if (g && growable_stacks_enabled) {
        run_stack_grow_to_sp(g, fault_addr);
        return; /* Resume execution */
    }

    /* Not a stack guard fault — invoke default handler */
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

void run_stack_growth_init(void) {
    /* Provide an alternate signal stack so we can handle stack overflow */
    stack_t ss;
    ss.ss_sp = malloc(SIGSTKSZ);
    if (!ss.ss_sp) {
        fprintf(stderr, "run: failed to allocate signal stack\n");
        abort();
    }
    ss.ss_size = SIGSTKSZ;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = run_stack_growth_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

#else /* Windows stub */

void run_stack_growth_init(void) {
    /* TODO: Windows SEH for stack growth */
}

#endif

/* ========================================================================
 * Debug Helper: dump all green threads as JSON (#debugger)
 * Called via GDB's -data-evaluate-expression from the DAP adapter.
 * ======================================================================== */

static const char *run_g_status_str(run_g_status_t s) {
    switch (s) {
    case G_IDLE:
        return "idle";
    case G_RUNNABLE:
        return "runnable";
    case G_RUNNING:
        return "running";
    case G_WAITING:
        return "waiting";
    case G_DEAD:
        return "dead";
    default:
        return "unknown";
    }
}

static int run_dump_g(char *buf, size_t remaining, run_g_t *g, bool *first) {
    if (g == NULL || remaining < 128)
        return 0;
    int n = snprintf(buf, remaining,
                     "%s{\"id\":%lu,\"status\":\"%s\",\"stack_base\":\"%p\",\"in_syscall\":%s}",
                     *first ? "" : ",", (unsigned long)g->id, run_g_status_str(g->status),
                     g->stack_base, g->in_syscall ? "true" : "false");
    *first = false;
    return (n > 0 && (size_t)n < remaining) ? n : 0;
}

void run_debug_run_dump_goroutines(char *buf, size_t buf_size) {
    if (buf == NULL || buf_size < 3)
        return;

    int pos = 0;
    buf[pos++] = '[';
    bool first = true;
    size_t remaining = buf_size - 2; /* reserve space for ] and \0 */

    /* Dump Gs in each P's local queue (lock-free deque snapshot) */
    for (uint32_t i = 0; i < num_ps; i++) {
        run_local_queue_t *lq = &all_ps[i].local_queue;
        uint32_t lq_head = atomic_load_explicit(&lq->head, memory_order_relaxed);
        uint32_t lq_tail = atomic_load_explicit(&lq->tail, memory_order_relaxed);
        for (uint32_t j = lq_head; j != lq_tail; j++) {
            run_g_t *g = lq->buf[j % RUN_LOCAL_QUEUE_SIZE];
            if (g) {
                int n = run_dump_g(buf + pos, remaining, g, &first);
                pos += n;
                remaining -= (size_t)n;
            }
        }
        /* Also dump the currently running G on this P's bound M */
        if (all_ps[i].bound_m && all_ps[i].bound_m->current_g) {
            int n = run_dump_g(buf + pos, remaining, all_ps[i].bound_m->current_g, &first);
            pos += n;
            remaining -= (size_t)n;
        }
    }

    /* Dump Gs in the global queue */
    for (run_g_t *g = global_queue.head; g != NULL; g = g->sched_next) {
        int n = run_dump_g(buf + pos, remaining, g, &first);
        pos += n;
        remaining -= (size_t)n;
    }

    buf[pos++] = ']';
    buf[pos] = '\0';
}

/* ========================================================================
 * Growable Stack Expansion
 * ======================================================================== */

void run_morestack(void) {
    char marker;
    run_stack_check(&marker);
}

void run_stack_check(void *sp) {
    run_g_t *g = run_current_g();
    if (g == NULL || g->id == 0)
        return;
    run_stack_record_sp(g, sp);
    run_stack_grow_to_sp(g, sp);
}

/* ========================================================================
 * Runtime Introspection API
 * ======================================================================== */

int64_t run_scheduler_goroutine_count(void) {
    return atomic_load_explicit(&live_g_count, memory_order_relaxed);
}

uint32_t run_scheduler_get_maxprocs(void) {
    return num_ps > 0 ? num_ps : 1;
}

uint32_t run_scheduler_set_maxprocs(uint32_t n) {
    uint32_t prev = run_scheduler_get_maxprocs();
    if (!scheduler_initialized && n >= 1 && n <= RUN_MAX_P_COUNT) {
        num_ps = n;
    }
    return prev;
}

/* ========================================================================
 * Runtime Metrics (#410)
 * ======================================================================== */

run_metrics_t run_runtime_metrics(void) {
    run_metrics_t m;
    m.spawn_count = atomic_load_explicit(&scheduler_metrics.spawn_count, memory_order_relaxed);
    m.complete_count =
        atomic_load_explicit(&scheduler_metrics.complete_count, memory_order_relaxed);
    m.steal_count = atomic_load_explicit(&scheduler_metrics.steal_count, memory_order_relaxed);
    m.context_switches =
        atomic_load_explicit(&scheduler_metrics.context_switches, memory_order_relaxed);
    m.park_count = atomic_load_explicit(&scheduler_metrics.park_count, memory_order_relaxed);
    m.unpark_count = atomic_load_explicit(&scheduler_metrics.unpark_count, memory_order_relaxed);
    m.poll_count = atomic_load_explicit(&scheduler_metrics.poll_count, memory_order_relaxed);
    m.global_queue_len = run_metrics_global_queue_len();
    m.local_queue_len = run_metrics_local_queue_len();
    m.live_g_count = atomic_load_explicit(&live_g_count, memory_order_relaxed);
    m.poll_waiter_count = run_metrics_poll_waiter_count();
    return m;
}
