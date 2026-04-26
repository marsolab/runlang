#include "../run_runtime.h"

#include <stdio.h>

static int spawned_task_ran = 0;

static void spawned_task(void *arg) {
    (void)arg;
    spawned_task_ran = 1;
    printf("hello from WASI runtime task\n");
}

void run_main__main(void) {
    printf("hello from WASI runtime main\n");
    run_spawn(spawned_task, NULL);
}

int run_wasi_smoke_task_ran(void) {
    return spawned_task_ran;
}
