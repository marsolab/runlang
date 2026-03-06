# Contributing to Run

Thanks for your interest in contributing to Run! This document covers how to get set up and submit changes.

## Development Setup

1. Install [Zig 0.15](https://ziglang.org/download/) or later
2. Clone the repository:
   ```bash
   git clone https://github.com/marsolab/runlang.git
   cd runlang
   ```
3. Build the compiler:
   ```bash
   zig build
   ```
4. Run the tests:
   ```bash
   zig build test
   ```

## Making Changes

1. Fork the repository and create a branch from `master`
2. Make your changes
3. Add tests for new functionality (test blocks in the relevant `.zig` file)
4. Run `zig build test` and make sure all tests pass
5. Run `zig build` to verify the project compiles cleanly

## Code Style

- Follow Zig's standard naming conventions
- Use `kw_` prefix for keyword tokens
- Use `_stmt`, `_decl`, `_literal` suffixes for AST node tags
- Use `type_` prefix for type-related AST nodes
- Use `ArrayList.empty` (not `.init(allocator)`) — Zig 0.15 convention
- Pass the allocator to each method call rather than storing it in containers

## Submitting a Pull Request

1. Push your branch to your fork
2. Open a pull request against `master`
3. Describe what your change does and why
4. Link any related issues

Keep pull requests focused on a single change. If you have multiple independent improvements, submit them as separate PRs.

## Reporting Issues

Open an issue on GitHub with:
- A clear description of the problem or suggestion
- Steps to reproduce (for bugs)
- Expected vs actual behavior
- Zig version and platform

## Project Architecture

See the [README](README.md) for an overview of the compiler pipeline and project structure. The [Language Specification](SPEC.md) covers the language design.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
