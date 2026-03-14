---
title: "Platform-Specific Details"
sidebar:
  order: 4
---

## Platform Support Matrix

| Feature           | Linux                           | macOS                           | Windows                              |
| ----------------- | ------------------------------- | ------------------------------- | ------------------------------------ |
| Virtual memory    | `mmap` / `munmap`               | `mmap` / `munmap`               | `VirtualAlloc` / `VirtualFree`       |
| Page release      | `madvise(MADV_DONTNEED)`        | `madvise(MADV_FREE)`            | `VirtualFree(MEM_DECOMMIT)`          |
| Thread creation   | `pthread_create`                | `pthread_create`                | `CreateThread`                       |
| Thread parking    | `pthread_cond_wait`             | `pthread_cond_wait`             | `WaitForSingleObject`                |
| Mutexes           | `pthread_mutex`                 | `pthread_mutex`                 | `CRITICAL_SECTION`                   |
| CPU count         | `sysconf(_SC_NPROCESSORS_ONLN)` | `sysconf(_SC_NPROCESSORS_ONLN)` | `GetSystemInfo`                      |
| Stack guard fault | `SIGSEGV` handler               | `SIGSEGV` handler               | SEH (Structured Exception Handling)  |
| Preemption signal | `SIGURG`                        | `SIGURG`                        | `SuspendThread` / `GetThreadContext` |
| Network polling   | `epoll`                         | `kqueue`                        | IOCP                                 |
| Context switch    | System V ABI asm                | System V ABI asm                | Windows ABI asm                      |
| TLS               | `__thread` / `pthread_key`      | `__thread` / `pthread_key`      | `__declspec(thread)` / `TlsAlloc`    |

## Virtual Memory

### Linux and macOS

Both use the POSIX `mmap` interface. Key flags:

```c
// Allocate anonymous private memory (not backed by a file)
void *p = mmap(NULL, size,
    PROT_READ | PROT_WRITE,        // initial protection
    MAP_PRIVATE | MAP_ANONYMOUS,   // private, not file-backed
    -1, 0);                        // no fd, no offset

// Reserve address space without committing physical memory
void *p = mmap(NULL, size,
    PROT_NONE,                     // no access (guard/reserve)
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1, 0);

// Commit pages within reserved region
mprotect(ptr, size, PROT_READ | PROT_WRITE);

// Release physical pages back to OS (keeps virtual mapping)
madvise(ptr, size, MADV_DONTNEED);  // Linux: zeroes pages on next access
madvise(ptr, size, MADV_FREE);      // macOS: lazy release

// Unmap entirely
munmap(ptr, size);
```

**macOS-specific notes:**

- `MAP_ANONYMOUS` is available (not just `MAP_ANON`)
- `MADV_FREE` is preferred over `MADV_DONTNEED` (lazier, better performance)
- Mach VM APIs (`vm_allocate`, `vm_deallocate`) are an alternative but unnecessary — `mmap` works fine

### Windows

Windows uses a two-stage model: reserve then commit.

```c
// Reserve address space (no physical memory yet)
void *p = VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_NOACCESS);

// Commit pages within reserved region
VirtualAlloc(ptr, size, MEM_COMMIT, PAGE_READWRITE);

// Reserve + commit in one call (equivalent to mmap with PROT_READ|PROT_WRITE)
void *p = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);

// Decommit (release physical pages, keep reservation)
VirtualFree(ptr, size, MEM_DECOMMIT);

// Release entirely (must use original base and size 0)
VirtualFree(base_ptr, 0, MEM_RELEASE);

// Change protection
DWORD old_protect;
VirtualProtect(ptr, size, PAGE_READWRITE, &old_protect);
```

## Thread Management

### POSIX (Linux, macOS)

```c
// Create thread
pthread_t thread;
pthread_create(&thread, NULL, thread_func, arg);

// Park thread (wait on condition variable)
pthread_mutex_lock(&mutex);
while (!condition) {
    pthread_cond_wait(&cond, &mutex);
}
pthread_mutex_unlock(&mutex);

// Wake thread
pthread_mutex_lock(&mutex);
condition = true;
pthread_cond_signal(&cond);    // wake one
pthread_cond_broadcast(&cond); // wake all
pthread_mutex_unlock(&mutex);

// Set thread stack size (for M threads, not G stacks)
pthread_attr_t attr;
pthread_attr_init(&attr);
pthread_attr_setstacksize(&attr, 2 * 1024 * 1024);  // 2 MB
pthread_create(&thread, &attr, thread_func, arg);
```

### Windows

```c
// Create thread
HANDLE thread = CreateThread(NULL, 0, thread_func, arg, 0, &thread_id);

// Park thread (wait on event)
WaitForSingleObject(event, INFINITE);

// Wake thread
SetEvent(event);        // wake one waiter
// or use condition variables (Vista+):
SleepConditionVariableCS(&condvar, &critical_section, INFINITE);
WakeConditionVariable(&condvar);
WakeAllConditionVariable(&condvar);
```

## Stack Guard and Growth

### Linux and macOS: SIGSEGV Handler

```c
#include <signal.h>

static void stack_fault_handler(int sig, siginfo_t *info, void *ucontext) {
    void *fault_addr = info->si_addr;

    // Check if fault_addr is in any G's guard region
    run_g_t *g = find_g_by_guard_addr(fault_addr);
    if (g != NULL) {
        // Stack overflow in a known green thread
        if (can_grow_stack(g)) {
            // Commit the next page
            void *page = align_down(fault_addr, PAGE_SIZE);
            mprotect(page, PAGE_SIZE, PROT_READ | PROT_WRITE);
            g->stack_size += PAGE_SIZE;
            return;  // resume execution
        } else {
            // Stack overflow: exceeded maximum
            fprintf(stderr, "run: stack overflow in green thread %llu\n", g->id);
            abort();
        }
    }

    // Not a stack guard fault — invoke default handler
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
    raise(SIGSEGV);
}

// Install at init:
struct sigaction sa;
sa.sa_sigaction = stack_fault_handler;
sigemptyset(&sa.sa_mask);
sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
sigaction(SIGSEGV, &sa, NULL);

// Provide an alternate signal stack (so we can handle stack overflow)
stack_t ss;
ss.ss_sp = malloc(SIGSTKSZ);
ss.ss_size = SIGSTKSZ;
ss.ss_flags = 0;
sigaltstack(&ss, NULL);
```

### macOS Alternative: Mach Exception Handling

macOS also supports Mach exception ports, which can catch `EXC_BAD_ACCESS` before it becomes a SIGSEGV. This is more reliable but more complex:

```c
// Create exception port
mach_port_t exception_port;
mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exception_port);

// Register for EXC_BAD_ACCESS
task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS,
    exception_port, EXCEPTION_DEFAULT, THREAD_STATE_NONE);

// Handle in a dedicated thread
// (Mach exception messages are received via mach_msg)
```

For simplicity, Phase 1 uses SIGSEGV on both Linux and macOS.

### Windows: Structured Exception Handling (SEH)

```c
LONG WINAPI stack_fault_handler(EXCEPTION_POINTERS *ep) {
    if (ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        void *fault_addr = (void *)ep->ExceptionRecord->ExceptionInformation[1];
        run_g_t *g = find_g_by_guard_addr(fault_addr);
        if (g != NULL && can_grow_stack(g)) {
            void *page = align_down(fault_addr, PAGE_SIZE);
            VirtualAlloc(page, PAGE_SIZE, MEM_COMMIT, PAGE_READWRITE);
            g->stack_size += PAGE_SIZE;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

// Install at init:
AddVectoredExceptionHandler(1, stack_fault_handler);
```

## Preemption Signals

### Linux and macOS: SIGURG

Go 1.14+ uses `SIGURG` for asynchronous preemption because:

- It is not commonly used by applications
- It does not interfere with debuggers
- It is safe to deliver to any thread

```c
// Send preemption signal to a specific M's OS thread
pthread_kill(m->thread, SIGURG);

// Handler: runs on the target thread
static void preempt_handler(int sig, siginfo_t *info, void *uctx) {
    run_m_t *m = run_current_m();
    if (m == NULL || m->current_g == NULL) return;

    run_g_t *g = m->current_g;
    if (g->status != G_RUNNING) return;

    // Check if we're in safe-to-preempt code (not in runtime)
    ucontext_t *ctx = (ucontext_t *)uctx;
    void *pc = (void *)ctx->uc_mcontext.gregs[REG_RIP];  // Linux x86-64
    if (is_runtime_code(pc)) return;

    // Set up the G to yield when the signal returns
    g->preempt = true;
    // Optionally: modify the signal context to redirect to run_yield
}
```

### Windows: Thread Suspension

Windows doesn't have an equivalent to SIGURG. Options:

1. **SuspendThread/GetThreadContext/SetThreadContext/ResumeThread** — directly inspect and modify the thread's register state
2. **QueueUserAPC** — queue an async procedure call on the target thread (requires the thread to enter an alertable wait state)

Option 1 is more reliable for preemption:

```c
SuspendThread(m->thread);
CONTEXT ctx;
ctx.ContextFlags = CONTEXT_CONTROL;
GetThreadContext(m->thread, &ctx);
// Check if Rip is in user code, set preempt flag
m->current_g->preempt = true;
ResumeThread(m->thread);
```

## Network Polling

Network polling integrates with the scheduler to efficiently handle I/O-bound Gs.

### Linux: epoll

```c
int epfd = epoll_create1(0);

// Register interest
struct epoll_event ev = { .events = EPOLLIN, .data.ptr = g };
epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);

// Poll (non-blocking check from scheduler)
struct epoll_event events[64];
int n = epoll_wait(epfd, events, 64, 0);  // timeout=0 for non-blocking
for (int i = 0; i < n; i++) {
    run_g_t *g = events[i].data.ptr;
    g->status = G_RUNNABLE;
    push_to_run_queue(g);
}
```

### macOS: kqueue

```c
int kq = kqueue();

// Register interest
struct kevent ev;
EV_SET(&ev, fd, EVFILT_READ, EV_ADD, 0, 0, g);
kevent(kq, &ev, 1, NULL, 0, NULL);

// Poll (non-blocking)
struct kevent events[64];
struct timespec ts = {0, 0};  // no wait
int n = kevent(kq, NULL, 0, events, 64, &ts);
for (int i = 0; i < n; i++) {
    run_g_t *g = events[i].udata;
    g->status = G_RUNNABLE;
    push_to_run_queue(g);
}
```

### Windows: IOCP

```c
HANDLE iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);

// Associate a socket
CreateIoCompletionPort((HANDLE)socket, iocp, (ULONG_PTR)g, 0);

// Poll (non-blocking)
OVERLAPPED_ENTRY entries[64];
ULONG count;
GetQueuedCompletionStatusEx(iocp, entries, 64, &count, 0, FALSE);
for (ULONG i = 0; i < count; i++) {
    run_g_t *g = (run_g_t *)entries[i].lpCompletionKey;
    g->status = G_RUNNABLE;
    push_to_run_queue(g);
}
```

## Context Switch Assembly — Full Implementations

### x86-64 (System V ABI — Linux, macOS)

```asm
# run_context_amd64.S
.text

# void run_context_switch(run_context_t *from, run_context_t *to)
.globl run_context_switch
run_context_switch:
    # Save callee-saved registers
    movq    %rbx,  0x00(%rdi)
    movq    %rbp,  0x08(%rdi)
    movq    %r12,  0x10(%rdi)
    movq    %r13,  0x18(%rdi)
    movq    %r14,  0x20(%rdi)
    movq    %r15,  0x28(%rdi)
    # Save stack pointer
    movq    %rsp,  0x30(%rdi)
    # Save return address (instruction pointer)
    movq    (%rsp), %rax
    movq    %rax,  0x38(%rdi)

    # Restore callee-saved registers
    movq    0x00(%rsi), %rbx
    movq    0x08(%rsi), %rbp
    movq    0x10(%rsi), %r12
    movq    0x18(%rsi), %r13
    movq    0x20(%rsi), %r14
    movq    0x28(%rsi), %r15
    # Restore stack pointer
    movq    0x30(%rsi), %rsp
    # Jump to saved instruction pointer
    jmpq    *0x38(%rsi)
```

### aarch64 (ARM64 — macOS Apple Silicon, Linux)

```asm
# run_context_arm64.S
.text

# void run_context_switch(run_context_t *from, run_context_t *to)
.globl run_context_switch
run_context_switch:
    # Save callee-saved registers
    stp     x19, x20, [x0, #0x00]
    stp     x21, x22, [x0, #0x10]
    stp     x23, x24, [x0, #0x20]
    stp     x25, x26, [x0, #0x30]
    stp     x27, x28, [x0, #0x40]
    stp     x29, x30, [x0, #0x50]    # fp + lr
    mov     x2, sp
    str     x2,       [x0, #0x60]    # sp

    # Restore callee-saved registers
    ldp     x19, x20, [x1, #0x00]
    ldp     x21, x22, [x1, #0x10]
    ldp     x23, x24, [x1, #0x20]
    ldp     x25, x26, [x1, #0x30]
    ldp     x27, x28, [x1, #0x40]
    ldp     x29, x30, [x1, #0x50]    # fp + lr
    ldr     x2,       [x1, #0x60]
    mov     sp, x2
    ret                               # return to restored lr
```

## Thread-Local Storage (TLS)

Each M needs quick access to its current G and P. This is stored in thread-local storage.

### POSIX

```c
static __thread run_m_t *tls_current_m;

run_m_t *run_current_m(void) { return tls_current_m; }
run_g_t *run_current_g(void) { return tls_current_m ? tls_current_m->current_g : NULL; }
```

### Windows

```c
static __declspec(thread) run_m_t *tls_current_m;

// Or using TLS API for dynamic loading:
static DWORD tls_index;
// Init: tls_index = TlsAlloc();
// Get:  run_m_t *m = TlsGetValue(tls_index);
// Set:  TlsSetValue(tls_index, m);
```
