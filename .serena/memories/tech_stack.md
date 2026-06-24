# Tech Stack

- Compiler implementation language: Zig, currently using Zig 0.16 conventions.
- Runtime: C in `src/runtime/`, built/tested through repo build/make targets and expected to stay clang-format clean.
- Backend emits C, then uses `zig cc` for native binary compilation.
- Docs site: Astro/Starlight/Tailwind/React in `website/`; use `bun`, not npm/yarn/pnpm.
- Editor tooling: VS Code extension and tree-sitter packages under `editors/`, also using bun where applicable.