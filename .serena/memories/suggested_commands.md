# Suggested Commands

- `zig build` builds the compiler.
- `zig build test` runs Zig unit tests.
- `zig build test-e2e` runs end-to-end compiler cases.
- `zig build run -- <command> <file.run>` runs compiler commands: `check`, `run`, `build`, `fmt`, `tokens`, `ast`.
- `make test-runtime` runs the runtime C suite.
- Website: `cd website && bun run dev`; production: `cd website && bun run build`.
- Tree-sitter: `cd editors/tree-sitter-run && bun run test`.
- VS Code extension: `cd editors/vscode && bun run compile`.
- Prefer `rg` / `rg --files` for search.