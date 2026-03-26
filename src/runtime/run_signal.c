#include "run_signal.h"

#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── POSIX signal number mapping ─────────────────────────────────────────── */

static const int sig_run_to_posix[RUN_SIG_COUNT] = {
    [RUN_SIG_INTERRUPT] = SIGINT, [RUN_SIG_TERMINATE] = SIGTERM, [RUN_SIG_HANGUP] = SIGHUP,
    [RUN_SIG_USR1] = SIGUSR1,     [RUN_SIG_USR2] = SIGUSR2,      [RUN_SIG_PIPE] = SIGPIPE,
    [RUN_SIG_ALARM] = SIGALRM,    [RUN_SIG_CHILD] = SIGCHLD,     [RUN_SIG_CONT] = SIGCONT,
    [RUN_SIG_STOP] = SIGTSTP, /* SIGSTOP cannot be caught */
    [RUN_SIG_QUIT] = SIGQUIT,
};

/* Reverse mapping: POSIX signal number → Run ordinal. Returns -1 if unknown. */
static int posix_to_run(int signo) {
    for (int i = 0; i < RUN_SIG_COUNT; i++) {
        if (sig_run_to_posix[i] == signo)
            return i;
    }
    return -1;
}

/* ── Self-pipe for async-signal-safe delivery ────────────────────────────── */

static int self_pipe[2] = {-1, -1};

static void signal_handler(int signo) {
    /* Async-signal-safe: best-effort write one byte to the pipe. */
    int saved_errno = errno;
    unsigned char byte = (unsigned char)signo;
    if (self_pipe[1] != -1) {
        (void)write(self_pipe[1], &byte, 1);
    }
    errno = saved_errno;
}

/* ── Channel registry ────────────────────────────────────────────────────── */

#define MAX_REGISTRATIONS 64

typedef struct {
    run_chan_t *ch;
    bool signals[RUN_SIG_COUNT]; /* which Run signals this registration wants */
} registration_t;

static registration_t registry[MAX_REGISTRATIONS];
static int registry_count = 0;
static pthread_mutex_t registry_mutex = PTHREAD_MUTEX_INITIALIZER;

static void remove_registration_at_locked(int idx, bool restore_handlers);

/* ── Dispatcher thread ───────────────────────────────────────────────────── */

static pthread_t dispatcher_thread;
static pthread_once_t dispatcher_once = PTHREAD_ONCE_INIT;

static void *dispatcher_fn(void *arg) {
    (void)arg;
    for (;;) {
        unsigned char byte;
        ssize_t n = read(self_pipe[0], &byte, 1);
        if (n != 1) {
            if (n == -1 && errno == EINTR)
                continue;
            continue;
        }

        int signo = (int)byte;
        int run_sig = posix_to_run(signo);
        if (run_sig < 0)
            continue;

        int64_t ordinal = (int64_t)run_sig;

        pthread_mutex_lock(&registry_mutex);
        for (int i = 0; i < registry_count;) {
            if (!registry[i].signals[run_sig]) {
                i++;
                continue;
            }

            switch (run_chan_try_send(registry[i].ch, &ordinal)) {
            case RUN_CHAN_SEND_OK:
            case RUN_CHAN_SEND_WOULD_BLOCK:
                i++;
                break;
            case RUN_CHAN_SEND_CLOSED:
                remove_registration_at_locked(i, true);
                break;
            }
        }
        pthread_mutex_unlock(&registry_mutex);
    }
    return NULL;
}

static void start_dispatcher(void) {
    if (pipe(self_pipe) != 0)
        return;

    int flags = fcntl(self_pipe[1], F_GETFL, 0);
    if (flags != -1) {
        (void)fcntl(self_pipe[1], F_SETFL, flags | O_NONBLOCK);
    }

    if (pthread_create(&dispatcher_thread, NULL, dispatcher_fn, NULL) != 0) {
        close(self_pipe[0]);
        close(self_pipe[1]);
        self_pipe[0] = -1;
        self_pipe[1] = -1;
    }
}

static void ensure_dispatcher(void) {
    pthread_once(&dispatcher_once, start_dispatcher);
}

/* ── Install/remove sigaction for a POSIX signal ─────────────────────────── */

static void install_handler(int posix_sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(posix_sig, &sa, NULL);
}

static bool signal_has_any_registration(int run_sig) {
    for (int i = 0; i < registry_count; i++) {
        if (registry[i].signals[run_sig])
            return true;
    }
    return false;
}

static void remove_registration_at_locked(int idx, bool restore_handlers) {
    bool had[RUN_SIG_COUNT];
    memcpy(had, registry[idx].signals, sizeof(had));

    for (int j = idx; j < registry_count - 1; j++) {
        registry[j] = registry[j + 1];
    }
    registry_count--;

    if (!restore_handlers) {
        return;
    }

    for (int s = 0; s < RUN_SIG_COUNT; s++) {
        if (had[s] && !signal_has_any_registration(s)) {
            signal(sig_run_to_posix[s], SIG_DFL);
        }
    }
}

/* ── Public API ──────────────────────────────────────────────────────────── */

void run_signal_notify(run_chan_t *ch, const int64_t *signals, size_t nsignals) {
    if (!ch)
        return;

    ensure_dispatcher();
    pthread_mutex_lock(&registry_mutex);

    /* Find or create registration for this channel */
    registration_t *reg = NULL;
    for (int i = 0; i < registry_count; i++) {
        if (registry[i].ch == ch) {
            reg = &registry[i];
            break;
        }
    }
    if (!reg) {
        if (registry_count >= MAX_REGISTRATIONS) {
            pthread_mutex_unlock(&registry_mutex);
            return;
        }
        reg = &registry[registry_count++];
        reg->ch = ch;
        memset(reg->signals, 0, sizeof(reg->signals));
    }

    if (nsignals == 0) {
        /* Register for all signals */
        for (int i = 0; i < RUN_SIG_COUNT; i++) {
            reg->signals[i] = true;
            install_handler(sig_run_to_posix[i]);
        }
    } else {
        for (size_t i = 0; i < nsignals; i++) {
            int s = (int)signals[i];
            if (s >= 0 && s < RUN_SIG_COUNT) {
                reg->signals[s] = true;
                install_handler(sig_run_to_posix[s]);
            }
        }
    }

    pthread_mutex_unlock(&registry_mutex);
}

void run_signal_stop(run_chan_t *ch) {
    if (!ch)
        return;

    pthread_mutex_lock(&registry_mutex);

    for (int i = 0; i < registry_count; i++) {
        if (registry[i].ch == ch) {
            remove_registration_at_locked(i, true);
            break;
        }
    }

    pthread_mutex_unlock(&registry_mutex);
}

void run_signal_ignore(const int64_t *signals, size_t nsignals) {
    if (nsignals == 0) {
        for (int i = 0; i < RUN_SIG_COUNT; i++) {
            signal(sig_run_to_posix[i], SIG_IGN);
        }
    } else {
        for (size_t i = 0; i < nsignals; i++) {
            int s = (int)signals[i];
            if (s >= 0 && s < RUN_SIG_COUNT) {
                signal(sig_run_to_posix[s], SIG_IGN);
            }
        }
    }
}

void run_signal_reset(const int64_t *signals, size_t nsignals) {
    pthread_mutex_lock(&registry_mutex);

    if (nsignals == 0) {
        /* Reset all */
        for (int i = 0; i < RUN_SIG_COUNT; i++) {
            signal(sig_run_to_posix[i], SIG_DFL);
        }
        /* Remove all registrations */
        registry_count = 0;
    } else {
        for (size_t i = 0; i < nsignals; i++) {
            int s = (int)signals[i];
            if (s >= 0 && s < RUN_SIG_COUNT) {
                signal(sig_run_to_posix[s], SIG_DFL);
                /* Remove this signal from all registrations */
                for (int r = 0; r < registry_count; r++) {
                    registry[r].signals[s] = false;
                }
            }
        }
        /* Clean up empty registrations */
        int w = 0;
        for (int r = 0; r < registry_count; r++) {
            bool has_any = false;
            for (int s = 0; s < RUN_SIG_COUNT; s++) {
                if (registry[r].signals[s]) {
                    has_any = true;
                    break;
                }
            }
            if (has_any) {
                if (w != r)
                    registry[w] = registry[r];
                w++;
            }
        }
        registry_count = w;
    }

    pthread_mutex_unlock(&registry_mutex);
}
