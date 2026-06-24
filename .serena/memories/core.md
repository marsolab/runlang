# Core

- Run compiler workspace. Main pipeline: `.run` source -> lexer -> parser -> naming -> resolve -> typecheck -> lower IR -> C codegen -> `zig cc`.
- Primary compiler code under `src/`; runtime C under `src/runtime/`; stdlib packages under `stdlib/`; e2e `.run` cases under `tests/e2e/cases/`; docs site under `website/`.
- Start task context from `CLAUDE.md` and `AGENTS.md`; keep them synchronized when contributor commands/process change.
- Long-term self-hosting tracked by GitHub issue #188: Zig compiler is stage0; Run compiler rewrite must eventually stage0->stage1->stage2 with stable output/fixpoint.
- Read `mem:tech_stack` for toolchain details, `mem:conventions` for local style, `mem:suggested_commands` for common commands, and `mem:task_completion` before final verification.