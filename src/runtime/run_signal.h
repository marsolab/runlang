#ifndef RUN_SIGNAL_H
#define RUN_SIGNAL_H

#include "run_chan.h"

#include <stddef.h>
#include <stdint.h>

/* Signal enum ordinals matching the Run sum type declaration order. */
#define RUN_SIG_INTERRUPT 0  /* SIGINT  */
#define RUN_SIG_TERMINATE 1  /* SIGTERM */
#define RUN_SIG_HANGUP    2  /* SIGHUP  */
#define RUN_SIG_USR1      3  /* SIGUSR1 */
#define RUN_SIG_USR2      4  /* SIGUSR2 */
#define RUN_SIG_PIPE      5  /* SIGPIPE */
#define RUN_SIG_ALARM     6  /* SIGALRM */
#define RUN_SIG_CHILD     7  /* SIGCHLD */
#define RUN_SIG_CONT      8  /* SIGCONT */
#define RUN_SIG_STOP      9  /* SIGTSTP (SIGSTOP cannot be caught) */
#define RUN_SIG_QUIT     10  /* SIGQUIT */
#define RUN_SIG_COUNT    11

/* Register channel to receive signals.
 * signals: array of Run signal ordinals. nsignals: count (0 = all). */
void run_signal_notify(run_chan_t *ch, const int64_t *signals, size_t nsignals);

/* Stop relaying signals to the given channel. */
void run_signal_stop(run_chan_t *ch);

/* Ignore the specified signals (0 count = all catchable). */
void run_signal_ignore(const int64_t *signals, size_t nsignals);

/* Reset signal handlers to default (0 count = all). */
void run_signal_reset(const int64_t *signals, size_t nsignals);

#endif
