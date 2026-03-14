---
title: "Green Thread Scheduler — GMP Model"
sidebar:
  order: 5
---

## Overview

Run's scheduler is modeled after Go's GMP scheduler. It multiplexes many lightweight green threads ("run routines") onto a smaller number of OS threads, providing concurrency with low overhead.

The three core abstractions:

- **G (Green thread)** — a user-space thread with its own stack and saved register state
- **M (Machine)** — an OS-level thread that executes Gs
- **P (Processor)** — a scheduling context that holds a local run queue and per-P resources. The number of Ps determines the maximum parallelism

A G runs on an M, which must be attached to a P. This three-way relationship enables efficient work distribution and graceful handling of blocking operations.

## Data Structures

### G — Green Thread

```c
typedef enum {
    G_IDLE,       // not yet started
    G_RUNNABLE,   // ready to run, in a run queue
    G_RUNNING,    // currently executing on an M
    G_WAITING,    // blocked (on channel, mutex, etc.)
    G_DEAD        // finished execution
} run_g_status_t;

typedef struct run_g {
    uint64_t         id;
    run_g_status_t   status;

    // Stack
    void            *stack_base;    // mmap'd stack memory
    size_t           stack_size;    // committed stack size

    // Saved CPU state (platform-specific)
    run_context_t    context;

    // Entry point
    void           (*entry_fn)(void *);
    void            *entry_arg;

    // Scheduling
    struct run_g    *sched_next;    // intrusive linked list for run queues
    struct run_p    *last_p;        // last P this G ran on (cache affinity)
} run_g_t;
```

### M — Machine Thread

```c
typedef struct run_m {
    uint64_t         id;

    // OS thread handle
    pthread_t        thread;        // HANDLE on Windows

    // Current state
    run_g_t         *current_g;     // G currently executing (NULL if idle)
    struct run_p    *current_p;     // attached P (NULL if spinning/idle)

    // Scheduler stack
    run_g_t         *g0;            // scheduler goroutine (runs scheduler code)

    // Linked list of all Ms
    struct run_m    *all_next;
} run_m_t;
```

### P — Processor

```c
typedef enum {
    P_IDLE,       // not bound to any M
    P_RUNNING,    // actively running Gs
    P_SYSCALL     // bound M is in a syscall
} run_p_status_t;

typedef struct run_p {
    uint32_t         id;
    run_p_status_t   status;

    // Local run queue (FIFO linked list)
    run_g_t         *run_queue_head;
    run_g_t         *run_queue_tail;
    uint32_t         run_queue_len;

    // Bound M
    run_m_t         *bound_m;

    // Per-P allocation cache (future: slab allocator mcache)
    // void *mcache;
} run_p_t;
```

## Global State

```c
// All Ps, created at init. Count = RUN_MAXPROCS (default: CPU count).
static run_p_t     all_ps[RUN_MAX_P_COUNT];
static uint32_t    num_ps;

// Global run queue — overflow from local queues, protected by mutex.
static run_g_t    *global_queue_head;
static run_g_t    *global_queue_tail;
static uint32_t    global_queue_len;
static mutex_t     global_queue_lock;

// Idle lists
static run_p_t    *idle_ps;         // Ps not bound to any M
static run_m_t    *idle_ms;         // Ms parked on condvar

// All Ms (for cleanup)
static run_m_t    *all_ms;
static uint32_t    num_ms;
static mutex_t     all_ms_lock;

// Maximum number of Ms (prevent thread explosion)
#define RUN_MAX_M_COUNT 10000
```

## Initialization

`run_scheduler_init()`:

1. Query CPU count:
   - Linux/macOS: `sysconf(_SC_NPROCESSORS_ONLN)`
   - Windows: `GetSystemInfo(&si); si.dwNumberOfProcessors`
2. Read `RUN_MAXPROCS` environment variable (defaults to CPU count)
3. Allocate `num_ps` P structs, all initially `P_IDLE`
4. Create M0 wrapping the main OS thread
5. Bind M0 to P[0], set P[0] to `P_RUNNING`
6. Initialize global run queue (empty) and locks

## Spawning a Green Thread

`run_spawn(fn, arg)`:

1. Allocate a new `run_g_t`
2. Allocate a stack via `run_vmem` (64 KB fixed, or 8 KB initial with guard)
3. Initialize the context: `run_context_init(&g->context, stack_top, fn, arg)`
4. Set `g->status = G_RUNNABLE`
5. Push G onto the current P's local run queue
6. If there are idle Ps without bound Ms:
   - Try to wake a parked M from `idle_ms` (signal its condvar)
   - If no idle Ms and `num_ms < RUN_MAX_M_COUNT`, create a new M via `pthread_create`

## Scheduling Loop

Each M executes this loop (the "schedule" function, running on M's g0 stack):

```
schedule:
    1. p = current_p
       if p == NULL:
           try to acquire an idle P
           if none available: park M on condvar, wait for wakeup, goto schedule

    2. g = p->run_queue_head           // try local queue first
       if g != NULL:
           dequeue g from local queue
           goto execute

    3. lock(global_queue_lock)         // try global queue
       n = min(global_queue_len, global_queue_len / num_ps + 1)
       take n items from global queue, put first in g, rest in local queue
       unlock(global_queue_lock)
       if g != NULL:
           goto execute

    4. for i in random_permutation(num_ps):  // work stealing
           if i == p->id: continue
           victim = &all_ps[i]
           stolen = steal_half(victim->run_queue)
           if stolen:
               g = first of stolen
               put rest in local queue
               goto execute

    5. // No work found anywhere
       release P to idle_ps
       park M on condvar
       goto schedule

execute:
    g->status = G_RUNNING
    g->last_p = p
    p->bound_m->current_g = g
    run_context_switch(&g0->context, &g->context)
    // returns here when g yields or completes
    if g->status == G_DEAD:
        free g's stack and struct
    goto schedule
```

## Context Switching

Context switching saves and restores callee-saved registers plus the stack pointer and instruction pointer.

### x86-64 (System V ABI — Linux, macOS)

```c
typedef struct {
    void *rsp;
    void *rip;  // resume address (return address trick)
    void *rbx;
    void *rbp;
    void *r12;
    void *r13;
    void *r14;
    void *r15;
} run_context_t;
```

Assembly implementation (`run_context_amd64.S`):

```asm
# void run_context_switch(run_context_t *from, run_context_t *to)
# rdi = from, rsi = to
.globl run_context_switch
run_context_switch:
    # Save callee-saved registers to 'from'
    movq %rsp, 0x00(%rdi)
    movq %rbx, 0x10(%rdi)
    movq %rbp, 0x18(%rdi)
    movq %r12, 0x20(%rdi)
    movq %r13, 0x28(%rdi)
    movq %r14, 0x30(%rdi)
    movq %r15, 0x38(%rdi)
    leaq resume(%rip), %rax
    movq %rax, 0x08(%rdi)

    # Restore callee-saved registers from 'to'
    movq 0x10(%rsi), %rbx
    movq 0x18(%rsi), %rbp
    movq 0x20(%rsi), %r12
    movq 0x28(%rsi), %r13
    movq 0x30(%rsi), %r14
    movq 0x38(%rsi), %r15
    movq 0x00(%rsi), %rsp
    jmpq *0x08(%rsi)

resume:
    ret
```

### aarch64 (ARM64 — macOS Apple Silicon, Linux ARM)

```c
typedef struct {
    void *sp;
    void *lr;   // link register (return address)
    void *x19, *x20, *x21, *x22, *x23;
    void *x24, *x25, *x26, *x27, *x28;
    void *fp;   // x29, frame pointer
} run_context_t;
```

### Windows x86-64

Same as System V x86-64 but additionally saves XMM6–XMM15 (Windows ABI requires these to be callee-saved):

```c
typedef struct {
    void *rsp, *rip;
    void *rbx, *rbp, *rdi, *rsi;
    void *r12, *r13, *r14, *r15;
    __m128 xmm6, xmm7, xmm8, xmm9;
    __m128 xmm10, xmm11, xmm12, xmm13, xmm14, xmm15;
} run_context_t;
```

### Context Initialization

```c
void run_context_init(run_context_t *ctx, void *stack_top,
                      void (*entry)(void *), void *arg);
```

Sets up a new context so that when switched to, execution begins at `entry(arg)` on the given stack. Implementation:

1. Align `stack_top` downward to 16 bytes
2. Push a return address pointing to a `run_g_exit` trampoline (handles G completion)
3. Set `ctx->rsp` to the adjusted stack top
4. Set `ctx->rip` to a trampoline that calls `entry(arg)`

## Preemption

### Phase 1: Cooperative Preemption

The compiler inserts a preemption check at every function prologue:

```c
// Generated at the start of every function
if (__builtin_expect(run_current_g->preempt, 0)) {
    run_yield();
}
```

The scheduler sets `g->preempt = true` when a G has been running too long (checked via a periodic timer, e.g., every 10ms using `setitimer`).

### Phase 2: Signal-Based Preemption

For Gs executing tight loops without function calls:

1. A background timer thread sends `SIGURG` to the M's OS thread
2. The signal handler checks if the M is executing user code (not in the runtime)
3. If so, it modifies the signal context to redirect execution to `run_yield()` on return
4. This is the same approach Go 1.14+ uses for non-cooperative preemption

## Syscall Handling

When a G is about to make a blocking syscall (file I/O, network, sleep):

1. **Before syscall**: M detaches from its P

   ```c
   run_p_t *p = m->current_p;
   p->status = P_SYSCALL;
   m->current_p = NULL;
   // Another M can now acquire this P
   ```

2. **During syscall**: The P is available for other Ms. A "sysmon" background thread periodically checks for Ps in `P_SYSCALL` state and hands them off.

3. **After syscall returns**: M tries to reacquire its P
   ```c
   if (try_acquire_p(p)) {
       // got it back — continue running the G
   } else if (try_acquire_idle_p(&p)) {
       // got a different P — continue running the G on this P
   } else {
       // no P available — put G in global queue, park M
       put_global_queue(g);
       park_m(m);
   }
   ```

## Stack Allocation

### Phase 1: Fixed Stacks

```c
#define RUN_STACK_SIZE (64 * 1024)    // 64 KB
#define RUN_GUARD_SIZE (4 * 1024)     // 4 KB guard page

void *run_stack_alloc(void) {
    void *mem = run_vmem_alloc(RUN_STACK_SIZE);
    // Bottom page is a guard — segfaults on overflow
    run_vmem_protect(mem, RUN_GUARD_SIZE, RUN_VMEM_NONE);
    return mem;
}

void run_stack_free(void *stack) {
    run_vmem_free(stack, RUN_STACK_SIZE);
}
```

### Phase 2: Growable Stacks

```c
#define RUN_STACK_INITIAL (8 * 1024)    // 8 KB committed
#define RUN_STACK_MAX     (1024 * 1024) // 1 MB reserved (configurable via RUN_STACK_MAX)

void *run_stack_alloc(void) {
    size_t max = run_stack_max_size();  // reads RUN_STACK_MAX env var
    void *mem = run_vmem_alloc_reserve(max);  // reserve only, PROT_NONE
    // Commit the top 8 KB
    void *commit_start = (char *)mem + max - RUN_STACK_INITIAL;
    run_vmem_protect(commit_start, RUN_STACK_INITIAL, RUN_VMEM_READWRITE);
    return mem;
}
```

The runtime installs a `SIGSEGV` handler that checks if the faulting address is in a stack guard region. If so, it commits the next page and resumes execution. If the stack has reached `RUN_STACK_MAX`, it reports a stack overflow error.

## Implementation Phases

### Phase 1 — Single-Threaded Cooperative

- One P, one M, N Gs
- Fixed 64 KB stacks with guard pages
- x86-64 context switch assembly (Linux)
- Round-robin scheduling (no work stealing needed with one P)
- `run_yield()` does a context switch back to the scheduler
- Channel integration: blocking send/recv parks the G and calls schedule

### Phase 2 — Multi-Threaded

- Multiple Ps (= CPU count), dynamic M creation
- Work stealing between P local queues
- `pthread_mutex` / C11 atomics for scheduler data structures
- Syscall detach/reattach
- Cooperative preemption (function prologue checks)
- ARM64 context switch assembly

### Phase 3 — Production Hardening

- Signal-based preemption (`SIGURG`)
- Growable stacks via guard page fault handling
- Sysmon thread for detecting long-running syscalls
- Per-P allocation caches (mcache)
- Windows support (CreateThread, custom context switch, SEH for stack growth)
- Scheduler tracing and debugging hooks
