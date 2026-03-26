# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
zig build              # Compile the `run` binary
zig build test         # Run all unit tests (lexer + parser)
zig build test-e2e     # Run end-to-end tests
zig build run -- <command> <file.run>  # Run compiler commands
```

Compiler commands: `run`, `build`, `check`, `tokens` (dump lexer output), `ast` (dump parsed AST).

## Architecture

Run is a systems programming language compiler written in Zig 0.15. The full compilation pipeline:

```
Source (.run) → Lexer → Parser → Naming → Resolve → TypeCheck → Lower (IR) → CodegenC → zig cc
```

**Frontend:**
- **token.zig** — Token types (~90 variants) and compile-time keyword map
- **lexer.zig** — Stateless single-pass scanner. `Lexer.init(source)` then `.next()` for streaming or `.tokenize(allocator)` for batch
- **parser.zig** — Single-pass recursive descent with precedence climbing for expressions. Collects errors without stopping (no panic mode)
- **ast.zig** — Flat array design: `nodes: ArrayList(Node)` + `extra_data: ArrayList(NodeIndex)` for variable-length data. `null_node = 0` sentinel (node 0 is always `.root`)

**Semantic analysis:**
- **naming.zig** — Naming convention checker
- **resolve.zig** — Name resolution and scope analysis
- **symbol.zig** — Symbol table with scope stack
- **typecheck.zig** — Type checking pass (stub — needs real type inference)
- **types.zig** — Type system definitions
- **diagnostics.zig** — Structured error reporting

**Backend:**
- **ir.zig** — Three-address code IR. Uses `local_set`/`local_get` for variables, `CallInfo` for named calls
- **lower.zig** — AST→IR lowering
- **codegen_c.zig** — IR→C code generation. Function name mangling: `run_main__<name>`, built-in mapping: `fmt.println` → `run_fmt_println`
- **driver.zig** — Compilation pipeline orchestration (invokes `zig cc`)

**Tooling:**
- **formatter.zig** — Code formatter
- **lsp.zig** — Language server protocol implementation
- **dap.zig** / **debug_engine.zig** / **gdb_mi.zig** — Debug adapter protocol
- **test_runner.zig** — Test runner
- **init.zig** — Project scaffolding

**Optimization:**
- **const_fold.zig** — Constant folding
- **dce.zig** — Dead code elimination
- **ownership.zig** — Ownership analysis

**Other:**
- **main.zig** — CLI entry point dispatching commands
- **root.zig** — Re-exports all modules; test entry point via `refAllDecls`
- **runtime/** — C runtime library (librunrt.a): allocator, strings, slices, fmt, green thread scheduler, channels

Tests are embedded `test` blocks in source files, discovered through root.zig.

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
- `!T` error unions with `try` and `switch`; bare `!` for failable functions with no return value
- Structs use `type Name struct { }` syntax (name before keyword); interfaces with `implements` block inside struct
- Go-style methods: `fun (recv &Type) name(params) ret { body }` — receiver in parens between `fun` and method name
- Newlines are significant tokens

## Current Status

Full pipeline working: Source → Lex → Parse → Naming → Resolve → TypeCheck → Lower → CodegenC → zig cc. Functions, let/var, assignments, if/else, for loops, literals, binary/unary ops, and calls all compile and run. Type checking is a stub (needs real type inference). Missing in lower.zig: for-in, switch, structs, defer, closures, channels, error handling.

## Self-Improvement

When you make a mistake or encounter an error during work, document it so future sessions can avoid the same pitfall.

1. **Before starting work**, read all files in `.agents/memory/mistakes/` to learn from past mistakes
2. **When a mistake happens** (build error you caused, wrong API usage, misunderstanding of codebase conventions, etc.), create a file:

   ```
   .agents/memory/mistakes/YYYY-MM-DD_short-name.md
   ```

   The file must contain:
   - **What went wrong** — describe the mistake clearly
   - **Why it happened** — root cause (wrong assumption, outdated knowledge, etc.)
   - **How to avoid it** — the correct approach for next time

3. Keep filenames descriptive (e.g., `2026-03-21_arraylist-init-api.md`, `2026-03-21_wrong-stdout-writer.md`)

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
7. **M7: Universal Assembly Language** — Portable assembly syntax, inline asm blocks, platform-specific asm files, assembler integration with C codegen
8. **M8: Native SIMD** — First-class vector types (`v4f32`, `v8i32`, etc.), SIMD operations, auto-vectorization hints, platform-specific intrinsic mapping
9. **M9: NUMA-Aware Runtime** — Topology discovery, NUMA-aware allocators, thread/green-thread affinity, memory placement policies
10. **M10: Stdlib Foundation** — Core stdlib packages (fmt, io, os, strings, bytes, unicode)
11. **M11: Stdlib Utilities** — Utility stdlib packages (math, sort, hash, encoding, compress, crypto)
12. **M12: Stdlib Application** — Application-level stdlib packages (net, http, json, testing, log, time)
13. **M13: Stdlib Specialized** — Specialized stdlib packages (reflect, debug, plugin, unsafe)
14. **M14: Package Manager Core** — TOML manifest, semver resolution, GitHub fetching, local cache, MVS dependency resolution, `run get`/`run mod` CLI commands
15. **M15: Package Manager Integration** — External import resolution, scope-aware dependency checking, multi-module compilation, vendor mode, offline builds, private repo auth

M7 is the foundation (assembly provides the low-level escape hatch). M8 and M9 can proceed in parallel after M7. M10-M13 expand the stdlib from M4's core (see RFC #219). M14 depends on M5 (Tooling). M15 depends on M14. See RFC #218 for the full package manager design.

### Long-term Goal: Self-Hosted Compiler (#188)

Once the compiler and language are stable enough (post-M6 at minimum), the compiler will be rewritten in Run itself. The current Zig implementation becomes the bootstrap compiler (stage 0), the Run rewrite becomes stage 1, and self-hosting is proven when stage 1 can compile itself (stage 2) with matching output.

### Labels

Component labels for categorizing issues: `type-system`, `runtime`, `stdlib`, `tooling`, `compiler`, `concurrency`, `memory`, `testing`, `assembly`, `simd`, `numa`, `package-manager`

## Website

The `website/` directory contains the landing page and documentation site built with Astro + Starlight + Tailwind CSS v4 + React.

### Package Manager

**Always use `bun`** (not npm/yarn/pnpm) for all JavaScript/TypeScript projects in this repository.

```bash
cd website
bun install            # Install dependencies
bun run dev            # Dev server at localhost:4321
bun run build          # Production build to website/dist/
bun run preview        # Preview production build
```

### Deployment

The website deploys to **Cloudflare Pages** automatically on push to `main`. Configuration is in `website/wrangler.jsonc`.

## Blog (Strapi CMS)

The `blog/` directory contains a Helm chart for deploying the Strapi CMS (`blog/helm/`). Chart name: `runlang-strapi`. Deployed to Kubernetes via `.github/workflows/deploy-blog.yml` on pushes to `main` that change `blog/` files. Strapi secrets are passed from GitHub repo secrets via `--set` flags. PostgreSQL runs as a subchart dependency (Bitnami).
