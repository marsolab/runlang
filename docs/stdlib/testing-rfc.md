# RFC: Testing Package Redesign

## Motivation

The current testing design follows Go's approach: test functions with a `test_` prefix
and a `testing.T` parameter. This works but has several limitations:

1. **No language-level test support** — tests are just functions, discovered by naming convention
2. **Table-driven tests are boilerplate-heavy** — require manual struct definition, loop, and subtest naming
3. **No built-in fuzzing** — fuzzing is a separate infrastructure concern rather than a first-class feature
4. **Test descriptions are identifiers** — `test_add_returns_sum_of_two_positive_integers` is not readable

This RFC redesigns testing around a `test` keyword (inspired by Zig) with first-class
table-driven tests and fuzzing, while keeping Go's practical strengths (explicit test
context, subtests, benchmarks). Assertions use a composable operator pattern inspired
by [go-testdeep](https://github.com/maxatome/go-testdeep).

## Design

### The `test` Keyword

`test` is a new top-level keyword that declares a test block. It takes a string
description, an explicit test context parameter `(t)`, and a body:

```run
use "testing"

test "addition works" (t) {
    t.expect(add(2, 3), t.eq(5))
    t.expect(add(-1, 1), t.eq(0))
}
```

Key properties:
- `test` blocks are **top-level declarations** (like `fun`, `type`, `struct`)
- The string is a **human-readable description**, not an identifier
- `(t)` receives the test context `&T` explicitly — like Go, unlike Zig
- `t.expect(got, operator)` is the single assertion method
- Operators (`t.eq`, `t.gt`, `t.contains`, etc.) are methods on `T`
- Tests are stripped from production builds — zero cost

### `t.expect` and Operators

`t.expect` is the **single assertion method** on the test context. It takes a value
and an operator. Operators are methods on `T` that return an `Operator` value:

```run
use "testing"

test "operators" (t) {
    // Equality and comparison
    t.expect(add(2, 3), t.eq(5))            // deep equality
    t.expect(count, t.ne(0))                 // not equal
    t.expect(age, t.gt(18))                  // greater than
    t.expect(age, t.gte(18))                 // greater than or equal
    t.expect(score, t.lt(100))               // less than
    t.expect(score, t.lte(100))             // less than or equal
    t.expect(temp, t.between(36.0, 37.5))   // range (inclusive)

    // Boolean
    t.expect(isReady, t.isTrue())           // assert true
    t.expect(isDone, t.isFalse())           // assert false

    // Nil / error
    t.expect(ptr, t.isNil())                // assert null
    t.expect(result, t.notNil())            // assert non-null
    t.expect(parse("???"), t.isErr())       // assert error union is .err
    t.expect(parse("42"), t.isOk())         // assert error union is .ok

    // Strings
    t.expect(name, t.hasPrefix("John"))     // string prefix
    t.expect(name, t.hasSuffix("Doe"))      // string suffix
    t.expect(body, t.contains("hello"))     // substring (also works on slices)
    t.expect(email, t.matches("[a-z]+@.+")) // regex match

    // Collections
    t.expect(items, t.hasLen(3))            // length check
    t.expect(buf, t.hasCap(64))             // capacity check
    t.expect(list, t.isEmpty())             // empty check
    t.expect(list, t.notEmpty())            // non-empty check
    t.expect(ids, t.containsAll(1, 2, 3))  // all elements present
    t.expect(ids, t.containsAny(1, 2, 3))  // at least one present

    // Composition — operators compose via all/any/none
    t.expect(x, t.all(t.gt(0), t.lt(100))) // AND: all must match
    t.expect(x, t.any(t.eq(0), t.gt(10)))  // OR: at least one must match
    t.expect(x, t.none(t.eq(0), t.lt(0)))  // NOR: none must match
    t.expect(x, t.not(t.eq(0)))            // negation
}
```

When an assertion fails, `t.expect` reports:
- Source file and line
- The expression that failed
- Expected vs actual values
- A diff for large string/struct comparisons
- The operator description (e.g., "expected > 18, got 16")

### Operators are Methods on `T`

Operators are methods on the test context `T`. They return an `Operator` value
that `t.expect` evaluates:

```run
// In testing package:
pub fun (t @T) eq(want any) Operator { ... }
pub fun (t @T) gt(bound any) Operator { ... }
pub fun (t @T) hasPrefix(prefix string) Operator { ... }
pub fun (t @T) all(ops ...Operator) Operator { ... }
```

This means:
- No new keywords needed for operators
- Users can write custom operators by returning `Operator`
- IDE autocomplete on `t.` shows all available operators

### Table-Driven Tests (First-Class)

Table-driven testing is the most common pattern in Go. Run makes it a language
construct using `for` with named cases. Each case uses the `::` separator
(consistent with `switch` arms):

```run
use "testing"

for test "add" in [
    "positive"    :: { a: 2,  b: 3,  want: 5  },
    "negative"    :: { a: -1, b: -2, want: -3  },
    "zeros"       :: { a: 0,  b: 0,  want: 0   },
    "mixed signs" :: { a: -3, b: 7,  want: 4   },
] (t) {
    t.expect(add(row.a, row.b), t.eq(row.want))
}
```

Key properties:
- `for test` / `for bench` introduces the table-driven variant
- Each case is `"name" :: { fields }` — reuses the `::` separator from `switch`
- The string before `::` is the **subtest name**, shown in output
- The struct after `::` is the **test data**, accessed via the implicit `row` binding
- `(t)` receives the test context for each case
- Row fields are inferred from the struct literals — no type declaration needed
- Each case runs as an independent subtest

More table-driven examples:

```run
for test "parseInt" in [
    "simple"        :: { input: "42",    want: 42    },
    "negative"      :: { input: "-7",    want: -7    },
    "zero"          :: { input: "0",     want: 0     },
    "with spaces"   :: { input: " 12 ",  want: 12    },
    "large number"  :: { input: "99999", want: 99999 },
] (t) {
    result := try parseInt(row.input)
    t.expect(result, t.eq(row.want))
}

for test "http status codes" in [
    "ok"          :: { code: 200, class: "success" },
    "created"     :: { code: 201, class: "success" },
    "bad request" :: { code: 400, class: "client"  },
    "not found"   :: { code: 404, class: "client"  },
    "internal"    :: { code: 500, class: "server"  },
] (t) {
    t.expect(classifyStatus(row.code), t.eq(row.class))
}

for test "validate email" in [
    "valid simple" :: { email: "a@b.com",   valid: true  },
    "valid dots"   :: { email: "a.b@c.com", valid: true  },
    "missing @"    :: { email: "abc.com",   valid: false },
    "empty"        :: { email: "",          valid: false },
] (t) {
    result := validateEmail(row.email)
    if row.valid {
        t.expect(result, t.isOk())
    } else {
        t.expect(result, t.isErr())
    }
}
```

Rows can also bind with destructuring for conciseness:

```run
for test "string trimming" in [
    "leading"  :: { input: "  hello", want: "hello" },
    "trailing" :: { input: "hello  ", want: "hello" },
    "both"     :: { input: " hello ", want: "hello" },
    "none"     :: { input: "hello",   want: "hello" },
    "empty"    :: { input: "",        want: ""       },
] as { input, want } (t) {
    t.expect(trim(input), t.eq(want))
}
```

### Subtests

For dynamic or conditional subtests that don't fit the table pattern, use `t.run`:

```run
test "database operations" (t) {
    db := try setupTestDb()
    defer db.close()

    t.run("insert") (t) {
        try db.insert("key", "value")
        result := try db.get("key")
        t.expect(result, t.eq("value"))
    }

    t.run("delete") (t) {
        try db.delete("key")
        result := db.get("key")
        t.expect(result, t.isErr())
    }
}
```

### Fuzzing (First-Class)

Fuzz tests use the `test ... fuzz` form. The compiler and test runner handle
corpus management, coverage guidance, and mutation:

```run
test "json roundtrip" fuzz(data []byte) (t) {
    parsed := parseJson(data) or return
    output := toJson(parsed)
    reparsed := try parseJson(output)
    t.expect(reparsed, t.eq(parsed))
}
```

Key properties:
- `fuzz(params)` declares the fuzz inputs and their types
- Supported fuzz types: `[]byte`, `string`, `int`, `uint`, `f64`, `bool`
- `or return` inside fuzz tests skips inputs that don't meet preconditions
- The test runner manages the corpus (in `testdata/fuzz/<TestName>/`)

Seed corpus with `seed`:

```run
test "parseInt is safe" fuzz(input string) seed [
    "0", "-1", "999999999", "", "abc", "2147483648",
] (t) {
    _ = parseInt(input)
}
```

Multiple fuzz parameters:

```run
test "encode decode" fuzz(key string, value []byte) (t) {
    encoded := encode(key, value)
    t.expect(encoded, t.notEmpty())
    k, v := try decode(encoded)
    t.expect(k, t.eq(key))
    t.expect(v, t.eq(value))
}

test "utf8 validation" fuzz(data []byte) seed [
    []byte{},
    []byte{0x00},
    []byte{0x7F},
    []byte{0xC0, 0x80},
    []byte{0xED, 0xA0, 0x80},
] (t) {
    if isValidUtf8(data) {
        s := stringFromBytes(data)
        t.expect(bytesFromString(s), t.eq(data))
    }
}
```

### Benchmarks

Benchmarks use the `bench` keyword:

```run
bench "sort 1000 elements" (b) {
    data := generateRandomSlice(1000)
    b.resetTimer()
    for _ in 0..b.n {
        sort(data)
    }
}

bench "map lookup" (b) {
    m := buildTestMap(10000)
    keys := generateKeys(1000)
    b.resetTimer()
    for _ in 0..b.n {
        for key in keys {
            _ = m[key]
        }
    }
}
```

Table-driven benchmarks:

```run
for bench "sort" in [
    "10 elements"    :: { size: 10    },
    "100 elements"   :: { size: 100   },
    "1000 elements"  :: { size: 1000  },
    "10000 elements" :: { size: 10000 },
] (b) {
    data := generateRandomSlice(row.size)
    b.resetTimer()
    for _ in 0..b.n {
        sort(data)
    }
}

for bench "hash functions" in [
    "fnv32"   :: { hashFn: fnv32   },
    "murmur3" :: { hashFn: murmur3 },
    "xxhash"  :: { hashFn: xxhash  },
] (b) {
    data := generateRandomBytes(1024)
    b.bytesPerOp(1024)
    b.resetTimer()
    for _ in 0..b.n {
        _ = row.hashFn(data)
    }
}
```

### Test Lifecycle Hooks

Setup and teardown at the file/package level:

```run
test beforeAll {
    db = try setupDatabase()
}

test afterAll {
    db.close()
}

test beforeEach {
    try db.clear()
}

test afterEach {
    try cleanupTempFiles()
}
```

### Test Context (`T`)

The explicit `t` parameter provides:

**Control methods:**
```
t.expect(got, operator)  — assert got matches operator
t.log(msg)               — log a message (shown only on failure or -v)
t.logf(format, args)     — formatted log
t.skip(reason)           — skip this test
t.fail()                 — mark failed, continue running
t.failNow()              — mark failed, stop immediately
t.fatal(msg)             — log + failNow
t.fatalf(format, args)   — formatted fatal
t.run(name) (t) { }      — launch a subtest
t.parallel()             — mark test as safe to run in parallel
t.deadline() int         — returns the test timeout deadline
t.tempDir() string       — returns a temporary directory cleaned up after the test
t.name() string          — returns the current test/subtest name
```

**Operator methods (return `Operator` for use with `t.expect`):**
```
t.eq(want)               — deep equality
t.ne(want)               — not equal
t.gt(bound)              — greater than
t.gte(bound)             — greater than or equal
t.lt(bound)              — less than
t.lte(bound)             — less than or equal
t.between(lo, hi)        — range [lo, hi]
t.isTrue()               — boolean true
t.isFalse()              — boolean false
t.isNil()                — null check
t.notNil()               — non-null check
t.isErr()                — error union is .err
t.isOk()                 — error union is .ok
t.hasPrefix(s)           — string prefix
t.hasSuffix(s)           — string suffix
t.contains(v)            — substring or element containment
t.matches(pattern)       — regex match
t.hasLen(n)              — length check
t.hasCap(n)              — capacity check
t.isEmpty()              — length is 0
t.notEmpty()             — length > 0
t.containsAll(items...)  — all items present
t.containsAny(items...)  — at least one present
t.all(ops...)            — AND: all must match
t.any(ops...)            — OR: at least one must match
t.none(ops...)           — NOR: none must match
t.not(op)                — negation
t.approx(want, tol)      — numeric approximate equality
t.typeOf(name)           — type check
```

### Benchmark Context (`B`)

The explicit `b` parameter provides:

```
b.n int                            — iteration count (set by framework)
b.resetTimer()                     — reset timer and counters
b.startTimer()                     — resume timing
b.stopTimer()                      — pause timing
b.reportMetric(name, val, unit)    — custom metric
b.bytesPerOp(n)                    — set bytes processed per iteration
b.run(name) (b) { }               — sub-benchmark
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
| `test "name" (t) { }` | Unit test block |
| `for test "name" in ["case" :: {}, ...] (t) { }` | Table-driven test |
| `for test "name" in [...] as { fields } (t) { }` | Table-driven test with destructuring |
| `test "name" fuzz(params) (t) { }` | Fuzz test |
| `test "name" fuzz(params) seed [...] (t) { }` | Fuzz test with seed corpus |
| `bench "name" (b) { }` | Benchmark block |
| `for bench "name" in ["case" :: {}, ...] (b) { }` | Table-driven benchmark |
| `test beforeAll { }` | File-level setup |
| `test afterAll { }` | File-level teardown |
| `test beforeEach { }` | Per-test setup |
| `test afterEach { }` | Per-test teardown |
| `t.run("name") (t) { }` | Dynamic subtest |
| `t.parallel()` | Parallel test marker |

### Key Design Decisions

1. **Explicit `t` parameter** — like Go, test context is passed explicitly via `(t)`.
   This makes it clear what's available and enables helper functions that accept `&T`.

2. **`t.expect` is the single assertion method** — no `expectEq`, `expectNe`, etc.
   One method + composable operators covers all cases.

3. **Operators are methods on `T`** — `t.eq`, `t.gt`, `t.contains`, `t.all`, etc.
   They return `Operator` values. This keeps operators out of the keyword list
   and provides natural IDE autocomplete via `t.`.

4. **`"case" :: { data }` syntax** — reuses `::` from switch for table cases.
   No new keywords needed for table-driven tests.

## Comparison

| Feature | Go | Zig | Run (new) |
|---------|-----|-----|-----------|
| Test declaration | `func TestX(t *testing.T)` | `test "name" { }` | `test "name" (t) { }` |
| Test descriptions | Identifier names | String literals | String literals |
| Test context | `t *testing.T` (explicit) | implicit | `t` (explicit) |
| Assertions | Third-party (testify) | `try std.testing.expect()` | `t.expect(got, t.op())` |
| Operators | go-testdeep (third-party) | N/A | `t.eq`, `t.gt`, ... (built-in) |
| Table-driven | Manual struct + loop | Manual | `for test ... in ["name" :: {}, ...]` |
| Subtests | `t.Run("name", func(t *T))` | N/A | `t.run("name") (t) { }` |
| Fuzzing | `func FuzzX(f *testing.F)` | `std.testing.fuzz` | `test ... fuzz(params)` |
| Benchmarks | `func BenchX(b *testing.B)` | Manual timing | `bench "name" (b) { }` |
| Parallel | `t.Parallel()` | N/A | `t.parallel()` |
| Lifecycle hooks | `TestMain` | N/A | `beforeAll/afterAll/beforeEach/afterEach` |

## Implementation Notes

### New Tokens
- `kw_test` — the `test` keyword
- `kw_bench` — the `bench` keyword
- `kw_fuzz` — the `fuzz` keyword (contextual, only after test)
- `kw_seed` — the `seed` keyword (contextual, only after fuzz params)

Note: `for` and `::` are already tokens. Operators are methods on `T`, not tokens.

### New AST Nodes
- `test_decl` — test block with description, parameter, and body
- `table_test_decl` — table-driven test with named cases, parameter, and body
- `fuzz_test_decl` — fuzz test with fuzz parameters, test parameter, optional seed, and body
- `bench_decl` — benchmark block with description, parameter, and body
- `table_bench_decl` — table-driven benchmark with named cases
- `test_hook_decl` — lifecycle hook (beforeAll, afterAll, etc.)

### Compiler Changes
- Lexer: Add new keyword tokens (`test`, `bench`, `fuzz`, `seed`)
- Parser: Parse test/bench declarations at top level; parse `for [...]` case tables
- Codegen: Strip test/bench blocks from non-test builds
- Test runner: Discover test/bench/fuzz declarations from AST instead of name prefix

## References

- Issue #245 — stdlib: implement testing package
- RFC #219 — Standard Library Redesign
- Inspiration: [go-testdeep](https://github.com/maxatome/go-testdeep) operator pattern
