---
title: "Channels and Synchronization"
sidebar:
  order: 2
---


## Overview

Channels are the primary synchronization and communication mechanism in Run. They provide typed, thread-safe message passing between green threads, deeply integrated with the scheduler for efficient blocking and waking.

## Channel Data Structure

```c
typedef struct run_g_queue {
    run_g_t *head;
    run_g_t *tail;
    uint32_t len;
} run_g_queue_t;

typedef struct run_chan {
    mutex_t          lock;         // protects all fields

    size_t           elem_size;    // size of each element in bytes
    size_t           buffer_cap;   // buffer capacity (0 = unbuffered)
    size_t           buffer_len;   // number of elements currently in buffer
    size_t           send_idx;     // next write position in circular buffer
    size_t           recv_idx;     // next read position in circular buffer
    void            *buffer;       // circular buffer (NULL for unbuffered)

    run_g_queue_t    send_q;       // Gs waiting to send
    run_g_queue_t    recv_q;       // Gs waiting to receive

    bool             closed;       // true after channel is closed
} run_chan_t;
```

## Channel Creation

```c
// Create a new channel.
// elem_size: size of each element (e.g., sizeof(int))
// buffer_cap: buffer capacity (0 for unbuffered, >0 for buffered)
run_chan_t *run_chan_new(size_t elem_size, size_t buffer_cap);
```

Implementation:
1. Allocate the `run_chan_t` struct
2. If `buffer_cap > 0`, allocate a circular buffer of `elem_size * buffer_cap` bytes
3. Initialize the mutex, zero out queues, set `closed = false`

## Send Operation

```c
void run_chan_send(run_chan_t *ch, const void *data);
```

```
run_chan_send(ch, data):
    lock(ch->lock)

    if ch->closed:
        panic("send on closed channel")

    // Fast path: waiting receiver exists
    if ch->recv_q.len > 0:
        receiver = dequeue(ch->recv_q)
        // Direct copy: data -> receiver's waiting slot
        memcpy(receiver->chan_data_ptr, data, ch->elem_size)
        receiver->status = G_RUNNABLE
        push_to_run_queue(receiver)
        unlock(ch->lock)
        return

    // Buffer has space
    if ch->buffer_len < ch->buffer_cap:
        slot = ch->buffer + (ch->send_idx * ch->elem_size)
        memcpy(slot, data, ch->elem_size)
        ch->send_idx = (ch->send_idx + 1) % ch->buffer_cap
        ch->buffer_len++
        unlock(ch->lock)
        return

    // Must block: buffer full (or unbuffered with no receiver)
    g = run_current_g()
    g->status = G_WAITING
    g->chan_data_ptr = (void *)data  // sender's data stays in place
    enqueue(ch->send_q, g)
    unlock(ch->lock)
    run_schedule()  // context switch to scheduler
    // resumed here after a receiver copies our data
```

## Receive Operation

```c
void run_chan_recv(run_chan_t *ch, void *data);
```

```
run_chan_recv(ch, data):
    lock(ch->lock)

    // Fast path: waiting sender exists (unbuffered or buffer full)
    if ch->send_q.len > 0:
        sender = dequeue(ch->send_q)
        if ch->buffer_cap > 0:
            // Buffered: take from buffer, then copy sender's data into buffer
            slot = ch->buffer + (ch->recv_idx * ch->elem_size)
            memcpy(data, slot, ch->elem_size)
            memcpy(slot, sender->chan_data_ptr, ch->elem_size)
            ch->recv_idx = (ch->recv_idx + 1) % ch->buffer_cap
            ch->send_idx = (ch->send_idx + 1) % ch->buffer_cap
        else:
            // Unbuffered: direct copy from sender
            memcpy(data, sender->chan_data_ptr, ch->elem_size)
        sender->status = G_RUNNABLE
        push_to_run_queue(sender)
        unlock(ch->lock)
        return

    // Buffer has data
    if ch->buffer_len > 0:
        slot = ch->buffer + (ch->recv_idx * ch->elem_size)
        memcpy(data, slot, ch->elem_size)
        ch->recv_idx = (ch->recv_idx + 1) % ch->buffer_cap
        ch->buffer_len--
        unlock(ch->lock)
        return

    // Channel is closed and empty
    if ch->closed:
        memset(data, 0, ch->elem_size)  // zero value
        unlock(ch->lock)
        return

    // Must block: buffer empty (or unbuffered with no sender)
    g = run_current_g()
    g->status = G_WAITING
    g->chan_data_ptr = data  // receiver provides the destination
    enqueue(ch->recv_q, g)
    unlock(ch->lock)
    run_schedule()  // context switch to scheduler
    // resumed here after a sender copies data to our slot
```

## Close Operation

```c
void run_chan_close(run_chan_t *ch);
```

```
run_chan_close(ch):
    lock(ch->lock)

    if ch->closed:
        panic("close of closed channel")

    ch->closed = true

    // Wake all waiting receivers — they get zero values
    while ch->recv_q.len > 0:
        g = dequeue(ch->recv_q)
        memset(g->chan_data_ptr, 0, ch->elem_size)
        g->status = G_RUNNABLE
        push_to_run_queue(g)

    // Wake all waiting senders — they will panic
    while ch->send_q.len > 0:
        g = dequeue(ch->send_q)
        g->chan_panic = true  // flag: panic when resumed
        g->status = G_RUNNABLE
        push_to_run_queue(g)

    unlock(ch->lock)
```

## Free Operation

```c
void run_chan_free(run_chan_t *ch);
```

Frees the channel's buffer (if any) and the channel struct itself. The channel must be closed and have no waiting Gs.

## Unbuffered Channel Optimization

For unbuffered channels (the common case), a direct copy optimization avoids intermediate buffering:

1. When a sender arrives and a receiver is waiting: copy data directly from sender's stack frame to receiver's stack frame
2. When a receiver arrives and a sender is waiting: copy data directly from sender's stack frame to receiver's destination

This means data crosses at most one `memcpy` — no intermediate buffer allocation.

## Scheduler Integration

Channels are the main reason Gs block. The integration is tight:

1. **Blocking**: A G that cannot complete a send/recv sets its status to `G_WAITING`, enqueues itself on the channel's wait queue, and calls `run_schedule()` to switch to the scheduler
2. **Waking**: When a matching operation arrives, the blocked G is dequeued, its status is set to `G_RUNNABLE`, and it is pushed to the current P's local run queue (for cache affinity) or the global queue
3. **Lock ordering**: Channel lock is always acquired before scheduler locks to prevent deadlocks

## Future: Select Statement

The `select` statement allows waiting on multiple channel operations simultaneously:

```go
select {
    msg := <-ch1 {
        // received from ch1
    }
    ch2 <- value {
        // sent to ch2
    }
    default {
        // no channel ready
    }
}
```

Implementation approach:
1. Register the G on all specified channels' wait queues
2. If any channel is immediately ready, proceed with that case
3. If none are ready and there's a `default` case, execute default
4. If none are ready and no default, park the G
5. When any channel becomes ready, dequeue the G from ALL wait queues (not just the one that fired)

## Future: Synchronization Primitives

Built on top of the scheduler's G parking mechanism:

### Mutex

```c
typedef struct {
    _Atomic(uint32_t) state;   // 0 = unlocked, 1 = locked
    run_g_queue_t     waiters; // Gs waiting to acquire
    mutex_t           lock;    // protects waiters queue
} run_mutex_t;
```

- `lock`: try atomic CAS 0→1. If fail, park G on waiters queue
- `unlock`: wake one G from waiters queue, or set state to 0

### WaitGroup

```c
typedef struct {
    _Atomic(int32_t)  counter;
    run_g_queue_t     waiters;
    mutex_t           lock;
} run_waitgroup_t;
```

- `add(n)`: atomic add to counter
- `done()`: atomic decrement; if reaches 0, wake all waiters
- `wait()`: if counter > 0, park G on waiters queue

### Once

```c
typedef struct {
    _Atomic(uint32_t) done;
    mutex_t           lock;
} run_once_t;
```

- `do(fn)`: check `done` flag. If 0, acquire lock, double-check, call fn, set done=1
