#ifndef RUN_XEV_H
#define RUN_XEV_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*run_xev_ready_cb)(int fd, uint32_t events, void *read_g, void *write_g);

int run_xev_init(run_xev_ready_cb cb);
void run_xev_close(void);

/* Bookkeeping registration for an fd. No kernel pre-registration required. */
int run_xev_open(int fd);
void run_xev_close_fd(int fd);

void run_xev_poll_read(int fd, void *g);
void run_xev_poll_write(int fd, void *g);

int run_xev_tick(void);
int run_xev_tick_blocking(int64_t timeout_ms);

int run_xev_async_init(void);
int run_xev_async_notify(void);
void run_xev_async_wait(void);

bool run_xev_has_waiters(void);

#ifdef __cplusplus
}
#endif

#endif
