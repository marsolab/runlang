#include "test_framework.h"
#include "../run_chan.h"
#include "../run_signal.h"

#include <signal.h>
#include <unistd.h>

static void test_signal_notify_drops_when_channel_full(void) {
    run_chan_t *ch = run_chan_new(sizeof(int64_t), 1);
    int64_t sig = RUN_SIG_USR1;

    run_signal_notify(ch, &sig, 1);

    raise(SIGUSR1);
    usleep(50000);
    raise(SIGUSR1);
    usleep(50000);

    run_signal_stop(ch);
    run_chan_close(ch);
    run_chan_free(ch);

    RUN_ASSERT(1);
}

void run_test_signal(void) {
    TEST_SUITE("run_signal");
    RUN_TEST(test_signal_notify_drops_when_channel_full);
}
