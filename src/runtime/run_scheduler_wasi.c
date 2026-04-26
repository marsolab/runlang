#include "run_numa.h"
#include "run_poller.h"
#include "run_scheduler.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* WASI MVP has no native threads, signals, or stack-switching ABI. This file
 * provides a single-P cooperative scheduler that can run queued tasks to
 * completion and keeps the public runtime API linkable for WASI smoke tests. */

static run_p_t p0;
static run_m_t m0;
static run_g_queue_t global_queue;
static _Atomic uint64_t next_g_id = 1;
static _Atomic int64_t live_g_count = 0;
static _Atomic int64_t goroutine_count = 0;
static bool scheduler_initialized = false;
static run_metrics_t scheduler_metrics = {0};

run_g_t *run_current_g(void) {
    return m0.current_g;
}

run_m_t *run_current_m(void) {
    return scheduler_initialized ? &m0 : NULL;
}

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
    if (!g)
        return NULL;
    q->head = g->sched_next;
    if (!q->head)
        q->tail = NULL;
    g->sched_next = NULL;
    q->len--;
    return g;
}

bool run_g_queue_remove(run_g_queue_t *q, run_g_t *g) {
    if (!q->head)
        return false;
    if (q->head == g) {
        q->head = g->sched_next;
        if (!q->head)
            q->tail = NULL;
        g->sched_next = NULL;
        q->len--;
        return true;
    }

    run_g_t *prev = q->head;
    while (prev->sched_next) {
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

void run_local_queue_init(run_local_queue_t *q) {
    atomic_store_explicit(&q->head, 0, memory_order_relaxed);
    atomic_store_explicit(&q->tail, 0, memory_order_relaxed);
    memset((void *)q->buf, 0, sizeof(q->buf));
}

bool run_local_queue_push(run_local_queue_t *q, run_g_t *g) {
    uint32_t tail = atomic_load_explicit(&q->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&q->head, memory_order_acquire);
    if (tail - head >= RUN_LOCAL_QUEUE_SIZE)
        return false;
    q->buf[tail % RUN_LOCAL_QUEUE_SIZE] = g;
    atomic_store_explicit(&q->tail, tail + 1, memory_order_release);
    return true;
}

run_g_t *run_local_queue_pop(run_local_queue_t *q) {
    uint32_t head = atomic_load_explicit(&q->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&q->tail, memory_order_acquire);
    if (head == tail)
        return NULL;
    run_g_t *g = q->buf[head % RUN_LOCAL_QUEUE_SIZE];
    atomic_store_explicit(&q->head, head + 1, memory_order_release);
    return g;
}

run_g_t *run_local_queue_steal(run_local_queue_t *src, run_local_queue_t *dst) {
    (void)dst;
    return run_local_queue_pop(src);
}

uint32_t run_local_queue_len(run_local_queue_t *q) {
    uint32_t head = atomic_load_explicit(&q->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&q->tail, memory_order_relaxed);
    return tail >= head ? tail - head : 0;
}

void run_scheduler_init(void) {
    if (scheduler_initialized)
        return;

    memset(&p0, 0, sizeof(p0));
    memset(&m0, 0, sizeof(m0));
    run_g_queue_init(&global_queue);
    run_local_queue_init(&p0.local_queue);

    p0.id = 0;
    p0.status = P_RUNNING;
    p0.bound_m = &m0;
    p0.numa_node = 0;

    m0.id = 1;
    m0.current_p = &p0;

    run_numa_init();
    run_poller_init();
    scheduler_initialized = true;
}

static run_g_t *run_g_new(void (*fn)(void *), void *arg, int32_t preferred_node) {
    run_g_t *g = (run_g_t *)calloc(1, sizeof(run_g_t));
    if (!g) {
        fprintf(stderr, "run: failed to allocate goroutine\n");
        abort();
    }

    g->id = atomic_fetch_add_explicit(&next_g_id, 1, memory_order_relaxed);
    g->status = G_RUNNABLE;
    g->entry_fn = fn;
    g->entry_arg = arg;
    g->preferred_node = preferred_node;
    g->preempt_safe = true;
    return g;
}

void run_spawn(void (*fn)(void *), void *arg) {
    run_spawn_on_node(fn, arg, -1);
}

void run_spawn_on_node(void (*fn)(void *), void *arg, int32_t node_id) {
    if (!scheduler_initialized)
        run_scheduler_init();
    run_g_t *g = run_g_new(fn, arg, node_id);
    atomic_fetch_add_explicit(&live_g_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&goroutine_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&scheduler_metrics.spawn_count, 1, memory_order_relaxed);
    run_g_queue_push(&global_queue, g);
}

static void run_g_finish(run_g_t *g) {
    g->status = G_DEAD;
    atomic_fetch_sub_explicit(&live_g_count, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(&goroutine_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&scheduler_metrics.complete_count, 1, memory_order_relaxed);
    free(g);
}

void run_scheduler_run(void) {
    if (!scheduler_initialized)
        run_scheduler_init();

    while (atomic_load_explicit(&live_g_count, memory_order_relaxed) > 0) {
        run_g_t *g = run_g_queue_pop(&global_queue);
        if (!g) {
            if (run_poller_has_waiters()) {
                run_poller_poll_blocking(-1);
                continue;
            }
            break;
        }

        m0.current_g = g;
        g->status = G_RUNNING;
        atomic_fetch_add_explicit(&scheduler_metrics.context_switches, 1, memory_order_relaxed);
        g->entry_fn(g->entry_arg);
        m0.current_g = NULL;
        run_g_finish(g);
    }
}

void run_yield(void) {
    atomic_fetch_add_explicit(&scheduler_metrics.context_switches, 1, memory_order_relaxed);
}

void run_schedule(void) {
    run_yield();
}

void run_g_exit(void) {
    run_g_t *g = run_current_g();
    if (g)
        g->status = G_DEAD;
}

void run_g_ready(run_g_t *g) {
    if (!g || g->status == G_DEAD)
        return;
    g->status = G_RUNNABLE;
    run_g_queue_push(&global_queue, g);
}

void run_numa_pin(uint32_t node_id) {
    (void)node_id;
}

void run_preemption_start(void) {}
void run_preemption_stop(void) {}
void run_signal_preemption_start(void) {}
void run_signal_preemption_stop(void) {}
void run_entersyscall(void) {}
void run_exitsyscall(void) {}
void run_wake_m(void) {}

void run_global_queue_push(run_g_t *g) {
    run_g_queue_push(&global_queue, g);
}

run_g_t *run_global_queue_pop(void) {
    return run_g_queue_pop(&global_queue);
}

uint32_t run_global_queue_len(void) {
    return global_queue.len;
}

size_t run_stack_max_size(void) {
    return 0;
}

void run_stack_growth_init(void) {}

void run_morestack(void) {
    fprintf(stderr, "run: stack growth is unavailable on WASI\n");
    abort();
}

void run_debug_dump_goroutines(char *buf, size_t buf_size) {
    if (!buf || buf_size == 0)
        return;
    snprintf(buf, buf_size, "wasi scheduler: %lld live goroutine(s)\n",
             (long long)atomic_load_explicit(&live_g_count, memory_order_relaxed));
}

int64_t run_scheduler_goroutine_count(void) {
    return atomic_load_explicit(&goroutine_count, memory_order_relaxed);
}

uint32_t run_scheduler_get_maxprocs(void) {
    return 1;
}

uint32_t run_scheduler_set_maxprocs(uint32_t n) {
    (void)n;
    return 1;
}

run_metrics_t run_runtime_metrics(void) {
    return scheduler_metrics;
}
