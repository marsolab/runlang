# Standard Library Implementation Design

## Decision: Stdlib Written in Run

The standard library is written in Run itself, not in Zig or C. This is the standard approach for self-hosting languages (Go's stdlib is Go, Rust's is Rust) and serves as the primary dogfooding vehicle for the language.

## Architecture: Three Layers

```
┌─────────────────────────────────────────┐
│  Layer 3: Standard Library (Run)        │
│  fmt, io, os, strings, testing, ...     │
│  Written in .run files, testable,       │
│  user-readable, contributable           │
├─────────────────────────────────────────┤
│  Layer 2: Compiler Builtins (bridge)    │
│  @syscall, @alloc, @chanSend, ...       │
│  Thin intrinsics the compiler lowers    │
│  to C runtime calls                     │
├─────────────────────────────────────────┤
│  Layer 1: C Runtime (librunrt.a)        │
│  Allocator, scheduler, channels,        │
│  context switch (asm), virtual memory   │
│  Minimal, non-replaceable foundation    │
└─────────────────────────────────────────┘
```

### Layer 1 — C Runtime (`src/runtime/`)

Already implemented. Provides the primitives that **cannot** be expressed in Run because they implement the language's own safety and concurrency model:

| Component | File(s) | Why C/ASM |
|-----------|---------|-----------|
| Generational allocator | `run_alloc.c/h` | Implements the memory safety model itself |
| Green thread scheduler | `run_scheduler.c/h` | OS thread management, GMP model |
| Context switching | `run_context_amd64.S`, `run_context_arm64.S` | CPU register manipulation |
| Channels | `run_chan.c/h` | Tightly coupled to scheduler internals |
| Virtual memory | `run_vmem.c/h` | Raw `mmap`/`VirtualAlloc` wrappers |
| Hash maps | `run_map.c/h` | Runtime backing for `map[K]V` type |
| Strings | `run_string.c/h` | Runtime backing for `string` type |
| Slices | `run_slice.c/h` | Runtime backing for `[]T` type |
| Formatting | `run_fmt.c/h` | Primitive type printing (bootstrap) |

This layer is small and should stabilize early. Users never interact with it directly.

### Layer 2 — Compiler Builtins

A small, fixed set of intrinsics that the compiler recognizes and lowers to C runtime calls during code generation. These are the **only** bridge between Run code and the C runtime:

```run
// These are compiler-known, not user-definable
@syscall.open(path, flags, mode)   // → run_syscall_open()
@syscall.read(fd, buf, len)        // → run_syscall_read()
@syscall.write(fd, buf, len)       // → run_syscall_write()
@syscall.close(fd)                 // → run_syscall_close()
@alloc(T)                          // → run_alloc(sizeof(T))
@free(ptr)                         // → run_free(ptr)
@chanSend(ch, val)                 // → run_chan_send()
@chanRecv(ch)                      // → run_chan_recv()
```

The set of builtins grows conservatively. If something can be built in Run using existing builtins, it should be.

### Layer 3 — Standard Library (Run)

All user-facing packages, written in `.run` files:

```
stdlib/
  fmt/
    fmt.run           # String formatting and printing
    fmt_test.run      # Tests
  io/
    io.run            # Reader/Writer interfaces, buffered I/O
    io_test.run
  os/
    os.run            # File system, processes, environment
    os_test.run
  strings/
    strings.run       # String manipulation
    strings_test.run
  bytes/
    bytes.run         # Byte slice utilities
    bytes_test.run
  math/
    math.run          # Mathematical functions and constants
    math_test.run
  testing/
    testing.run       # Test framework
    testing_test.run
  time/
    time.run          # Time, duration, timers
    time_test.run
  log/
    log.run           # Structured logging
    log_test.run
  net/
    net.run           # TCP/UDP sockets, DNS
    net_test.run
  http/
    http.run          # HTTP server and client
    http_test.run
  json/
    json.run          # JSON encoding/decoding
    json_test.run
  crypto/
    crypto.run        # Hashing, encryption
    crypto_test.run
  sync/
    sync.run          # Mutexes, atomics, wait groups
    sync_test.run
  unsafe/
    unsafe.run        # Raw pointers, type layout
    unsafe_test.run
```

## Example: How Layers Connect

```run
// stdlib/os/os.run
package os

use "io"

// Error type for file operations
type FileError = .notFound
    | .permissionDenied
    | .alreadyExists
    | .isDirectory
    | .notDirectory
    | .diskFull

pub File struct {
    implements {
        io.Reader
        io.Writer
        io.Closer
    }

    fd   int
    path string
}

// Open opens a file for reading.
pub fun open(path string) !File {
    fd := try @syscall.open(path, O_RDONLY, 0)
    return File{ fd: fd, path: path }
}

// Read reads up to len(buf) bytes into buf.
pub fun (f &File) read(buf []byte) !int {
    return try @syscall.read(f.fd, buf, len(buf))
}

// Write writes buf to the file.
pub fun (f &File) write(buf []byte) !int {
    return try @syscall.write(f.fd, buf, len(buf))
}

// Close closes the file.
pub fun (f &File) close() !void {
    try @syscall.close(f.fd)
}
```

```run
// User code using the stdlib
package main

use "os"
use "fmt"

pub fun main() {
    file := try os.open("hello.txt") :: "opening file"
    defer file.close()

    buf := make([]byte, 1024)
    n := try file.read(buf) :: "reading file"
    fmt.println(string(buf[:n]))
}
```

## Why Run-in-Run

1. **Dogfooding** — The stdlib becomes the largest Run codebase, surfacing language design issues and compiler bugs early
2. **Single language** — Contributors read one language. Go's stdlib is Go, Rust's is Rust
3. **Proves the language** — If `fmt` or `http` can't be written comfortably in Run, the language needs fixing
4. **Simpler toolchain** — Users don't need a C compiler to read or extend the stdlib
5. **Testable** — Stdlib tests use the same `testing` package and `_test.run` convention as user code

## What Stays in C (and Why)

The boundary is simple: **if it implements a language primitive, it's C. If it uses language primitives, it's Run.**

- The allocator is C because it *is* the memory model
- The scheduler is C because it *is* the concurrency model
- `fmt.println` is Run because it *uses* strings and I/O
- `os.open` is Run because it *uses* a syscall builtin
- `http.listenAndServe` is Run because it *uses* `os`, `io`, and `net`

## Implementation Priority

Matches the stdlib-designer agent priorities and M4 milestone:

| Priority | Packages | Notes |
|----------|----------|-------|
| **P0** | `fmt`, `io`, `os` | Exercise builtins, error unions, interfaces |
| **P1** | `strings`, `bytes`, `math`, `testing`, `time`, `log` | Mostly pure Run, minimal builtins needed |
| **P2** | `net`, `http`, `json`, `crypto`, `sync`, `unsafe` | Build on P0/P1 foundations |

## Prerequisites

Before stdlib implementation can begin, these compiler capabilities must work end-to-end:

- [x] Lexer and parser (complete)
- [x] C runtime (librunrt.a MVP complete)
- [ ] Type checking for structs, interfaces, error unions, sum types
- [ ] `use` import system resolving stdlib paths
- [ ] Code generation for method calls, interface dispatch
- [ ] `defer` codegen
- [ ] Error union propagation (`try`, `::` context)

These are tracked in milestones M1-M3.
