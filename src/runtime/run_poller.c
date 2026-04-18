/*
 * run_poller.c
 *
 * libxev-backed poller implementation.
 *
 * The previous platform-specific io_uring/kqueue backend lives in
 * run_poller_legacy.c and can be selected via `-Dlegacy-poller=true`.
 */

#include "run_xev.c"
