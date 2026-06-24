# Conventions

- Zig 0.16 `ArrayList`: use `.empty`, pass allocator to methods (`append(allocator, item)`, `deinit(allocator)`).
- Zig stdio: use `std.fs.File.stdout()` / `.stderr()` with `.deprecatedWriter()`.
- Token tags use `kw_` prefix. AST tags use `_stmt`, `_decl`, `_literal`, and `type_` for type-related nodes.
- Add or update the nearest behavior test for compiler/runtime changes: inline Zig tests, e2e `.run` cases, runtime `src/runtime/tests/test_*.c`, stdlib `*_test.run`.
- Preserve unrelated dirty work; current sessions may have generated local metadata like `.serena/project.yml`.