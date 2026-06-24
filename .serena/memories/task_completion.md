# Task Completion

- For compiler changes, run the focused test first, then broaden based on risk: commonly `zig build test`, `zig build test-e2e`, and/or `zig build`.
- For runtime C changes, run `make test-runtime`; on Linux sanitizer parity is `zig build test -Dsanitize=true`.
- Format Zig with `zig fmt` on touched Zig files before final verification.
- Website changes need `cd website && bun run build`; editor changes need their package-specific bun command.
- Before claiming success, report the exact commands run and whether they exited cleanly; do not infer broad pass status from a narrow check.