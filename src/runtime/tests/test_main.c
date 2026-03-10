#include "test_framework.h"
#include "../run_scheduler.h"

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

int main(void) {
    printf("Run Runtime Test Suite\n");
    printf("======================\n");

    /* Initialize the scheduler (required for scheduler and channel tests) */
    run_scheduler_init();

    run_test_vmem();
    run_test_map();
    run_test_scheduler();
    run_test_chan();

    TEST_SUMMARY();
}
