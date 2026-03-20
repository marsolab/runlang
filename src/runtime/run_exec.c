#include "run_exec.h"

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/* Convert run_string_t (ptr+len, not NUL-terminated) to a heap-allocated C string. */
static char *string_to_cstr(run_string_t s) {
    char *buf = malloc(s.len + 1);
    if (!buf) {
        return NULL;
    }
    if (s.len > 0) {
        memcpy(buf, s.ptr, s.len);
    }
    buf[s.len] = '\0';
    return buf;
}

/* ── Internal command struct ─────────────────────────────────────────────── */

struct run_exec_cmd {
    char *path;        /* NUL-terminated copy of program name/path */
    char **argv;       /* NULL-terminated argument vector */
    int argc;          /* number of args (excluding NULL sentinel) */
    int argv_cap;      /* allocated capacity of argv array */
    char *dir;         /* working directory, NULL = inherit */
    char **envp;       /* environment, NULL = inherit */
    int envc;          /* number of env entries */
    pid_t child_pid;   /* 0 = not started */
    int stdin_pipe[2]; /* [0]=read, [1]=write; -1 = not created */
    int stdout_pipe[2];
    int stderr_pipe[2];
    bool started;
    bool waited;
    int exit_status; /* raw waitpid status */
};

/* ── Public API ──────────────────────────────────────────────────────────── */

run_exec_cmd_t *run_exec_command(run_string_t name) {
    run_exec_cmd_t *cmd = calloc(1, sizeof(*cmd));
    if (!cmd)
        return NULL;

    cmd->path = string_to_cstr(name);
    if (!cmd->path) {
        free(cmd);
        return NULL;
    }

    /* argv[0] = program name, argv[1] = NULL sentinel */
    cmd->argv_cap = 8;
    cmd->argv = (char **)calloc((size_t)cmd->argv_cap, sizeof(char *));
    if (!cmd->argv) {
        free(cmd->path);
        free(cmd);
        return NULL;
    }
    cmd->argv[0] = cmd->path;
    cmd->argc = 1;

    cmd->stdin_pipe[0] = cmd->stdin_pipe[1] = -1;
    cmd->stdout_pipe[0] = cmd->stdout_pipe[1] = -1;
    cmd->stderr_pipe[0] = cmd->stderr_pipe[1] = -1;

    return cmd;
}

void run_exec_add_args(run_exec_cmd_t *cmd, run_string_t *args, size_t nargs) {
    if (!cmd || !args)
        return;
    for (size_t i = 0; i < nargs; i++) {
        /* Grow argv if needed (+1 for NULL sentinel) */
        if (cmd->argc + 1 >= cmd->argv_cap) {
            int new_cap = cmd->argv_cap * 2;
            char **new_argv = (char **)realloc((void *)cmd->argv, (size_t)new_cap * sizeof(char *));
            if (!new_argv)
                return;
            cmd->argv = new_argv;
            cmd->argv_cap = new_cap;
        }
        char *s = string_to_cstr(args[i]);
        if (!s)
            return; /* OOM: stop adding args rather than corrupt argv */
        cmd->argv[cmd->argc] = s;
        cmd->argc++;
        cmd->argv[cmd->argc] = NULL; /* maintain NULL sentinel */
    }
}

void run_exec_set_dir(run_exec_cmd_t *cmd, run_string_t dir) {
    if (!cmd)
        return;
    free(cmd->dir);
    cmd->dir = (dir.len > 0) ? string_to_cstr(dir) : NULL;
}

void run_exec_set_env(run_exec_cmd_t *cmd, run_string_t *env, size_t nenv) {
    if (!cmd)
        return;
    /* Free previous env */
    if (cmd->envp) {
        for (int i = 0; i < cmd->envc; i++)
            free(cmd->envp[i]);
        free((void *)cmd->envp);
    }
    if (nenv == 0 || !env) {
        cmd->envp = NULL;
        cmd->envc = 0;
        return;
    }
    cmd->envp = (char **)calloc(nenv + 1, sizeof(char *));
    if (!cmd->envp)
        return;
    for (size_t i = 0; i < nenv; i++) {
        cmd->envp[i] = string_to_cstr(env[i]);
    }
    cmd->envp[nenv] = NULL;
    cmd->envc = (int)nenv;
}

/* ── Internal: fork + exec ───────────────────────────────────────────────── */

static run_error_t do_start(run_exec_cmd_t *cmd) {
    if (!cmd)
        return RUN_ERR("exec: null command");
    if (cmd->started)
        return RUN_ERR("exec: already started");

    pid_t pid = fork();
    if (pid < 0) {
        return RUN_ERR("exec: fork failed");
    }

    if (pid == 0) {
        /* ── Child process ──────────────────────────────────────────── */

        /* Set up stdin pipe */
        if (cmd->stdin_pipe[0] != -1) {
            dup2(cmd->stdin_pipe[0], STDIN_FILENO);
            close(cmd->stdin_pipe[0]);
            close(cmd->stdin_pipe[1]);
        }
        /* Set up stdout pipe */
        if (cmd->stdout_pipe[1] != -1) {
            dup2(cmd->stdout_pipe[1], STDOUT_FILENO);
            close(cmd->stdout_pipe[0]);
            close(cmd->stdout_pipe[1]);
        }
        /* Set up stderr pipe */
        if (cmd->stderr_pipe[1] != -1) {
            dup2(cmd->stderr_pipe[1], STDERR_FILENO);
            /* Only close if stderr has its own pipe (not sharing with stdout) */
            if (cmd->stderr_pipe[1] != cmd->stdout_pipe[1]) {
                if (cmd->stderr_pipe[0] != -1)
                    close(cmd->stderr_pipe[0]);
                close(cmd->stderr_pipe[1]);
            }
        }

        /* Change directory if requested */
        if (cmd->dir) {
            if (chdir(cmd->dir) != 0) {
                _exit(127);
            }
        }

        /* Exec */
        if (cmd->envp) {
            execve(cmd->path, cmd->argv, cmd->envp);
        } else {
            execvp(cmd->path, cmd->argv);
        }
        /* execvp/execve only returns on error */
        _exit(127);
    }

    /* ── Parent process ─────────────────────────────────────────────── */
    cmd->child_pid = pid;
    cmd->started = true;

    /* Close child-side pipe ends in parent */
    if (cmd->stdin_pipe[0] != -1) {
        close(cmd->stdin_pipe[0]);
        cmd->stdin_pipe[0] = -1;
    }
    if (cmd->stdout_pipe[1] != -1) {
        close(cmd->stdout_pipe[1]);
        cmd->stdout_pipe[1] = -1;
    }
    if (cmd->stderr_pipe[1] != -1 && cmd->stderr_pipe[1] != cmd->stdout_pipe[1]) {
        close(cmd->stderr_pipe[1]);
    }
    cmd->stderr_pipe[1] = -1;

    return RUN_OK;
}

static run_error_t do_wait(run_exec_cmd_t *cmd) {
    if (!cmd)
        return RUN_ERR("exec: null command");
    if (!cmd->started)
        return RUN_ERR("exec: not started");
    if (cmd->waited)
        return RUN_ERR("exec: already waited");

    int status = 0;
    pid_t result;
    do {
        result = waitpid(cmd->child_pid, &status, 0);
    } while (result == -1 && errno == EINTR);

    if (result == -1) {
        return RUN_ERR("exec: waitpid failed");
    }

    cmd->exit_status = status;
    cmd->waited = true;

    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        return RUN_ERR("exec: non-zero exit");
    }
    if (WIFSIGNALED(status)) {
        return RUN_ERR("exec: killed by signal");
    }

    return RUN_OK;
}

/* ── Read all bytes from a file descriptor ───────────────────────────────── */

static run_slice_t read_all_fd(int fd) {
    run_slice_t result = run_slice_new(1, 4096);
    char buf[4096];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0)
            break;
        for (ssize_t i = 0; i < n; i++) {
            run_slice_append(&result, &buf[i]);
        }
    }
    return result;
}

/* ── Public: run / output / combined_output ──────────────────────────────── */

run_error_t run_exec_run(run_exec_cmd_t *cmd) {
    run_error_t err = do_start(cmd);
    if (err.is_error)
        return err;
    return do_wait(cmd);
}

run_slice_t run_exec_output(run_exec_cmd_t *cmd, run_error_t *err) {
    /* Create stdout pipe */
    if (pipe(cmd->stdout_pipe) != 0) {
        *err = RUN_ERR("exec: pipe failed");
        return run_slice_new(1, 0);
    }

    *err = do_start(cmd);
    if (err->is_error) {
        close(cmd->stdout_pipe[0]);
        close(cmd->stdout_pipe[1]);
        cmd->stdout_pipe[0] = cmd->stdout_pipe[1] = -1;
        return run_slice_new(1, 0);
    }

    /* Read all stdout from parent end of pipe */
    run_slice_t output = read_all_fd(cmd->stdout_pipe[0]);
    close(cmd->stdout_pipe[0]);
    cmd->stdout_pipe[0] = -1;

    *err = do_wait(cmd);
    return output;
}

run_slice_t run_exec_combined_output(run_exec_cmd_t *cmd, run_error_t *err) {
    /* Create stdout pipe; stderr will be redirected to same pipe in child */
    if (pipe(cmd->stdout_pipe) != 0) {
        *err = RUN_ERR("exec: pipe failed");
        return run_slice_new(1, 0);
    }
    /* Signal to do_start that stderr should use stdout's pipe */
    cmd->stderr_pipe[0] = -1;
    cmd->stderr_pipe[1] = cmd->stdout_pipe[1]; /* child will dup2 both */

    *err = do_start(cmd);
    if (err->is_error) {
        close(cmd->stdout_pipe[0]);
        close(cmd->stdout_pipe[1]);
        cmd->stdout_pipe[0] = cmd->stdout_pipe[1] = -1;
        cmd->stderr_pipe[1] = -1;
        return run_slice_new(1, 0);
    }

    run_slice_t output = read_all_fd(cmd->stdout_pipe[0]);
    close(cmd->stdout_pipe[0]);
    cmd->stdout_pipe[0] = -1;

    *err = do_wait(cmd);
    return output;
}

/* ── Public: start / wait ────────────────────────────────────────────────── */

run_error_t run_exec_start(run_exec_cmd_t *cmd) {
    return do_start(cmd);
}

run_error_t run_exec_wait(run_exec_cmd_t *cmd) {
    return do_wait(cmd);
}

/* ── Public: pipe accessors ──────────────────────────────────────────────── */

int64_t run_exec_stdin_pipe(run_exec_cmd_t *cmd, run_error_t *err) {
    if (pipe(cmd->stdin_pipe) != 0) {
        *err = RUN_ERR("exec: pipe failed");
        return -1;
    }
    *err = RUN_OK;
    return (int64_t)cmd->stdin_pipe[1]; /* write end for parent */
}

int64_t run_exec_stdout_pipe(run_exec_cmd_t *cmd, run_error_t *err) {
    if (pipe(cmd->stdout_pipe) != 0) {
        *err = RUN_ERR("exec: pipe failed");
        return -1;
    }
    *err = RUN_OK;
    return (int64_t)cmd->stdout_pipe[0]; /* read end for parent */
}

int64_t run_exec_stderr_pipe(run_exec_cmd_t *cmd, run_error_t *err) {
    if (pipe(cmd->stderr_pipe) != 0) {
        *err = RUN_ERR("exec: pipe failed");
        return -1;
    }
    *err = RUN_OK;
    return (int64_t)cmd->stderr_pipe[0]; /* read end for parent */
}

/* ── Public: process state ───────────────────────────────────────────────── */

run_exec_process_state_t run_exec_process_state(run_exec_cmd_t *cmd) {
    run_exec_process_state_t ps = {0};
    if (!cmd || !cmd->waited)
        return ps;

    ps.pid = (int64_t)cmd->child_pid;
    if (WIFEXITED(cmd->exit_status)) {
        ps.exit_code = WEXITSTATUS(cmd->exit_status);
        ps.success = (ps.exit_code == 0);
    } else if (WIFSIGNALED(cmd->exit_status)) {
        ps.exit_code = -1;
        ps.success = false;
    }
    return ps;
}

/* ── Public: look_path ───────────────────────────────────────────────────── */

run_string_t run_exec_look_path(run_string_t file, run_error_t *err) {
    char *name = string_to_cstr(file);
    if (!name) {
        *err = RUN_ERR("exec: out of memory");
        return (run_string_t){.ptr = NULL, .len = 0};
    }

    /* If the name contains a slash, check it directly */
    if (strchr(name, '/')) {
        if (access(name, X_OK) == 0) {
            *err = RUN_OK;
            return (run_string_t){.ptr = name, .len = strlen(name)};
        }
        free(name);
        *err = RUN_ERR("exec: not found");
        return (run_string_t){.ptr = NULL, .len = 0};
    }

    /* Search PATH */
    const char *path_env = getenv("PATH");
    if (!path_env) {
        free(name);
        *err = RUN_ERR("exec: PATH not set");
        return (run_string_t){.ptr = NULL, .len = 0};
    }

    char *path_copy = strdup(path_env);
    if (!path_copy) {
        free(name);
        *err = RUN_ERR("exec: out of memory");
        return (run_string_t){.ptr = NULL, .len = 0};
    }

    char *saveptr = NULL;
    char *dir = strtok_r(path_copy, ":", &saveptr);
    while (dir) {
        size_t dir_len = strlen(dir);
        size_t name_len = strlen(name);
        size_t full_len = dir_len + 1 + name_len;
        char *full_path = malloc(full_len + 1);
        if (full_path) {
            memcpy(full_path, dir, dir_len);
            full_path[dir_len] = '/';
            memcpy(full_path + dir_len + 1, name, name_len);
            full_path[full_len] = '\0';

            if (access(full_path, X_OK) == 0) {
                free(path_copy);
                free(name);
                *err = RUN_OK;
                return (run_string_t){.ptr = full_path, .len = full_len};
            }
            free(full_path);
        }
        dir = strtok_r(NULL, ":", &saveptr);
    }

    free(path_copy);
    free(name);
    *err = RUN_ERR("exec: not found");
    return (run_string_t){.ptr = NULL, .len = 0};
}

/* ── Public: free ────────────────────────────────────────────────────────── */

void run_exec_free(run_exec_cmd_t *cmd) {
    if (!cmd)
        return;

    /* argv[0] == cmd->path, don't double-free */
    for (int i = 1; i < cmd->argc; i++) {
        free(cmd->argv[i]);
    }
    free((void *)cmd->argv);
    free(cmd->path);
    free(cmd->dir);

    if (cmd->envp) {
        for (int i = 0; i < cmd->envc; i++)
            free(cmd->envp[i]);
        free((void *)cmd->envp);
    }

    /* Close any still-open pipe fds */
    if (cmd->stdin_pipe[0] != -1)
        close(cmd->stdin_pipe[0]);
    if (cmd->stdin_pipe[1] != -1)
        close(cmd->stdin_pipe[1]);
    if (cmd->stdout_pipe[0] != -1)
        close(cmd->stdout_pipe[0]);
    if (cmd->stdout_pipe[1] != -1)
        close(cmd->stdout_pipe[1]);
    if (cmd->stderr_pipe[0] != -1)
        close(cmd->stderr_pipe[0]);
    if (cmd->stderr_pipe[1] != -1)
        close(cmd->stderr_pipe[1]);

    free(cmd);
}
