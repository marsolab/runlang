#ifndef RUN_PLATFORM_H
#define RUN_PLATFORM_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <process.h>
#include <windows.h>

#define RUN_THREAD_LOCAL __declspec(thread)

typedef HANDLE run_thread_t;
typedef SRWLOCK run_mutex_t;
typedef CONDITION_VARIABLE run_cond_t;
typedef void (*run_timer_fn)(void *);

typedef struct {
    HANDLE handle;
    run_timer_fn fn;
    void *arg;
} run_platform_timer_t;

#define RUN_MUTEX_INITIALIZER SRWLOCK_INIT

typedef void *(*run_thread_fn)(void *);

typedef struct {
    run_thread_fn fn;
    void *arg;
} run_thread_start_t;

static unsigned __stdcall run_thread_trampoline(void *arg) {
    run_thread_start_t *start = (run_thread_start_t *)arg;
    run_thread_fn fn = start->fn;
    void *fn_arg = start->arg;
    free(start);
    (void)fn(fn_arg);
    return 0;
}

static VOID CALLBACK run_timer_trampoline(PVOID arg, BOOLEAN fired) {
    (void)fired;
    run_platform_timer_t *timer = (run_platform_timer_t *)arg;
    timer->fn(timer->arg);
}

static inline void run_mutex_init(run_mutex_t *m) {
    InitializeSRWLock(m);
}

static inline void run_mutex_destroy(run_mutex_t *m) {
    (void)m;
}

static inline void run_mutex_lock(run_mutex_t *m) {
    AcquireSRWLockExclusive(m);
}

static inline void run_mutex_unlock(run_mutex_t *m) {
    ReleaseSRWLockExclusive(m);
}

static inline void run_cond_init(run_cond_t *c) {
    InitializeConditionVariable(c);
}

static inline void run_cond_destroy(run_cond_t *c) {
    (void)c;
}

static inline void run_cond_wait(run_cond_t *c, run_mutex_t *m) {
    SleepConditionVariableSRW(c, m, INFINITE, 0);
}

static inline void run_cond_signal(run_cond_t *c) {
    WakeConditionVariable(c);
}

static inline int run_thread_create(run_thread_t *thread, run_thread_fn fn, void *arg) {
    run_thread_start_t *start = (run_thread_start_t *)malloc(sizeof(run_thread_start_t));
    if (start == NULL)
        return -1;
    start->fn = fn;
    start->arg = arg;

    uintptr_t handle = _beginthreadex(NULL, 0, run_thread_trampoline, start, 0, NULL);
    if (handle == 0) {
        free(start);
        return -1;
    }
    *thread = (HANDLE)handle;
    return 0;
}

static inline void run_thread_detach(run_thread_t thread) {
    CloseHandle(thread);
}

static inline run_thread_t run_thread_self(void) {
    return GetCurrentThread();
}

static inline uintptr_t run_thread_seed(void) {
    return (uintptr_t)GetCurrentThreadId();
}

static inline long run_cpu_count(void) {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return (long)info.dwNumberOfProcessors;
}

static inline bool run_timer_start(run_platform_timer_t *timer, uint32_t interval_us,
                                   run_timer_fn fn, void *arg) {
    timer->handle = NULL;
    timer->fn = fn;
    timer->arg = arg;

    DWORD interval_ms = (DWORD)((interval_us + 999u) / 1000u);
    if (interval_ms == 0)
        interval_ms = 1;

    return CreateTimerQueueTimer(&timer->handle, NULL, run_timer_trampoline, timer, interval_ms,
                                 interval_ms, WT_EXECUTEDEFAULT) != 0;
}

static inline void run_timer_stop(run_platform_timer_t *timer) {
    if (timer->handle != NULL) {
        DeleteTimerQueueTimer(NULL, timer->handle, INVALID_HANDLE_VALUE);
        timer->handle = NULL;
    }
}

#else

#include <pthread.h>
#include <unistd.h>

#define RUN_THREAD_LOCAL __thread

typedef pthread_t run_thread_t;
typedef pthread_mutex_t run_mutex_t;
typedef pthread_cond_t run_cond_t;
typedef void (*run_timer_fn)(void *);

typedef struct {
    int unused;
} run_platform_timer_t;

#define RUN_MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER

typedef void *(*run_thread_fn)(void *);

static inline void run_mutex_init(run_mutex_t *m) {
    pthread_mutex_init(m, NULL);
}

static inline void run_mutex_destroy(run_mutex_t *m) {
    pthread_mutex_destroy(m);
}

static inline void run_mutex_lock(run_mutex_t *m) {
    pthread_mutex_lock(m);
}

static inline void run_mutex_unlock(run_mutex_t *m) {
    pthread_mutex_unlock(m);
}

static inline void run_cond_init(run_cond_t *c) {
    pthread_cond_init(c, NULL);
}

static inline void run_cond_destroy(run_cond_t *c) {
    pthread_cond_destroy(c);
}

static inline void run_cond_wait(run_cond_t *c, run_mutex_t *m) {
    pthread_cond_wait(c, m);
}

static inline void run_cond_signal(run_cond_t *c) {
    pthread_cond_signal(c);
}

static inline int run_thread_create(run_thread_t *thread, run_thread_fn fn, void *arg) {
    return pthread_create(thread, NULL, fn, arg);
}

static inline void run_thread_detach(run_thread_t thread) {
    pthread_detach(thread);
}

static inline run_thread_t run_thread_self(void) {
    return pthread_self();
}

static inline uintptr_t run_thread_seed(void) {
    return (uintptr_t)pthread_self();
}

static inline long run_cpu_count(void) {
    return sysconf(_SC_NPROCESSORS_ONLN);
}

static inline bool run_timer_start(run_platform_timer_t *timer, uint32_t interval_us,
                                   run_timer_fn fn, void *arg) {
    (void)timer;
    (void)interval_us;
    (void)fn;
    (void)arg;
    return false;
}

static inline void run_timer_stop(run_platform_timer_t *timer) {
    (void)timer;
}

#endif

#endif
