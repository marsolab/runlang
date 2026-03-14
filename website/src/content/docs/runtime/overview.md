---
title: "Runtime Overview"
sidebar:
  order: 0
---

Design documentation for the Run language runtime library (`librunrt`).

## Documents

| Document                        | Description                                                                                                      |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| [Architecture](architecture.md) | Runtime component diagram, initialization sequence, how generated C code interacts with the runtime              |
| [Memory](memory.md)             | Generational allocation, virtual memory abstraction, slab allocator, arena allocator, custom allocator interface |
| [Scheduler](scheduler.md)       | Green thread scheduler based on Go's GMP model — goroutine/machine/processor design                              |
| [Concurrency](concurrency.md)   | Channels (buffered and unbuffered), synchronization primitives, scheduler integration                            |
| [Platform](platform.md)         | Platform-specific details for Linux, macOS, and Windows — virtual memory, threads, signals, context switching    |

## Overview

The Run runtime provides:

- **Memory safety** via generational references — every heap allocation carries a generation counter that is incremented on free, and every dereference checks the generation matches
- **Green threads** — lightweight user-space threads (called "run routines") scheduled cooperatively across OS threads, inspired by Go's goroutine model
- **Channels** — typed communication channels for inter-thread messaging, integrated with the scheduler for efficient blocking/waking
- **Strings and slices** — built-in dynamic data structures with bounds checking

## Implementation Phases

**Phase 1 — Minimal Working Scheduler:**
Single-threaded cooperative scheduler with fixed-size stacks, context switching via platform assembly, and unbuffered channels.

**Phase 2 — Multi-threaded Scheduler:**
Multiple OS threads, work-stealing, syscall-aware scheduling, cooperative preemption at function prologues.

**Phase 3 — Production Hardening:**
Virtual-memory-backed slab allocator, arena allocator, stack growth, signal-based preemption, buffered channels, Windows support.
