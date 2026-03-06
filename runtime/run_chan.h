#ifndef RUN_CHAN_H
#define RUN_CHAN_H

#include <stddef.h>

typedef struct run_chan run_chan_t;

run_chan_t *run_chan_new(size_t elem_size, size_t buffer_size);
void run_chan_send(run_chan_t *ch, const void *data);
void run_chan_recv(run_chan_t *ch, void *data);
void run_chan_free(run_chan_t *ch);

#endif
