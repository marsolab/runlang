#ifndef RUN_ERROR_H
#define RUN_ERROR_H

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    bool is_error;
    const char *context;
} run_error_t;

#define RUN_OK ((run_error_t){.is_error = false, .context = NULL})
#define RUN_ERR(ctx) ((run_error_t){.is_error = true, .context = (ctx)})

#endif
