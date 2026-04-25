#include "run_chan.h"

#include "run_scheduler.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ========================================================================
 * Channel Data Structure
 * ======================================================================== */

struct run_chan {
    run_mutex_t lock;

    size_t elem_size;  /* size of each element in bytes */
    size_t buffer_cap; /* buffer capacity (0 = unbuffered) */
    size_t buffer_len; /* current number of elements in buffer */
    size_t send_idx;   /* next write position in circular buffer */
    size_t recv_idx;   /* next read position in circular buffer */
    void *buffer;      /* circular buffer (NULL for unbuffered) */

    run_g_queue_t send_q; /* Gs waiting to send */
    run_g_queue_t recv_q; /* Gs waiting to receive */

    bool closed;
};

/* ========================================================================
 * Channel Creation / Destruction
 * ======================================================================== */

run_chan_t *run_chan_new(size_t elem_size, size_t buffer_cap) {
    run_chan_t *ch = (run_chan_t *)calloc(1, sizeof(run_chan_t));
    if (!ch) {
        fprintf(stderr, "run: failed to allocate channel\n");
        abort();
    }

    run_mutex_init(&ch->lock);
    ch->elem_size = elem_size;
    ch->buffer_cap = buffer_cap;
    ch->buffer_len = 0;
    ch->send_idx = 0;
    ch->recv_idx = 0;
    ch->closed = false;

    run_g_queue_init(&ch->send_q);
    run_g_queue_init(&ch->recv_q);

    if (buffer_cap > 0) {
        ch->buffer = calloc(buffer_cap, elem_size);
        if (!ch->buffer) {
            fprintf(stderr, "run: failed to allocate channel buffer\n");
            abort();
        }
    }

    return ch;
}

void run_chan_free(run_chan_t *ch) {
    if (!ch)
        return;
    run_mutex_destroy(&ch->lock);
    free(ch->buffer);
    free(ch);
}

/* ========================================================================
 * Send Operation
 *
 * Pseudocode from docs/runtime/concurrency.md:
 *   1. If closed -> panic
 *   2. Fast path: waiting receiver -> direct copy, wake receiver
 *   3. Buffer has space -> copy to circular buffer
 *   4. Block: enqueue G on send_q, yield to scheduler
 * ======================================================================== */

void run_chan_send(run_chan_t *ch, const void *data) {
    run_mutex_lock(&ch->lock);

    if (ch->closed) {
        run_mutex_unlock(&ch->lock);
        fprintf(stderr, "run: send on closed channel\n");
        abort();
    }

    /* Fast path: waiting receiver exists */
    if (ch->recv_q.len > 0) {
        run_g_t *receiver = run_g_queue_pop(&ch->recv_q);
        /* Direct copy: data -> receiver's waiting slot */
        memcpy(receiver->chan_data_ptr, data, ch->elem_size);
        run_mutex_unlock(&ch->lock);
        run_g_ready(receiver);
        return;
    }

    /* Buffer has space */
    if (ch->buffer_len < ch->buffer_cap) {
        void *slot = (char *)ch->buffer + (ch->send_idx * ch->elem_size);
        memcpy(slot, data, ch->elem_size);
        ch->send_idx = (ch->send_idx + 1) % ch->buffer_cap;
        ch->buffer_len++;
        run_mutex_unlock(&ch->lock);
        return;
    }

    /* Must block: buffer full (or unbuffered with no receiver) */
    run_g_t *g = run_current_g();
    if (!g) {
        /* Called from main thread before scheduler is running --
         * this would deadlock. */
        run_mutex_unlock(&ch->lock);
        fprintf(stderr, "run: channel send would block on main thread\n");
        abort();
    }

    g->status = G_WAITING;
    g->chan_data_ptr = (void *)data; /* sender's data stays in place */
    g->chan_panic = false;
    run_g_queue_push(&ch->send_q, g);
    run_mutex_unlock(&ch->lock);

    run_schedule(); /* context switch to scheduler */
    /* Resumed here after a receiver copies our data */
}

/* ========================================================================
 * Receive Operation
 *
 * Pseudocode from docs/runtime/concurrency.md:
 *   1. Fast path: waiting sender -> direct copy (or buffer rotate), wake sender
 *   2. Buffer has data -> copy from circular buffer
 *   3. Channel closed + empty -> zero value
 *   4. Block: enqueue G on recv_q, yield to scheduler
 * ======================================================================== */

void run_chan_recv(run_chan_t *ch, void *data) {
    run_mutex_lock(&ch->lock);

    /* Fast path: waiting sender exists */
    if (ch->send_q.len > 0) {
        run_g_t *sender = run_g_queue_pop(&ch->send_q);
        if (ch->buffer_cap > 0 && ch->buffer_len > 0) {
            /* Buffered channel with full buffer: take from buffer,
             * then copy sender's data into the freed buffer slot */
            void *slot = (char *)ch->buffer + (ch->recv_idx * ch->elem_size);
            memcpy(data, slot, ch->elem_size);
            /* Put sender's data into the buffer */
            void *send_slot = (char *)ch->buffer + (ch->send_idx * ch->elem_size);
            memcpy(send_slot, sender->chan_data_ptr, ch->elem_size);
            ch->recv_idx = (ch->recv_idx + 1) % ch->buffer_cap;
            ch->send_idx = (ch->send_idx + 1) % ch->buffer_cap;
            /* buffer_len stays the same (removed one, added one) */
        } else {
            /* Unbuffered: direct copy from sender */
            memcpy(data, sender->chan_data_ptr, ch->elem_size);
        }
        run_mutex_unlock(&ch->lock);
        run_g_ready(sender);
        return;
    }

    /* Buffer has data */
    if (ch->buffer_len > 0) {
        void *slot = (char *)ch->buffer + (ch->recv_idx * ch->elem_size);
        memcpy(data, slot, ch->elem_size);
        ch->recv_idx = (ch->recv_idx + 1) % ch->buffer_cap;
        ch->buffer_len--;
        run_mutex_unlock(&ch->lock);
        return;
    }

    /* Channel is closed and empty */
    if (ch->closed) {
        memset(data, 0, ch->elem_size); /* zero value */
        run_mutex_unlock(&ch->lock);
        return;
    }

    /* Must block: buffer empty (or unbuffered with no sender) */
    run_g_t *g = run_current_g();
    if (!g) {
        run_mutex_unlock(&ch->lock);
        fprintf(stderr, "run: channel recv would block on main thread\n");
        abort();
    }

    g->status = G_WAITING;
    g->chan_data_ptr = data; /* receiver provides the destination */
    g->chan_panic = false;
    run_g_queue_push(&ch->recv_q, g);
    run_mutex_unlock(&ch->lock);

    run_schedule(); /* context switch to scheduler */
    /* Resumed here after a sender copies data to our slot */
}

/* ========================================================================
 * Close Operation
 * ======================================================================== */

void run_chan_close(run_chan_t *ch) {
    run_mutex_lock(&ch->lock);

    if (ch->closed) {
        run_mutex_unlock(&ch->lock);
        fprintf(stderr, "run: close of closed channel\n");
        abort();
    }

    ch->closed = true;

    /* Collect all waiting Gs before releasing the lock */
    run_g_queue_t wake_list;
    run_g_queue_init(&wake_list);

    /* Wake all waiting receivers -- they get zero values */
    while (ch->recv_q.len > 0) {
        run_g_t *g = run_g_queue_pop(&ch->recv_q);
        memset(g->chan_data_ptr, 0, ch->elem_size);
        g->chan_panic = false;
        run_g_queue_push(&wake_list, g);
    }

    /* Wake all waiting senders -- they will panic */
    while (ch->send_q.len > 0) {
        run_g_t *g = run_g_queue_pop(&ch->send_q);
        g->chan_panic = true;
        run_g_queue_push(&wake_list, g);
    }

    run_mutex_unlock(&ch->lock);

    /* Make all collected Gs runnable (outside the channel lock) */
    run_g_t *g;
    while ((g = run_g_queue_pop(&wake_list)) != NULL) {
        run_g_ready(g);
    }
}
