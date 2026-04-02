---
title: "Compiler Status"
sidebar:
  order: 1
---

Run is in **active development**. The compiler can compile and run simple programs through C code generation.

## Pipeline Status

| Component          | Status      |
| ------------------ | ----------- |
| Lexer              | Complete    |
| Parser             | Complete    |
| Naming conventions | Complete    |
| Name resolution    | Complete    |
| Type checking      | In progress |
| IR lowering        | Complete    |
| C code generation  | Complete    |
| Runtime library    | MVP         |
| Standard library   | Not started |

## Compiler Architecture

The compiler is written in Zig 0.15 and follows a traditional pipeline:

```
Source (.run) → Lexer → Token stream → Parser → AST → Name Resolution → Type Check → IR → C codegen
```

### Source Files

| File              | Purpose                                           |
| ----------------- | ------------------------------------------------- |
| `main.zig`        | CLI entry point and command dispatch              |
| `token.zig`       | Token types (~90 variants), keyword map, display names |
| `lexer.zig`       | Single-pass stateless scanner                     |
| `parser.zig`      | Recursive descent parser with precedence climbing |
| `ast.zig`         | Flat AST representation (node array + extra_data) |
| `naming.zig`      | Naming convention enforcement                     |
| `resolve.zig`     | Name resolution and scope analysis                |
| `symbol.zig`      | Symbol table types                                |
| `typecheck.zig`   | Type checking pass                                |
| `types.zig`       | Type representation                               |
| `diagnostics.zig` | Rust-style diagnostic reporting with annotations  |
| `lower.zig`       | AST-to-IR lowering                                |
| `ir.zig`          | Intermediate representation                       |
| `codegen_c.zig`   | C code generation backend                         |
| `driver.zig`      | Compilation pipeline orchestration                |

## Diagnostics

The compiler produces Rust-style error messages with source context, caret annotations, and contextual help. All compilation phases (lexer, parser, naming, name resolution, type checking, ownership, constant folding) use a unified diagnostic system.

Features:
- **Source context** — errors show the relevant source line with carets under the error span
- **Labels** — concise caret-line labels distinct from the full error message
- **Annotations** — chained notes, help, and hint messages after the primary error
- **"Did you mean?"** — fuzzy matching suggests corrections for undefined references and struct fields
- **"First defined here"** — duplicate definitions and immutable reassignment show the original declaration
- **Fix suggestions** — naming violations suggest the corrected name; immutable reassignment suggests `var`
- **Keyword migration** — users from Go (`func`), JavaScript (`function`), Python (`def`), or C++ (`const`) get targeted help
- **Semicolon detection** — stray semicolons produce a clear error explaining Run uses newlines
- **Error count summary** — compilation ends with "aborting due to N previous errors"
- **Color support** — ANSI colors in terminal output, disabled with `--no-color`

Example output:

```
error: cannot assign to immutable variable 'x'
 --> main.run:5:5
  |
5 |     x = 10
  |     ^ cannot assign here
  |
  = note: defined as immutable here
 --> main.run:3:5
  |
3 |     let x = 42
  |     --- defined as immutable here
  |
  = help: consider using 'var' instead of 'let' if you need to reassign
error: aborting due to 1 previous error
```

## Getting Involved

This is a great time to contribute — the language design is taking shape, and there are significant pieces to build. Check the [GitHub Issues](https://github.com/marsolab/runlang/issues) for open tasks.
