# Repository Guidelines

## Canonical Docs
Start with `CLAUDE.md` for architecture, Zig 0.16 conventions, and current workflow rules. Keep shared instructions in `AGENTS.md` and `CLAUDE.md` synchronized in the same PR whenever commands, branch targets, or contributor process changes.

## Project Structure & Module Organization
`src/` holds compiler passes and CLI entrypoints such as `main.zig`, `driver.zig`, `formatter.zig`, and `lsp.zig`. `src/runtime/` contains the C runtime, with runtime tests in `src/runtime/tests/`. `stdlib/` stores standard library `.run` packages, `examples/` has sample programs, and `tests/` contains Zig debug/e2e runners plus fuzz corpus inputs. `website/` is the Astro/Starlight docs site, `editors/` contains VS Code and tree-sitter tooling, and `blog/helm/` deploys Strapi.

## Build, Test, and Development Commands
`zig build` builds the compiler. `zig build test` runs Zig unit tests, `zig build test-e2e` runs end-to-end compiler cases, and `make test-runtime` runs the runtime C suite. Use `zig build run -- <command> <file.run>` for compiler commands such as `check`, `run`, `fmt`, `tokens`, or `ast`. Website work stays in `website/`: `bun run dev` for local docs work and `bun run build` for a production build. Editor examples: `cd editors/tree-sitter-run && bun run test` and `cd editors/vscode && bun run compile`.

## Coding Style & Naming Conventions
Format Zig with `zig fmt`. Follow the Zig 0.16 patterns already used here: prefer `ArrayList.empty`, pass allocators per method call, and match existing module naming. Token tags use the `kw_` prefix; AST tags use `_stmt`, `_decl`, `_literal`, and `type_` for type-related nodes. Runtime C in `src/runtime/` should stay `clang-format` clean. Website code uses `oxfmt` and `oxlint`.

## Testing Guidelines
Keep tests close to the code they validate: inline Zig `test` blocks, runtime files named `src/runtime/tests/test_*.c`, e2e cases in `tests/e2e/cases/*.run`, and stdlib tests as `*_test.run`. Add or update the nearest matching test for every behavior change; there is no published coverage target. For Linux runtime work, `zig build test -Dsanitize=true` matches CI sanitizer coverage.

## Commit & Pull Request Guidelines
Use short imperative commit subjects like `Fix parser support...`, `Add ...`, or `Rename ...`. Keep each PR focused, target `main`, link the relevant issue when applicable, and summarize user-visible or compiler-visible behavior changes. Check open issues and milestones before larger work. Include screenshots only for website or editor UI changes.
