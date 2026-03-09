#include "run_chan.h"

#include <stdio.h>
#include <stdlib.h>

struct run_chan {
    size_t elem_size;
    size_t buffer_size;
};

run_chan_t *run_chan_new(size_t elem_size, size_t buffer_size) {
    (void)elem_size;
    (void)buffer_size;
    fprintf(stderr, "run: channels not yet implemented\n");
    abort();
}

void run_chan_send(run_chan_t *ch, const void *data) {
    (void)ch;
    (void)data;
    fprintf(stderr, "run: channels not yet implemented\n");
    abort();
}

void run_chan_recv(run_chan_t *ch, void *data) {
    (void)ch;
    (void)data;
    fprintf(stderr, "run: channels not yet implemented\n");
    abort();
}

void run_chan_free(run_chan_t *ch) {
    (void)ch;
    fprintf(stderr, "run: channels not yet implemented\n");
    abort();
}
