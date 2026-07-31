---
title: "Self-Hosting Plan"
sidebar:
  order: 3
---

This plan turns [#188: Goal: Self-hosted compiler](https://github.com/marsolab/runlang/issues/188)
from an aspiration into a sequenced engineering programme. It defines the **bootstrap
subset** (the frozen slice of Run that stage 1 is allowed to use), the **fixpoint
criterion** (what "the compiler compiles itself" is allowed to mean), and the order in
which the prerequisites must land.

## TLDR

1. The Run language cannot currently express a lexer. `s[0]` and `a[i..j]` have no
   lowering, so scanning source text is impossible. This, not the package manager, is
   what blocks #188.
2. There is no multi-file compilation of any kind — not across packages, and not between
   two files of the same package. The driver reads exactly one file.
3. Returning an allocated slice from a function is a use-after-free at runtime. That is
   the shape of every compiler pass.
4. The 32k-line standard library has never been compiled, because nothing can import it.
5. None of the 30 open package-manager issues (M14/M15) are prerequisites. Six of them
   need re-scoping from *external packages* to *local packages plus stdlib*; the other 24
   should be deferred.
6. Realistic scope: roughly 8–14 months of prerequisite compiler work before stage 1 is
   startable, then 6–12 months of porting. Committing to #188 means committing to that.

## Current Baseline

Measured against `zig-out/bin/run` at `bb890a8`. Every claim below is reproducible from a
clean checkout.

| Capability a compiler needs | Status |
|---|---|
| Flat node array (`[]Node`, `append`, recursive walk) | Works |
| `map[string]int` symbol table | Works |
| Struct methods, `&T` / `@T` / value receivers on locals | Works |
| Sum types, nullables, error unions, `try`, `switch` destructuring | Works |
| Index a string — `s[0]` | **No lowering** |
| Range expression — `a[i..j]`, any element type | **No lowering** |
| Character literal in expression position — `'a'` | **No parser rule** |
| Write a struct field through a slice index — `ts[0].end = 9` | **No lowering** |
| Load another file — `use "pkg"` | **Parsed, then dropped** |
| Return an allocated slice from a function | **Use-after-free at runtime** |
| Read a file, see `argv`, set an exit code | **No runtime support** |
| Reproducible output | **Three identical builds → three different binaries** |

Two constructs also *silently miscompiled*, contradicting the invariant stated in
`CLAUDE.md` that unlowered constructs produce compile errors rather than wrong code:

- A `&T` method called on a slice element wrote to a temporary copy, discarding the
  mutation. Now rejected with a diagnostic until slice elements become addressable.
- `sizeOfTypeId` had no case for sum, nullable, or error-union types and returned 8, so
  those elements overlapped in slices. A `[]int?` holding `11, 22, 33` read back as
  `1, 1, 0`. Now laid out to match the emitted C.

Both are fixed; they are called out because the *class* matters more than the instances.
The invariant was believed rather than tested, and there are ~34 `unsupported()` sites
plus the paths that bypass them. Phase 0 exists to close that gap.

## The Bootstrap Subset

Stage 1 — the compiler written in Run — may only use the language features listed here.
Anything outside the subset cannot appear in stage-1 source, because stage 0 must be able
to compile it. The subset is **frozen** on the stage-0 freeze date and changes only by
amending this document.

**In the subset:**

- Functions, methods with `&T` / `@T` / value receivers, multiple returns
- `let` / `var`, module-level globals, `if` / `else`, all `for` forms, `switch`, `defer`
- Structs, sum types, nullables, error unions with `try` and `::` context
- Slices (`alloc`, `append`, index, range), maps, strings and `[]byte`
- `fun main` returning an exit code; `os` file, argument, and process access

**Deliberately excluded**, and stage-1 source must not depend on them:

- Generics — excluded by language design, so the compiler uses the flat-node-array plus
  tagged-union style the Zig implementation already uses
- Interfaces — no lowering today, and a compiler does not need dynamic dispatch
- Capturing closures — no lowering today; pass state explicitly
- Channels, `run` spawning, green threads — stage 1 is a single-threaded batch program
- SIMD, inline assembly, NUMA — irrelevant to compilation
- Any stdlib package outside the fourteen listed in Phase 4

Keeping the subset small is the point. Every feature stage 1 uses is a feature stage 0
must support flawlessly, and a feature the fixpoint must reproduce exactly.

## The Fixpoint Criterion

"Stage 2 output matches stage 1 output" needs a precise meaning, because this compiler
emits C and shells out to `zig cc`. Three tiers, in increasing strength:

- **Tier 1 — behavioural.** Stage 2 passes the full e2e suite with stdout, exit codes,
  and normalized diagnostics identical to stage 0. This is the minimum bar for calling
  the compiler self-hosted.
- **Tier 2 — emitted C.** The C emitted by stage 1 over the compiler's own sources is
  byte-identical to the C emitted by stage 2 over the same sources. This is the real
  fixpoint proof and the one #188 should be closed on.
- **Tier 3 — binary.** The stage-2 and stage-3 binaries are byte-identical. Depends on
  `zig cc` determinism, which is outside this project's control, so it is a goal rather
  than a gate.

Tier 2 is unreachable today: three consecutive identical `run build` invocations produce
three different binaries, because the intermediate C file is named from a random `u64`
(`src/driver.zig:921`) and that name leaks into the artifact. There is also no
`--emit-c`, so the C cannot be captured as a comparable artifact at all. Both are Phase 0
work — the fixpoint criterion cannot even be *stated* until they land.

## Migration Order

Frontend-first, behind differential oracles. `run tokens` and `run ast` already exist and
already emit stable text, which makes them free checkpoints: a Run lexer and a Run parser
can be validated against the Zig implementation long before the backend is touched. The
alternatives — a big-bang rewrite, or a Zig/Run FFI bridge — either defer all risk to the
end or build a bridge that gets thrown away.

The one gap in this approach is the backend: `typecheck` + `lower` + `codegen_c` is 11,800
lines with no equivalent oracle. Phase 5 therefore adds `run ir` and `--emit-c` so the
backend gets the same treatment, rather than being one six-month step with a binary
pass/fail at the end.

### Phase 0 — Make the compiler trustworthy (~3 weeks)

Until unsupported constructs fail loudly, no downstream test result can be trusted: a
passing test may be a miscompile and a failing one may be a leaked `zig cc` error with no
Run source context.

- Land this document; freeze the bootstrap subset and set the stage-0 freeze date
- Fix the known silent miscompiles *(done — see the table above)*
- Audit every unsupported construct so it produces a Run diagnostic before codegen
- Add `run build --emit-c <path>` and make the generated C filename deterministic

**Exit:** a scripted sweep of the known-unsupported constructs produces a Run diagnostic
with source context and a non-zero exit for every one, no raw `zig cc` output reaches the
user, and three consecutive builds of the same input produce identical C and identical
binaries.

### Phase 1 — Make a lexer expressible (~8 weeks)

- String indexing, iteration, and `len`
- Range expressions `a[i..j]` end to end, for strings and slices
- Character literals in expression position
- Linear string building — a builder primitive and a freeing concat. Today
  `run_string_concat` mallocs `a+b` and frees neither operand; 20,000 appends producing a
  200 KB result cost 2.16 GB peak RSS. A compiler emitting a megabyte of C per unit
  cannot use it.
- Ownership transfer on return, so a pass can return its output
- `run_syscall_*` runtime, plus `argv` and exit codes — a Run lexer cannot read its input
  without them, which is why this cannot wait for a later phase

**Exit:** a lexer written in Run, compiled by stage 0, tokenizes all e2e cases with output
byte-identical to `run tokens`, returning its tokens as `[]Token` from a function.

### Phase 2 — Make a parser and AST expressible (~10 weeks)

- Slice-element field lvalues and `&slice[i]`
- Two-phase struct registration, for forward and self-referential field types
- Module-level `let` / `var` in lowering and codegen
- Switch payload bindings, so field access works on `.ok(t)` / `.some(n)`
- Sum-type variant literals in general expression position
- `for`-in element typing
- Green-thread stack growth — recursive descent will exceed the current limit

**Exit:** a recursive-descent parser written in Run matches `run ast` byte-for-byte on all
e2e cases, including one nested deeply enough to stress the stack, run repeatedly.

### Phase 3 — Multi-file and multi-package compilation (~12 weeks)

The largest single refactor on the path, and the long pole — start its design during
Phase 1. It needs no package manager, no network, no semver, and no lockfile.

- Driver accepts a package/file set instead of one file
- Cross-file resolve and typecheck: `(file_id, node)` side tables, one shared `TypePool`
  and `SymbolTable`
- Resolve and compile the stdlib from `stdlib/<pkg>/*.run` source
- Cross-package name mangling and multi-module C output
- Import validation and `pub` enforcement across package boundaries
- Per-file identity in diagnostics

**Exit:** the Phase 1–2 frontend, split across several files in at least two local
packages plus one real stdlib import, still matches `run tokens` and `run ast`. A typo'd
import path produces a Run diagnostic, not a `zig cc` error.

### Phase 4 — OS capability and a usable stdlib (~8 weeks)

Split deliberately in two, because these are different jobs with different owners:
*compiler gaps blocking stdlib*, and *stdlib authoring corrections*. Much of the stdlib
was written against a specification the compiler never implemented — for example variant
returns written as `return .some(x)` where the spec says a bare `return x` — and some of
it needs rewriting rather than fixing.

- Compile `run_exec.c` and `run_signal.c` into `librunrt.a`, so the driver can spawn `zig cc`
- Bring the fourteen compiler-critical packages through the full pipeline: `os`, `io`,
  `fmt`, `strings`, `bytes`, `strconv`, `sort`, `maps`, `slices`, `errors`, `path`,
  `testing`, `bufio`, `unicode/utf8`

**Exit:** a Run program reads its `argv`, reads and writes files, spawns `zig cc`, reads
its exit status, and terminates with a chosen non-zero code. All fourteen packages reach
object code, gated in CI.

### Phase 5 — Verification infrastructure (~6 weeks)

Built before stage 1 exists, so it can be validated by running stage 0 against stage 0.

- `run ir` dump, giving the backend the oracle the frontend already has
- Parameterize the e2e runner to compare two compiler binaries
- Real test-body execution — `run test` currently reports `0 passed, 0 failed, 0 total`
  on files full of syntax errors
- A stated resource budget: stage 1 must compile the compiler within a fixed wall-clock
  and RSS. Maps are never freed, the allocator never returns memory to the OS, and
  strings are quadratic; discovering that at the end of Phase 6 would be fatal.

**Exit:** the two-compiler harness reports per-case agreement on emitted C, stdout, exit
code, and normalized diagnostics, validated by running stage 0 against itself.

### Phase 6 — Port stage 1 and prove the fixpoint (~6–12 months)

Frontend first, behind the checkpoints proven in Phases 1–2, then the backend behind the
checkpoints from Phase 5. Freeze the Zig compiler as stage 0 on the agreed date.

**Exit:** `zig build bootstrap` runs stage 0 → stage 1 → stage 2 and asserts the Tier 2
criterion automatically.

## Relationship to the Package Manager

A self-hosted Run compiler has zero GitHub dependencies. It needs its own sources across
a handful of local packages, plus the stdlib — no TOML, no semver, no MVS, no archive
fetching, no lockfile.

- **Defer** all 19 M14 issues (#293–#311).
- **Re-scope and move**, not duplicate, the six M15 issues that already describe the work
  Phase 3 needs: #312, #314, #315, #316, #317, #318. Retitle them from *external
  packages* to *local packages and stdlib*, drop their `run.lock` and cache dependencies,
  and move them to a dedicated milestone. That dependency chain — #314 requiring the
  driver to read `run.lock`, #312 depending on cache infrastructure — is the only reason
  #188 currently looks gated behind thirty issues.
- **Leave deferred:** #313, #319–#322, #222, #223 (effectively a duplicate of #322), #291.

One bug hides in #312 and should be fixed when it is re-scoped: RFC #218's rule *"no
dots, no slashes → stdlib"* mis-classifies the stdlib's own `use "crypto/rand"`,
`use "net/http"`, and `use "io/fs"` paths, which match none of its three rules.

**Open decision, to be made before the stage-0 freeze date.** Deferring M14 is right for
sequencing, but it is not free: writing the package manager in Run *afterwards* means
debugging TLS, gzip, tar, and subprocess spawning in an unproven stdlib at the same time
as a new self-hosted frontend. In Zig those dependencies come from `std` for nothing. So
either M14 is written in Zig before the freeze, or it is accepted as expensive Run work
after it. Choosing "later" by default is the one outcome to avoid.

## Risks

- **Scope.** Phases 1–5 are roughly 40–50 engineer-weeks of sequenced work against a
  30,302-line compiler, before a line of stage 1 is written. If the available appetite is
  a quarter, the honest move is to spend it on Phases 0–1 — which are worth doing whether
  or not #188 proceeds — and defer the rest.
- **Phase 3 is the schedule risk.** It touches `driver`, `resolve`, `typecheck`, `lower`,
  `symbol`, and `types` simultaneously and cannot be landed incrementally behind a flag.
- **Silent miscompiles are the correctness risk.** Two were found and fixed; the invariant
  they violated was assumed rather than tested, so the prior should be that more exist.
- **The stdlib may be a liability rather than an asset.** 32k lines, never compiled, never
  executed, with test files that do not parse.
- **The oracles are load-bearing.** `run tokens` and `run ast` were not designed as
  interchange formats and neither is covered by a test asserting its shape. If either is
  lossy, the Phase 1–2 checkpoints prove less than they appear to.
- **Tooling drift.** `lsp.zig`, `formatter.zig`, `dap.zig`, and `wasm.zig` — 3,857 lines —
  import the Zig frontend directly and ship in the same binary. Stage 0 is retained, so
  they keep working, but they stop tracking the language once stage 1 leads.
