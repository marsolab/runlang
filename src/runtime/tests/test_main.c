#include "../run_scheduler.h"
#include "test_framework.h"

/* Test framework globals */
int _test_total = 0;
int _test_passed = 0;
int _test_failed = 0;
const char *_test_current = NULL;

/* Test suite declarations */
extern void run_test_vmem(void);
extern void run_test_scheduler(void);
extern void run_test_chan(void);
extern void run_test_map(void);
extern void run_test_fmt(void);
extern void run_test_simd(void);
extern void run_test_numa(void);
extern void run_test_runtime_api(void);
extern void run_test_debug_api(void);
extern void run_test_poller(void);
extern void run_test_stress(void);

int main(void) {
    printf("Run Runtime Test Suite\n");
    printf("======================\n");

    /* Default to single-processor mode for deterministic testing, but allow
     * targeted scheduler tests to opt into multi-P via the environment. */
    if (getenv("RUN_MAXPROCS") == NULL) {
        setenv("RUN_MAXPROCS", "1", 1);
    }

    /* Initialize the scheduler (required for scheduler and channel tests) */
    run_scheduler_init();

    run_test_vmem();
    run_test_map();
    run_test_fmt();
    run_test_simd();
    run_test_numa();
    run_test_runtime_api();
    run_test_debug_api();
    run_test_scheduler();
    run_test_chan();
    run_test_poller();
    run_test_stress();

    TEST_SUMMARY();
}
