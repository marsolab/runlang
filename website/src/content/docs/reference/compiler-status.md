---
title: "Compiler Status"
sidebar:
  order: 1
---

Run is in **active development**. The compiler can compile and run simple programs through C code generation.

## Pipeline Status

| Component | Status |
|---|---|
| Lexer | Complete |
| Parser | Complete |
| Naming conventions | Complete |
| Name resolution | Complete |
| Type checking | In progress |
| IR lowering | Complete |
| C code generation | Complete |
| Runtime library | MVP |
| Standard library | Not started |

## Compiler Architecture

The compiler is written in Zig 0.15 and follows a traditional pipeline:

```
Source (.run) → Lexer → Token stream → Parser → AST → Name Resolution → Type Check → IR → C codegen
```

### Source Files

| File | Purpose |
|---|---|
| `main.zig` | CLI entry point and command dispatch |
| `token.zig` | Token types (~90 variants) and keyword map |
| `lexer.zig` | Single-pass stateless scanner |
| `parser.zig` | Recursive descent parser with precedence climbing |
| `ast.zig` | Flat AST representation (node array + extra_data) |
| `naming.zig` | Naming convention enforcement |
| `resolve.zig` | Name resolution and scope analysis |
| `symbol.zig` | Symbol table types |
| `typecheck.zig` | Type checking pass |
| `types.zig` | Type representation |
| `diagnostics.zig` | Diagnostic reporting infrastructure |
| `lower.zig` | AST-to-IR lowering |
| `ir.zig` | Intermediate representation |
| `codegen_c.zig` | C code generation backend |
| `driver.zig` | Compilation pipeline orchestration |

## Getting Involved

This is a great time to contribute — the language design is taking shape, and there are significant pieces to build. Check the [GitHub Issues](https://github.com/marsolab/runlang/issues) for open tasks.
