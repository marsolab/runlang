#ifndef RUN_SCHEDULER_H
#define RUN_SCHEDULER_H

#include "run_platform.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct run_g run_g_t;
typedef struct run_m run_m_t;
typedef struct run_p run_p_t;

/* ---------- Context (platform-specific) ---------- */
#if defined(__aarch64__) || defined(__arm64__)
typedef struct {
    void *sp;
    void *lr;
    void *x19;
    void *x20;
    void *x21;
    void *x22;
    void *x23;
    void *x24;
    void *x25;
    void *x26;
    void *x27;
    void *x28;
    void *fp;
    void *reserved;
    uint64_t d8;
    uint64_t d9;
    uint64_t d10;
    uint64_t d11;
    uint64_t d12;
    uint64_t d13;
    uint64_t d14;
    uint64_t d15;
} run_context_t;
#elif defined(_WIN32) && defined(_M_X64)
typedef struct {
    void *rsp;
    void *rip;
    void *rbx;
    void *rbp;
    void *rdi;
    void *rsi;
    void *r12;
    void *r13;
    void *r14;
    void *r15;
    _Alignas(16) unsigned char xmm6[16];
    _Alignas(16) unsigned char xmm7[16];
    _Alignas(16) unsigned char xmm8[16];
    _Alignas(16) unsigned char xmm9[16];
    _Alignas(16) unsigned char xmm10[16];
    _Alignas(16) unsigned char xmm11[16];
    _Alignas(16) unsigned char xmm12[16];
    _Alignas(16) unsigned char xmm13[16];
    _Alignas(16) unsigned char xmm14[16];
    _Alignas(16) unsigned char xmm15[16];
} run_context_t;
#else
typedef struct {
    void *rsp;
    void *rip;
    void *rbx;
    void *rbp;
    void *r12;
    void *r13;
    void *r14;
    void *r15;
} run_context_t;
#endif

extern void run_context_switch(run_context_t *from, run_context_t *to);
extern void run_context_init(run_context_t *ctx, void *stack_top, void (*entry)(void *), void *arg);

/* ---------- G — Green Thread ---------- */
typedef enum { G_IDLE, G_RUNNABLE, G_RUNNING, G_WAITING, G_DEAD } run_g_status_t;

struct run_g {
    uint64_t id;
    run_g_status_t status;
    void *stack_base;
    void *stack_lo;
    size_t stack_size;
    size_t stack_committed;
    size_t stack_watermark;
    run_context_t context;
    void (*entry_fn)(void *);
    void *entry_arg;
    struct run_g *sched_next;
    struct run_p *last_p;
    int32_t preferred_node;
    volatile bool preempt;
    volatile bool preempt_safe;
    void *chan_data_ptr;
    bool chan_panic;
    bool in_syscall;
};

/* ---------- G Queue (intrusive linked list, for global queue) ---------- */
typedef struct {
    run_g_t *head;
    run_g_t *tail;
    uint32_t len;
} run_g_queue_t;
void run_g_queue_init(run_g_queue_t *q);
void run_g_queue_push(run_g_queue_t *q, run_g_t *g);
run_g_t *run_g_queue_pop(run_g_queue_t *q);
bool run_g_queue_remove(run_g_queue_t *q, run_g_t *g);

/* ---------- Lock-Free Local Run Queue (Chase-Lev deque) ---------- */
#define RUN_LOCAL_QUEUE_SIZE 256
typedef struct {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    run_g_t *buf[RUN_LOCAL_QUEUE_SIZE];
} run_local_queue_t;

void run_local_queue_init(run_local_queue_t *q);
bool run_local_queue_push(run_local_queue_t *q, run_g_t *g);
run_g_t *run_local_queue_pop(run_local_queue_t *q);
run_g_t *run_local_queue_steal(run_local_queue_t *src, run_local_queue_t *dst);
uint32_t run_local_queue_len(run_local_queue_t *q);

/* ---------- M — Machine Thread ---------- */
struct run_m {
    uint64_t id;
    run_thread_t thread;
    run_g_t *current_g;
    run_p_t *current_p;
    run_g_t *g0;
    run_mutex_t park_mutex;
    run_cond_t park_cond;
    volatile bool parked;
    struct run_m *all_next;
    struct run_m *idle_next;
};

/* ---------- P — Processor ---------- */
typedef enum { P_IDLE, P_RUNNING, P_SYSCALL } run_p_status_t;
#define RUN_MAX_P_COUNT 256

struct run_p {
    uint32_t id;
    run_p_status_t status;
    run_local_queue_t local_queue;
    run_m_t *bound_m;
    uint32_t numa_node;
};

/* ---------- Runtime Metrics ---------- */
typedef struct {
    _Atomic int64_t spawn_count;
    _Atomic int64_t complete_count;
    _Atomic int64_t steal_count;
    _Atomic int64_t context_switches;
    _Atomic int64_t park_count;
    _Atomic int64_t unpark_count;
    _Atomic int64_t poll_count;
    _Atomic int64_t global_queue_len;
    _Atomic int64_t local_queue_len;
    _Atomic int64_t live_g_count;
    _Atomic int64_t poll_waiter_count;
} run_metrics_t;
run_metrics_t run_runtime_metrics(void);

/* ---------- Public API ---------- */
typedef void (*run_task_fn)(void *);
void run_scheduler_init(void);
void run_scheduler_run(void);
void run_spawn(void (*fn)(void *), void *arg);
void run_spawn_on_node(void (*fn)(void *), void *arg, int32_t node_id);
void run_numa_pin(uint32_t node_id);
void run_yield(void);
void run_g_exit(void);

/* ---------- Scheduler internals ---------- */
run_g_t *run_current_g(void);
run_m_t *run_current_m(void);
void run_schedule(void);
void run_g_ready(run_g_t *g);

/* ---------- Preemption ---------- */
static inline void run_preemption_check(void) {
    run_g_t *g = run_current_g();
    if (g != NULL && __builtin_expect(g->preempt, 0)) {
        g->preempt = false;
        run_yield();
    }
}
void run_preemption_start(void);
void run_preemption_stop(void);

/* ---------- Syscall-aware scheduling ---------- */
void run_entersyscall(void);
void run_exitsyscall(void);

/* ---------- Multi-threaded scheduler ---------- */
void run_global_queue_push(run_g_t *g);
run_g_t *run_global_queue_pop(void);
uint32_t run_global_queue_len(void);
void run_wake_m(void);

/* ---------- Signal-based preemption ---------- */
void run_signal_preemption_start(void);
void run_signal_preemption_stop(void);

/* ---------- Growable stacks ---------- */
size_t run_stack_max_size(void);
void run_stack_growth_init(void);
void run_stack_check(void *sp);
void run_morestack(void);

/* ---------- Debug helpers ---------- */
void run_debug_dump_goroutines(char *buf, size_t buf_size);

/* ---------- Runtime introspection ---------- */
int64_t run_scheduler_goroutine_count(void);
uint32_t run_scheduler_get_maxprocs(void);
uint32_t run_scheduler_set_maxprocs(uint32_t n);

#endif
