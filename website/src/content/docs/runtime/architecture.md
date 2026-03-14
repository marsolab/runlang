---
title: "Runtime Architecture"
sidebar:
  order: 1
---


## Component Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                    Compiled Run Program                       │
│                  (generated C code + main)                    │
├──────────────────────────────────────────────────────────────┤
│                       librunrt.a                              │
│                                                              │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  alloc   │  │ string  │  │  slice   │  │     fmt      │  │
│  │ (gen ref)│  │ (ptr+   │  │ (dynamic │  │  (printing)  │  │
│  │          │  │  len)   │  │  array)  │  │              │  │
│  └────┬─────┘  └────┬────┘  └────┬─────┘  └──────────────┘  │
│       │             │            │                            │
│  ┌────┴─────────────┴────────────┴─────────────────────────┐ │
│  │                    Scheduler (GMP)                       │ │
│  │  ┌───┐ ┌───┐ ┌───┐    ┌───┐ ┌───┐    ┌───────────┐    │ │
│  │  │ G │ │ G │ │ G │    │ P │ │ P │    │  Channels  │    │ │
│  │  └───┘ └───┘ └───┘    └─┬─┘ └─┬─┘    └───────────┘    │ │
│  │                          │     │                        │ │
│  │                        ┌─┴─┐ ┌─┴─┐                     │ │
│  │                        │ M │ │ M │  (OS threads)        │ │
│  │                        └───┘ └───┘                      │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Platform Abstraction (vmem)                 │ │
│  │         mmap/VirtualAlloc, pthreads/CreateThread         │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

## Compilation and Linking

The Run compiler pipeline produces a C source file that includes `run_runtime.h`:

```
Source (.run) → Lexer → Parser → AST → Resolve → TypeCheck → Lower → IR → C Codegen
                                                                              │
                                                                    generated .c file
                                                                              │
                                                              cc -o binary generated.c -lrunrt
```

The generated C code:
- `#include "run_runtime.h"` for access to all runtime APIs
- Defines `void run_main__main(void)` as the user's entry point
- Calls `run_gen_alloc`/`run_gen_free`/`run_gen_check` for heap memory
- Calls `run_string_*` for string operations
- Calls `run_slice_*` for slice operations
- Calls `run_spawn` to launch green threads
- Calls `run_chan_*` for channel operations

## Initialization Sequence

The program entry point is `main()` in `run_main.c`:

```c
int main(void) {
    run_scheduler_init();    // 1. Initialize scheduler (create Ps, set up main M)
    run_main__main();        // 2. Run user's main function
    run_scheduler_run();     // 3. Run scheduler loop until all Gs complete
    return 0;
}
```

### Step 1: `run_scheduler_init()`

Future behavior (when scheduler is implemented):
1. Query CPU count via `sysconf(_SC_NPROCESSORS_ONLN)` (or `GetSystemInfo` on Windows)
2. Read `RUN_MAXPROCS` environment variable (defaults to CPU count)
3. Allocate P structs (one per logical processor)
4. Create the main M (wrapping the main OS thread)
5. Bind the main M to P[0]
6. Initialize the global run queue

### Step 2: `run_main__main()`

The user's main function runs directly on the main M/P. Any `run` statements in user code call `run_spawn()` which creates new Gs and adds them to run queues.

### Step 3: `run_scheduler_run()`

Future behavior:
1. Enter scheduling loop on the main M
2. Pick runnable Gs from local/global queues
3. Context-switch to each G, run until it yields or blocks
4. When all Gs are dead and all queues empty, return
5. Main returns 0

## Shutdown Sequence

1. `run_scheduler_run()` returns when no runnable Gs remain
2. All M threads are joined or detached
3. P structs and remaining resources are freed
4. `main()` returns 0

## Current State

The runtime currently operates in a simplified mode:
- `run_scheduler_init()` is a no-op
- `run_spawn()` calls the function directly (synchronous execution, no green threads)
- `run_scheduler_run()` is a no-op
- All channel operations abort with an error message
