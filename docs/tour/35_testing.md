# Testing

Run has first-class testing built into the language with the `test` keyword. Tests
combine Zig's `test` blocks with Go's explicit test context and a composable
operator system inspired by go-testdeep.

## Writing Tests

A test is a `test` block with a string description and an explicit test context `(t)`:

```run
package math

use "testing"

fun add(a int, b int) int {
    return a + b
}

test "add returns correct sums" (t) {
    t.expect(add(2, 3), t.eq(5))
    t.expect(add(-1, 1), t.eq(0))
    t.expect(add(0, 0), t.eq(0))
}
```

## Assertions with Operators

`t.expect(got, operator)` is the single assertion method. Operators are methods
on `t` that describe how to compare values:

```run
test "operators" (t) {
    t.expect(add(2, 3), t.eq(5))            // deep equality
    t.expect(count, t.ne(0))                 // not equal
    t.expect(age, t.gt(18))                  // greater than
    t.expect(score, t.lte(100))             // less than or equal
    t.expect(temp, t.between(36.0, 37.5))   // range

    t.expect(ptr, t.isNil())                // null check
    t.expect(result, t.isOk())              // error union is .ok
    t.expect(parse("???"), t.isErr())       // error union is .err

    t.expect(name, t.hasPrefix("John"))     // string prefix
    t.expect(body, t.contains("hello"))     // substring
    t.expect(items, t.hasLen(3))            // length check
    t.expect(list, t.notEmpty())            // non-empty

    // Compose operators
    t.expect(x, t.all(t.gt(0), t.lt(100))) // AND
    t.expect(x, t.any(t.eq(0), t.gt(10)))  // OR
    t.expect(x, t.not(t.eq(0)))            // negation
}
```

## Table-Driven Tests

The most common test pattern — testing a function with many inputs — is a
first-class language construct. Use `for` with named cases separated by `::`:

```run
test "add" for [
    "positive"    :: { a: 2,  b: 3,  want: 5   },
    "negative"    :: { a: -1, b: -2, want: -3   },
    "zeros"       :: { a: 0,  b: 0,  want: 0    },
    "mixed signs" :: { a: -3, b: 7,  want: 4    },
] (t) {
    t.expect(add(row.a, row.b), t.eq(row.want))
}
```

Each case runs as a separate subtest. The string before `::` is the case name,
the struct after `::` is the test data accessed via `row`:

```run
test "parseInt" for [
    "simple"     :: { input: "42",   want: 42 },
    "negative"   :: { input: "-7",   want: -7 },
    "whitespace" :: { input: " 12 ", want: 12 },
] (t) {
    result := try parseInt(row.input)
    t.expect(result, t.eq(row.want))
}
```

For concise access to row fields, use destructuring with `as`:

```run
test "add" for [
    "positive" :: { a: 2, b: 3, want: 5 },
    "zeros"    :: { a: 0, b: 0, want: 0 },
] as { a, b, want } (t) {
    t.expect(add(a, b), t.eq(want))
}
```

## Subtests

For dynamic or conditional subtests, use `t.run`:

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

## Fuzzing

Fuzz tests exercise your code with random inputs:

```run
test "json roundtrip" fuzz(data []byte) (t) {
    parsed := parseJson(data) or return
    output := toJson(parsed)
    reparsed := try parseJson(output)
    t.expect(reparsed, t.eq(parsed))
}
```

Provide seed inputs for deterministic coverage:

```run
test "parseInt never panics" fuzz(input string) seed [
    "0", "-1", "999999999", "", "abc",
] (t) {
    _ = parseInt(input)
}
```

Run fuzz tests with `run test -fuzz "json" -fuzz-time 30s`.

## Benchmarks

Use `bench` blocks to measure performance:

```run
bench "sort 1000 elements" (b) {
    data := generateRandomSlice(1000)
    b.resetTimer()
    for _ in 0..b.n {
        sort(data)
    }
}
```

Table-driven benchmarks compare different sizes:

```run
bench "sort" for [
    "10 elements"   :: { size: 10    },
    "100 elements"  :: { size: 100   },
    "1000 elements" :: { size: 1000  },
] (b) {
    data := generateRandomSlice(row.size)
    b.resetTimer()
    for _ in 0..b.n {
        sort(data)
    }
}
```

Run benchmarks with `run test -bench`.

## Lifecycle Hooks

Setup and teardown for test files:

```run
test beforeEach {
    try resetState()
}

test afterEach {
    try cleanup()
}
```

`beforeAll` / `afterAll` run once per file. `beforeEach` / `afterEach`
run around every test.

## Parallel Tests

Mark tests as safe to run concurrently:

```run
test "independent operation" (t) {
    t.parallel()
    result := try expensiveComputation()
    t.expect(result, t.eq(expected))
}
```

## Running Tests

```
run test                     # all tests
run test math                # tests in math package
run test -f "parse"          # filter by name
run test -v                  # verbose output
run test -bench              # include benchmarks
run test -fuzz "json"        # run fuzz tests
run test -shuffle            # randomize order
run test -cover              # show coverage
```

## Test Organization

Tests live alongside the code they test. For large test suites, use
separate `_test.run` files:

```
math/
    vector.run          // code + tests
    matrix.run          // code + tests
    matrix_test.run     // additional tests (optional)
```

`_test.run` files are in the same package and can access private members.
All test code is stripped from production builds.
