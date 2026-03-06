#ifndef RUN_SCHEDULER_H
#define RUN_SCHEDULER_H

void run_scheduler_init(void);
void run_scheduler_run(void);
void run_spawn(void (*fn)(void *), void *arg);
void run_yield(void);

#endif
