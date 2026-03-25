#ifndef RUN_SCHEDULER_H
#define RUN_SCHEDULER_H

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---------- Forward declarations ---------- */
typedef struct run_g run_g_t;
typedef struct run_m run_m_t;
typedef struct run_p run_p_t;

/* ---------- Context (platform-specific, defined in assembly) ---------- */
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

/* Implemented in run_context_amd64.S (or arm64 variant) */
extern void run_context_switch(run_context_t *from, run_context_t *to);
extern void run_context_init(run_context_t *ctx, void *stack_top, void (*entry)(void *), void *arg);

/* ---------- G — Green Thread ---------- */
typedef enum {
    G_IDLE,     /* not yet started */
    G_RUNNABLE, /* ready to run, in a run queue */
    G_RUNNING,  /* currently executing on an M */
    G_WAITING,  /* blocked (channel, mutex, etc.) */
    G_DEAD      /* finished execution */
} run_g_status_t;

struct run_g {
    uint64_t id;
    run_g_status_t status;

    /* Stack */
    void *stack_base;       /* mmap'd stack memory (lowest address) */
    size_t stack_size;      /* total allocated size */
    size_t stack_committed; /* committed bytes (for growable stacks) */

    /* Saved CPU state */
    run_context_t context;

    /* Entry point */
    void (*entry_fn)(void *);
    void *entry_arg;

    /* Scheduling */
    struct run_g *sched_next; /* intrusive linked list for run queues */
    struct run_p *last_p;     /* last P this G ran on (affinity) */
    int32_t preferred_node;   /* NUMA node preference: -1 = none, >= 0 = node */

    /* Preemption */
    volatile bool preempt; /* set by timer, checked at function entry */

    /* Channel integration */
    void *chan_data_ptr; /* data pointer for blocking send/recv */
    bool chan_panic;     /* true if woken because channel was closed during send */

    /* Syscall tracking */
    bool in_syscall;
};

/* ---------- G Queue (intrusive linked list) ---------- */
typedef struct {
    run_g_t *head;
    run_g_t *tail;
    uint32_t len;
} run_g_queue_t;

void run_g_queue_init(run_g_queue_t *q);
void run_g_queue_push(run_g_queue_t *q, run_g_t *g);
run_g_t *run_g_queue_pop(run_g_queue_t *q);
bool run_g_queue_remove(run_g_queue_t *q, run_g_t *g);

/* ---------- M — Machine Thread ---------- */
struct run_m {
    uint64_t id;
    pthread_t thread;

    run_g_t *current_g; /* G currently executing (NULL if idle) */
    run_p_t *current_p; /* attached P (NULL if spinning/idle) */

    run_g_t *g0; /* scheduler goroutine (owns scheduler stack) */

    /* Parking */
    pthread_mutex_t park_mutex;
    pthread_cond_t park_cond;
    volatile bool parked;

    /* Linked list of all Ms */
    struct run_m *all_next;
};

/* ---------- P — Processor ---------- */
typedef enum { P_IDLE, P_RUNNING, P_SYSCALL } run_p_status_t;

#define RUN_MAX_P_COUNT 256

struct run_p {
    uint32_t id;
    run_p_status_t status;

    /* Local run queue (FIFO linked list) */
    run_g_queue_t local_queue;

    /* Bound M */
    run_m_t *bound_m;

    /* NUMA node this P is assigned to */
    uint32_t numa_node;
};

/* ---------- Public API ---------- */

/* Task function type used by codegen: void fn(void *arg) */
typedef void (*run_task_fn)(void *);

/* Initialize the scheduler. Must be called before any other scheduler function. */
void run_scheduler_init(void);

/* Run the scheduler loop until all green threads complete. */
void run_scheduler_run(void);

/* Spawn a new green thread that will execute fn(arg). */
void run_spawn(void (*fn)(void *), void *arg);

/* Spawn a new green thread with NUMA node affinity.
 * node_id < 0 means no preference (same as run_spawn). */
void run_spawn_on_node(void (*fn)(void *), void *arg, int32_t node_id);

/* Pin the current green thread to a NUMA node.
 * The thread will be rescheduled on a P assigned to that node. */
void run_numa_pin(uint32_t node_id);

/* Voluntarily yield the current green thread. */
void run_yield(void);

/* Called when a green thread's entry function returns. Does not return. */
void run_g_exit(void);

/* ---------- Scheduler internals (used by channels, etc.) ---------- */

/* Get the currently running G on this thread. */
run_g_t *run_current_g(void);

/* Get the current M on this thread. */
run_m_t *run_current_m(void);

/* Switch from the current G back to the scheduler (g0).
 * The caller must set g->status before calling this. */
void run_schedule(void);

/* Make a G runnable and add it to a run queue.
 * Tries the current P's local queue first. */
void run_g_ready(run_g_t *g);

/* ---------- Preemption (#84) ---------- */

/* Inline preemption check — emitted at function prologues by codegen. */
static inline void run_preemption_check(void) {
    /* This is called from generated code. We need to access TLS to
     * get the current G and check its preempt flag. */
    run_g_t *g = run_current_g();
    if (g != NULL && __builtin_expect(g->preempt, 0)) {
        g->preempt = false;
        run_yield();
    }
}

/* Start the cooperative preemption timer (10ms periodic). */
void run_preemption_start(void);

/* Stop the preemption timer. */
void run_preemption_stop(void);

/* ---------- Syscall-aware scheduling (#85) ---------- */

/* Call before entering a potentially blocking syscall. */
void run_entersyscall(void);

/* Call after returning from a blocking syscall. */
void run_exitsyscall(void);

/* ---------- Multi-threaded scheduler (#86) ---------- */

/* Global run queue operations (thread-safe). */
void run_global_queue_push(run_g_t *g);
run_g_t *run_global_queue_pop(void);
uint32_t run_global_queue_len(void);

/* Wake an idle M or create a new one if needed. */
void run_wake_m(void);

/* ---------- Signal-based preemption (#87) ---------- */

/* Install SIGURG handler for async preemption. */
void run_signal_preemption_start(void);

/* Stop signal-based preemption. */
void run_signal_preemption_stop(void);

/* ---------- Growable stacks (#88) ---------- */

/* Get the configured maximum stack size (from RUN_STACK_MAX env var). */
size_t run_stack_max_size(void);

/* Install the SIGSEGV handler for stack growth. */
void run_stack_growth_init(void);

/* ---------- Debug helpers (#debugger) ---------- */

/* Dump all green threads as a JSON array into buf.
 * Called by the DAP adapter via GDB's expression evaluation. */
void run_debug_dump_goroutines(char *buf, size_t buf_size);

/* ---------- Runtime introspection API ---------- */

int64_t run_scheduler_goroutine_count(void);
uint32_t run_scheduler_get_maxprocs(void);
uint32_t run_scheduler_set_maxprocs(uint32_t n);

#endif
