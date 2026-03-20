#ifndef RUN_EXEC_H
#define RUN_EXEC_H

#include "run_error.h"
#include "run_slice.h"
#include "run_string.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Opaque handle to a command being prepared or run. */
typedef struct run_exec_cmd run_exec_cmd_t;

/* Process state returned after a command completes. */
typedef struct {
    int64_t pid;
    int64_t exit_code;
    bool success;
} run_exec_process_state_t;

/* Create a command handle for the named program. */
run_exec_cmd_t *run_exec_command(run_string_t name);

/* Set the working directory for the command. */
void run_exec_set_dir(run_exec_cmd_t *cmd, run_string_t dir);

/* Set environment variables (slice of "KEY=VALUE" run_string_t). */
void run_exec_set_env(run_exec_cmd_t *cmd, run_string_t *env, size_t nenv);

/* Add arguments to the command. */
void run_exec_add_args(run_exec_cmd_t *cmd, run_string_t *args, size_t nargs);

/* Start the command and wait for it to complete. */
run_error_t run_exec_run(run_exec_cmd_t *cmd);

/* Run and capture stdout. On error, *err is set. */
run_slice_t run_exec_output(run_exec_cmd_t *cmd, run_error_t *err);

/* Run and capture stdout+stderr combined. On error, *err is set. */
run_slice_t run_exec_combined_output(run_exec_cmd_t *cmd, run_error_t *err);

/* Start the command without waiting. */
run_error_t run_exec_start(run_exec_cmd_t *cmd);

/* Wait for a started command to exit. */
run_error_t run_exec_wait(run_exec_cmd_t *cmd);

/* Create a pipe connected to the command's stdin. Returns write-end fd. */
int64_t run_exec_stdin_pipe(run_exec_cmd_t *cmd, run_error_t *err);

/* Create a pipe connected to the command's stdout. Returns read-end fd. */
int64_t run_exec_stdout_pipe(run_exec_cmd_t *cmd, run_error_t *err);

/* Create a pipe connected to the command's stderr. Returns read-end fd. */
int64_t run_exec_stderr_pipe(run_exec_cmd_t *cmd, run_error_t *err);

/* Get the process state after wait() completes. */
run_exec_process_state_t run_exec_process_state(run_exec_cmd_t *cmd);

/* Search PATH for an executable. On error, *err is set. */
run_string_t run_exec_look_path(run_string_t file, run_error_t *err);

/* Free all resources associated with a command handle. */
void run_exec_free(run_exec_cmd_t *cmd);

#endif
