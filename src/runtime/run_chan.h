#ifndef RUN_CHAN_H
#define RUN_CHAN_H

#include <stdbool.h>
#include <stddef.h>

typedef struct run_chan run_chan_t;

/* Create a new channel.
 * elem_size: size of each element (e.g., sizeof(int64_t))
 * buffer_cap: buffer capacity (0 for unbuffered, >0 for buffered) */
run_chan_t *run_chan_new(size_t elem_size, size_t buffer_cap);

/* Send data to channel. Blocks if buffer is full or no receiver (unbuffered). */
void run_chan_send(run_chan_t *ch, const void *data);

/* Receive data from channel. Blocks if buffer is empty and no sender. */
void run_chan_recv(run_chan_t *ch, void *data);

/* Close the channel. Wakes all waiting receivers (zero values) and senders (panic). */
void run_chan_close(run_chan_t *ch);

/* Free the channel. Must be closed with no waiting Gs. */
void run_chan_free(run_chan_t *ch);

#endif
