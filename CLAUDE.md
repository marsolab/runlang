# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
zig build              # Compile the `run` binary
zig build test         # Run all unit tests (lexer + parser)
zig build run -- <command> <file.run>  # Run compiler commands
```

Compiler commands: `run`, `build`, `check`, `tokens` (dump lexer output), `ast` (dump parsed AST).

## Architecture

Run is a systems programming language compiler written in Zig 0.15. The compiler frontend pipeline:

```
Source (.run) → Lexer → Token stream → Parser → Ast (flat node array)
```

- **token.zig** — Token types (~90 variants) and compile-time keyword map
- **lexer.zig** — Stateless single-pass scanner. `Lexer.init(source)` then `.next()` for streaming or `.tokenize(allocator)` for batch
- **parser.zig** — Single-pass recursive descent with precedence climbing for expressions. Collects errors without stopping (no panic mode)
- **ast.zig** — Flat array design: `nodes: ArrayList(Node)` + `extra_data: ArrayList(NodeIndex)` for variable-length data. `null_node = 0` sentinel (node 0 is always `.root`)
- **main.zig** — CLI entry point dispatching to the 5 commands
- **root.zig** — Re-exports all modules; test entry point via `refAllDecls`

Tests are embedded `test` blocks in lexer.zig and parser.zig, discovered through root.zig.

## Zig 0.15 Conventions

These differ from older Zig versions and are critical to get right:

- **ArrayList**: Use `.empty` (not `.init(allocator)`). Pass allocator to each method: `.append(allocator, item)`, `.deinit(allocator)`
- **I/O**: `std.fs.File.stdout()` / `.stderr()` + `.deprecatedWriter()` (not `std.io.getStdErr()`)
- Allocator is threaded through as parameter, not stored in containers

## Naming Conventions

- `kw_` prefix for keyword tokens (`kw_fn`, `kw_pub`)
- `_stmt`, `_decl`, `_literal` suffixes for AST node tags by category
- `type_` prefix for type-related AST nodes

## Language Design (SPEC.md)

- Memory safety via generational references (no GC, no borrow checker)
- No generics by design
- `&T` (read/write pointer), `@T` (read-only pointer)
- `!T` error unions with `try` and `switch`
- Structs use `Name struct { }` syntax (name before keyword); interfaces with `implements` block inside struct
- Go-style methods: `fn (recv &Type) name(params) ret { body }` — receiver in parens between `fn` and method name
- Newlines are significant tokens

## Current Status

Lexer and parser are complete. No semantic analysis, type checking, or code generation yet.

## Project Management

Before starting any work, always:

1. **Check [GitHub Issues](https://github.com/marsolab/runlang/issues)** for open tasks, priorities, and current assignments
2. **Check [GitHub Milestones](https://github.com/marsolab/runlang/milestones)** to understand the current development phase and roadmap progression
3. **Reference the relevant issue number** in commit messages and PR descriptions (e.g., `Fixes #24`)
4. **Each issue should be addressed in a single, focused PR** — avoid combining unrelated changes

### Development Roadmap (Milestones)

The milestones are ordered by dependency — each builds on the previous:

1. **M1: Type System** — Full type checking (primitives, functions, structs, interfaces, error unions, sum types, inference)
2. **M2: Memory & Safety** — Generational references, ownership, deterministic destruction, pointer semantics
3. **M3: Runtime & Concurrency** — Green thread scheduler, channels, map runtime, runtime test suite
4. **M4: Standard Library Core** — fmt, io, os, strings, testing, math packages
5. **M5: Tooling & Developer Experience** — Error messages, formatter, test runner, LSP, project scaffolding
6. **M6: Optimization & Hardening** — DCE, constant folding, E2E tests, fuzzing, benchmarks

### Labels

Component labels for categorizing issues: `type-system`, `runtime`, `stdlib`, `tooling`, `compiler`, `concurrency`, `memory`, `testing`
