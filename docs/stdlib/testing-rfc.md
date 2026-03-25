# RFC: Testing Package Redesign

## Motivation

The current testing design follows Go's approach: test functions with a `test_` prefix
and a `testing.T` parameter. This works but has several limitations:

1. **No language-level test support** — tests are just functions, discovered by naming convention
2. **Table-driven tests are boilerplate-heavy** — require manual struct definition, loop, and subtest naming
3. **No built-in fuzzing** — fuzzing is a separate infrastructure concern rather than a first-class feature
4. **Test descriptions are identifiers** — `test_add_returns_sum_of_two_positive_integers` is not readable

This RFC redesigns testing around a `test` keyword (inspired by Zig) with first-class
table-driven tests and fuzzing, while keeping Go's practical strengths (subtests,
benchmarks, test context).

## Design

### The `test` Keyword

`test` is a new top-level keyword that declares a test block. It takes a string
description and a body:

```run
test "addition works" {
    expect_eq(add(2, 3), 5)
    expect_eq(add(-1, 1), 0)
}
```

Key properties:
- `test` blocks are **top-level declarations** (like `fun`, `type`, `struct`)
- The string is a **human-readable description**, not an identifier
- Test blocks have an implicit `t: &T` available for logging, skipping, etc.
- Assertion functions (`expect`, `expect_eq`, etc.) are available without a receiver
- Tests are stripped from production builds — zero cost

### Assertions

Assertions are free functions available inside `test` blocks. They produce rich
failure messages with source location and values:

```run
test "assertions" {
    expect(x > 0)                        // condition with auto-generated message
    expect_eq(got, want)                  // == with diff on failure
    expect_ne(a, b)                       // !=
    expect_true(ok)                       // explicit bool true
    expect_false(done)                    // explicit bool false
    expect_err(parse("???"))             // expects error union to be .err
    expect_ok(parse("42"))               // expects error union to be .ok
    expect_nil(ptr)                       // expects nullable to be null
    expect_not_nil(ptr)                   // expects nullable to be non-null
}
```

When an assertion fails, it reports:
- Source file and line
- The expression that failed
- Expected vs actual values (for `expect_eq`/`expect_ne`)
- A diff for large string/struct comparisons

### Table-Driven Tests (First-Class)

Table-driven testing is the most common pattern in Go. Run makes it a language
construct using `for` with named cases. Each case uses the `::` separator
(consistent with `switch` arms):

```run
test "add" for [
    "positive"      :: { a: 2,  b: 3,  want: 5   },
    "negative"      :: { a: -1, b: -2, want: -3   },
    "zeros"         :: { a: 0,  b: 0,  want: 0    },
    "mixed signs"   :: { a: -3, b: 7,  want: 4    },
] {
    expect_eq(add(row.a, row.b), row.want)
}
```

Key properties:
- `for` introduces the case table — reuses the existing `for` keyword
- Each case is `"name" :: { fields }` — reuses the `::` separator from `switch`
- The string before `::` is the **subtest name**, shown in output
- The struct after `::` is the **test data**, accessed via the implicit `row` binding
- Row fields are inferred from the struct literals — no type declaration needed
- Each case runs as an independent subtest

Rows can also bind with destructuring for conciseness:

```run
test "add" for [
    "positive" :: { a: 2, b: 3, want: 5 },
    "zeros"    :: { a: 0, b: 0, want: 0 },
] as { a, b, want } {
    expect_eq(add(a, b), want)
}
```

### Subtests

For dynamic or conditional subtests that don't fit the table pattern, use `t.run`:

```run
test "database operations" {
    db := try setup_test_db()
    defer db.close()

    t.run("insert") {
        try db.insert("key", "value")
        result := try db.get("key")
        expect_eq(result, "value")
    }

    t.run("delete") {
        try db.delete("key")
        result := db.get("key")
        expect_err(result)
    }
}
```

### Fuzzing (First-Class)

Fuzz tests use the `test ... fuzz` form. The compiler and test runner handle
corpus management, coverage guidance, and mutation:

```run
test "json roundtrip" fuzz(data: []byte) {
    parsed := parse_json(data) or return    // skip invalid inputs
    output := to_json(parsed)
    reparsed := try parse_json(output)
    expect_eq(parsed, reparsed)
}
```

Key properties:
- `fuzz(params)` declares the fuzz inputs and their types
- Supported fuzz types: `[]byte`, `string`, `int`, `uint`, `f64`, `bool`
- `or return` inside fuzz tests skips inputs that don't meet preconditions
- The test runner manages the corpus (in `testdata/fuzz/<TestName>/`)
- Seed corpus can be provided with `seed`:

```run
test "parse_int is safe" fuzz(input: string) seed [
    "0", "-1", "999999999", "", "abc", "2147483648",
] {
    // Should never panic, regardless of input
    _ = parse_int(input)
}
```

Multiple fuzz parameters:

```run
test "encode_decode" fuzz(key: string, value: []byte) {
    encoded := encode(key, value)
    k, v := try decode(encoded)
    expect_eq(k, key)
    expect_eq(v, value)
}
```

### Benchmarks

Benchmarks use the `bench` keyword:

```run
bench "sort 1000 elements" {
    data := generate_random_slice(1000)
    b.reset_timer()
    for _ in 0..b.n {
        sort(data)
    }
}
```

With table-driven benchmarks:

```run
bench "sort" for [
    "10 elements"    :: { size: 10    },
    "100 elements"   :: { size: 100   },
    "1000 elements"  :: { size: 1000  },
    "10000 elements" :: { size: 10000 },
] {
    data := generate_random_slice(row.size)
    b.reset_timer()
    for _ in 0..b.n {
        sort(data)
    }
}
```

Key properties:
- `bench` blocks have an implicit `b: &B` context
- `b.n` is the iteration count, set by the framework
- `b.reset_timer()` excludes setup from timing
- `b.report_metric(name, value, unit)` for custom metrics
- `b.bytes_per_op(n)` for throughput calculation

### Test Lifecycle Hooks

Setup and teardown at the file/package level:

```run
test before_all {
    // Runs once before all tests in this file
    db = try setup_database()
}

test after_all {
    // Runs once after all tests in this file
    db.close()
}

test before_each {
    // Runs before each test
    try db.clear()
}

test after_each {
    // Runs after each test
    try cleanup_temp_files()
}
```

### Test Context (`T`)

The implicit `t` provides:

```
t.log(msg)              — log a message (shown only on failure or -v)
t.logf(format, args)    — formatted log
t.skip(reason)          — skip this test
t.fail()                — mark failed, continue running
t.fail_now()            — mark failed, stop immediately
t.fatal(msg)            — log + fail_now
t.fatalf(format, args)  — formatted fatal
t.run(name) { }         — launch a subtest
t.parallel()            — mark test as safe to run in parallel
t.deadline() Time       — returns the test timeout deadline
t.temp_dir() string     — returns a temporary directory cleaned up after the test
t.name() string         — returns the current test/subtest name
```

### Benchmark Context (`B`)

The implicit `b` provides:

```
b.n int                         — iteration count (set by framework)
b.reset_timer()                 — reset timer and counters
b.start_timer()                 — resume timing
b.stop_timer()                  — pause timing
b.report_metric(name, val, unit) — custom metric
b.bytes_per_op(n)               — set bytes processed per iteration
b.run(name) { }                 — sub-benchmark
```

### Test Runner CLI

```bash
run test                        # run all tests
run test math                   # run tests in math package
run test -f "parse"             # filter by name substring
run test -v                     # verbose — show all logs
run test -parallel 4            # max parallel tests
run test -timeout 30s           # per-test timeout
run test -count 5               # run each test N times
run test -shuffle               # randomize test order
run test -bench                 # run benchmarks too
run test -bench "sort"          # run matching benchmarks
run test -fuzz "json"           # run matching fuzz tests
run test -fuzz-time 30s         # fuzz duration
run test -cover                 # show coverage summary
run test -cover -coverprofile   # write coverage data
```

### Test File Organization

Tests live in the same file as the code they test (like Zig), or in separate
`_test.run` files (like Go). Both are supported:

```
math/
    vector.run          // code + tests in same file
    matrix.run          // code + tests in same file
    matrix_test.run     // additional tests (optional, for large test suites)
```

`_test.run` files can access private package members (same package scope).

## Summary of New Keywords/Syntax

| Syntax | Purpose |
|--------|---------|
| `test "name" { }` | Unit test block |
| `test "name" for ["case" :: {}, ...] { }` | Table-driven test |
| `test "name" for [...] as { fields } { }` | Table-driven test with destructuring |
| `test "name" fuzz(params) { }` | Fuzz test |
| `test "name" fuzz(params) seed [...] { }` | Fuzz test with seed corpus |
| `bench "name" { }` | Benchmark block |
| `bench "name" for ["case" :: {}, ...] { }` | Table-driven benchmark |
| `test before_all { }` | File-level setup |
| `test after_all { }` | File-level teardown |
| `test before_each { }` | Per-test setup |
| `test after_each { }` | Per-test teardown |
| `t.run("name") { }` | Dynamic subtest |
| `t.parallel()` | Parallel test marker |

### Case Syntax: `"name" :: { fields }`

The table-driven test case syntax reuses two existing language constructs:

1. **`for`** — the iteration keyword, already used for loops (`for item in collection`)
2. **`::`** — the arm separator, already used in `switch` (`pattern :: body`)

This means no new keywords are needed for table-driven tests. A case reads naturally:
`"description" :: { test data }`, just like a switch arm reads `pattern :: action`.

## Comparison

| Feature | Go | Zig | Run (new) |
|---------|-----|-----|-----------|
| Test declaration | `func TestX(t *testing.T)` | `test "name" { }` | `test "name" { }` |
| Test descriptions | Identifier names | String literals | String literals |
| Table-driven | Manual struct + loop | Manual | `test ... for ["name" :: {}, ...]` |
| Subtests | `t.Run("name", func(t *T))` | N/A | `t.run("name") { }` |
| Fuzzing | `func FuzzX(f *testing.F)` | `std.testing.fuzz` | `test ... fuzz(params)` |
| Benchmarks | `func BenchX(b *testing.B)` | Manual timing | `bench "name" { }` |
| Parallel | `t.Parallel()` | N/A | `t.parallel()` |
| Lifecycle hooks | `TestMain` | N/A | `before_all/after_all/before_each/after_each` |
| Assertions | Third-party (testify) | `try std.testing.expect()` | Built-in `expect_eq`, etc. |

## Implementation Notes

### New Tokens
- `kw_test` — the `test` keyword
- `kw_bench` — the `bench` keyword
- `kw_fuzz` — the `fuzz` keyword (contextual, only after test)
- `kw_seed` — the `seed` keyword (contextual, only after fuzz params)

Note: `for` and `::` are already tokens. No new keyword needed for table-driven tests.

### New AST Nodes
- `test_decl` — test block with description and body
- `table_test_decl` — table-driven test with named cases and body
- `fuzz_test_decl` — fuzz test with parameters, optional seed, and body
- `bench_decl` — benchmark block with description and body
- `table_bench_decl` — table-driven benchmark with named cases
- `test_hook_decl` — lifecycle hook (before_all, after_all, etc.)

### Compiler Changes
- Lexer: Add new keyword tokens (`test`, `bench`, `fuzz`, `seed`)
- Parser: Parse test/bench declarations at top level; parse `for [...]` case tables
- Codegen: Strip test/bench blocks from non-test builds
- Test runner: Discover test/bench/fuzz declarations from AST instead of name prefix

## References

- Issue #245 — stdlib: implement testing package
- RFC #219 — Standard Library Redesign
