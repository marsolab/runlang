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
- Structs declared separately from methods (Go-style); traits with explicit `impl Trait for Type`
- Newlines are significant tokens

## Current Status

Lexer and parser are complete. No semantic analysis, type checking, or code generation yet.
