---
title: "Package Manager Implementation Plan"
sidebar:
  order: 2
---

This plan breaks down [RFC #218: Package Manager Design](https://github.com/marsolab/runlang/issues/218) into implementation phases for the Run compiler and docs. The package manager uses `run.toml`, `run.lock`, semantic version tags, a local module cache, Minimum Version Selection, `run install` / `run i` for dependency installation, and `run pkg` for package maintenance commands.

## TLDR

1. Build the compiler-internal foundation first: TOML, semantic versions, checksums, `run.toml`, and `run.lock`.
2. Add GitHub tag discovery, archive download, fast manifest fetches, and local cache management behind testable interfaces.
3. Implement deterministic dependency resolution with MVS before exposing package manager commands.
4. Wire `run install`, its `run i` alias, and `run pkg` into the CLI after the manifest, lockfile, fetch, cache, and resolver layers are stable.
5. Integrate external imports into the compiler last: path classification, scope-aware checking, multi-module compilation, cross-package lowering, and C codegen.
6. Finish with vendor mode, offline builds, private repository authentication, monorepo sub-modules, docs, and end-to-end tests.

## Current Baseline

The compiler already has a single-file pipeline:

```text
Source (.run) -> Lexer -> Parser -> Naming -> Resolve -> TypeCheck -> Lower (IR) -> CodegenC -> zig cc
```

The package manager work should preserve that pipeline for single-file and stdlib-only projects while adding module-aware behavior around project setup, dependency resolution, and compilation.

Current constraints:

- `run init` already writes a basic `run.toml`, but the CLI does not yet expose `run install`, `run i`, or `run pkg`.
- Imports parse as `use "path"` and currently behave as simple package symbols.
- The driver compiles one primary source file and discovers nearby assembly files.
- Lowering and C codegen still assume most cross-package behavior is either local code or known runtime/stdlib builtins.

## Phase 1: Foundation

Related issues: [#293](https://github.com/marsolab/runlang/issues/293), [#294](https://github.com/marsolab/runlang/issues/294), [#295](https://github.com/marsolab/runlang/issues/295), [#296](https://github.com/marsolab/runlang/issues/296), [#297](https://github.com/marsolab/runlang/issues/297), [#298](https://github.com/marsolab/runlang/issues/298)

Add the data model and parsing modules used by every later phase.

- Add `src/toml.zig` for the compiler-internal TOML subset required by `run.toml` and `run.lock`.
- Add `src/semver.zig` for semantic version parsing, comparison, sorting, `v` tag prefix stripping, and constraint evaluation.
- Add `src/checksum.zig` for SHA-256 archive hashing and `sha256:<hex>` formatting.
- Add `src/modfile.zig` for manifest parsing, validation, serialization, dependency sections, and scope tracking.
- Add `src/lockfile.zig` for deterministic lockfile parsing and generation.
- Update project initialization so `run init` and `run pkg init` create a complete manifest template.
- Export the new modules from `src/root.zig` so `zig build test` discovers their tests.

Acceptance gates:

- Valid and invalid TOML fixtures are covered by unit tests.
- Semver constraints cover `^`, `~`, `=`, `>=`, `0.x`, pre-release, and build metadata cases.
- Manifest and lockfile round trips are deterministic.
- Missing required package fields and malformed dependency entries produce clear diagnostics.

## Phase 2: Fetching And Cache

Related issues: [#299](https://github.com/marsolab/runlang/issues/299), [#300](https://github.com/marsolab/runlang/issues/300), [#301](https://github.com/marsolab/runlang/issues/301), [#302](https://github.com/marsolab/runlang/issues/302)

Add the GitHub and local filesystem layer that resolution depends on.

- Add `src/modfetch.zig` for module path parsing, GitHub URL construction, tag discovery, archive downloads, and raw `run.toml` fetches.
- Add `src/modcache.zig` for the default `~/.run/mod` cache and `RUNMODCACHE` override.
- Store archives under `cache/<host>/<owner>/<repo>/`.
- Extract immutable source trees to versioned module directories.
- Cache fetched manifests separately so transitive resolution can avoid downloading full archives just to inspect dependencies.
- Make process execution and HTTP behavior injectable so unit tests do not depend on live GitHub access.

Acceptance gates:

- Tag discovery filters semver tags, strips `v`, ignores dereference suffixes, and sorts deterministically.
- Cache path construction is tested for regular modules and future sub-module paths.
- Archive checksum computation is recorded for lockfile generation.
- HTTP, Git, auth, missing tag, and missing manifest failures produce actionable errors.

## Phase 3: Dependency Resolution

Related issues: [#303](https://github.com/marsolab/runlang/issues/303), [#304](https://github.com/marsolab/runlang/issues/304), [#305](https://github.com/marsolab/runlang/issues/305)

Add MVS and lockfile generation before adding user-facing commands.

- Add `src/mvs.zig` for requirement graph construction and deterministic Minimum Version Selection.
- Resolve production dependencies first.
- Resolve `dev`, `test`, and `debug` dependency graphs independently with production dependencies as the floor.
- Detect hard major-version conflicts and show which dependency introduced each incompatible requirement.
- Generate `run.lock` from the resolved graph.
- Skip re-resolution when the manifest and lockfile are already consistent.
- Verify previously cached modules before trusting cache hits.

Acceptance gates:

- Unit tests cover simple chains, diamonds, shared transitive dependencies, major conflicts, pre-release versions, and fetch-order independence.
- Scoped dependency tests prove test/debug/dev dependencies do not unexpectedly upgrade production dependencies.
- Generated `run.lock` output is stable for identical inputs.

## Phase 4: CLI Commands

Related issues: [#306](https://github.com/marsolab/runlang/issues/306), [#307](https://github.com/marsolab/runlang/issues/307), [#308](https://github.com/marsolab/runlang/issues/308), [#309](https://github.com/marsolab/runlang/issues/309), [#310](https://github.com/marsolab/runlang/issues/310), [#311](https://github.com/marsolab/runlang/issues/311)

Expose the package manager once the core behavior is reliable.

- Add `src/pkg_cmd.zig` for `install`, `tidy`, `download`, `verify`, `graph`, and `vendor` handlers.
- Wire `run install`, `run i`, and `run pkg` subcommands through `src/main.zig`.
- Support `run install <module>[@version]`, `run i <module>[@version]`, `--test`, `--debug`, `--dev`, `-u <module>`, and `-u`.
- Implement atomic updates for `run.toml` and `run.lock`.
- Implement `run pkg tidy` by using the parser and AST import declarations instead of source-text matching.
- Implement `run pkg download` and `run pkg verify` from lockfile state.
- Implement `run pkg graph` with direct and transitive dependency output, version labels, scopes, and diamond dependencies.
- Add user documentation for manifests, locks, scopes, semver syntax, and package manager workflows.

Acceptance gates:

- `run --help` includes package manager commands.
- `run install` and `run i` fail cleanly when `run.toml` is missing and suggest `run pkg init`.
- `run pkg verify` exits non-zero on missing or mismatched cache entries.
- CLI tests cover valid usage, invalid arguments, and error messages.

## Phase 5: Compiler Integration

Related issues: [#312](https://github.com/marsolab/runlang/issues/312), [#313](https://github.com/marsolab/runlang/issues/313), [#314](https://github.com/marsolab/runlang/issues/314), [#315](https://github.com/marsolab/runlang/issues/315), [#316](https://github.com/marsolab/runlang/issues/316), [#317](https://github.com/marsolab/runlang/issues/317), [#318](https://github.com/marsolab/runlang/issues/318)

Make resolved dependencies usable by the compiler.

- Extend import resolution to classify stdlib, relative, and external import paths.
- Look up external modules in `run.toml` and `run.lock`.
- Resolve module source from `vendor/` or the local cache.
- Enforce dependency scopes based on file type and build mode.
- Add parser, AST, resolver, and formatter support for import aliases such as `use mux "github.com/user/router"`.
- Introduce a multi-unit compilation model in the driver: root package plus dependency packages.
- Namespace package-level symbols to avoid collisions.
- Compile dependency `.run` files in dependency order.
- Generalize lowering so external function calls and type references use resolved symbol metadata instead of hardcoded package behavior.
- Extend C codegen for cross-module forward declarations, shared type definitions, duplicate definition avoidance, and stable generated C ordering.
- Add an end-to-end test that creates a local git repository package, runs package-manager commands, builds a dependent project, and executes the result.

Acceptance gates:

- Unknown external modules produce an error that suggests `run install`.
- Scoped dependencies are rejected outside their allowed contexts.
- External package functions generate correct mangled names.
- Multi-package generated C compiles without duplicate symbols or missing declarations.
- E2E tests do not depend on live GitHub network availability.

## Phase 6: Polish

Related issues: [#319](https://github.com/marsolab/runlang/issues/319), [#320](https://github.com/marsolab/runlang/issues/320), [#321](https://github.com/marsolab/runlang/issues/321), [#322](https://github.com/marsolab/runlang/issues/322)

Finish production workflows after the core package manager and compiler integration work.

- Implement `run pkg vendor` and prefer `vendor/` over the global cache when present.
- Add offline build behavior that never performs network requests when all required modules are cached or vendored.
- Add private repository support through `GITHUB_TOKEN`, git credential helpers, and `RUNPRIVATE`.
- Add monorepo sub-module support using path-prefixed tags and subdirectory `run.toml` files.
- Document private repository auth, offline workflows, vendor mode, and monorepo publishing.

Acceptance gates:

- Builds work offline when dependencies are cached or vendored.
- Missing cached modules produce a clear `run pkg download` suggestion.
- Private repository auth failures explain how to configure credentials.
- Sub-module packages resolve, fetch, cache, and import correctly.

## Testing Strategy

- Keep parser, resolver, and compiler behavior covered by inline Zig `test` blocks.
- Keep package-manager modules covered by focused unit tests with fixture strings and temporary directories.
- Mock Git and HTTP in unit tests.
- Use local temporary git repositories for E2E package-manager tests.
- Run `zig build test` for compiler unit coverage.
- Run `zig build test-e2e` after compiler integration phases.
- Run website checks from `website/` when documentation or sidebar changes.

## PR Sequencing

Each PR should stay close to one phase or one issue dependency chain.

1. `src/toml.zig`, `src/semver.zig`, and `src/checksum.zig` can land independently.
2. `src/modfile.zig` should wait for TOML and semver.
3. `src/lockfile.zig` should wait for TOML and scope types from modfile.
4. Fetch and cache can proceed after semver and checksum.
5. MVS should wait for modfile and semver.
6. CLI commands should wait for manifest, lockfile, fetch, cache, and resolution.
7. Compiler integration should wait for package-manager core and should be split by import resolution, scope checks, multi-file compilation, lowering, and codegen.
8. Vendor/offline/private/monorepo behavior should land after the base external import path works.

## Done Criteria

The package manager design is complete when:

- All child issues linked from RFC #218 are implemented or explicitly superseded.
- `run.toml` and `run.lock` are deterministic and documented.
- `run install`, `run i`, `run pkg tidy`, `run pkg download`, `run pkg verify`, `run pkg graph`, and `run pkg vendor` work from the CLI.
- External imports compile through the existing pipeline.
- Scoped dependencies are enforced at compile time.
- Cached, vendored, and offline builds are reproducible.
- Private GitHub repositories and monorepo sub-modules have tested workflows.
- `zig build test`, `zig build test-e2e`, and relevant website checks pass.
