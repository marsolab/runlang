#include "run_scheduler.h"

void run_scheduler_init(void) {
    /* stub: no-op for MVP */
}

void run_scheduler_run(void) {
    /* stub: no-op for MVP */
}

void run_spawn(void (*fn)(void *), void *arg) {
    /* stub: just call directly, no green threads yet */
    fn(arg);
}

void run_yield(void) {
    /* stub: no-op for MVP */
}
