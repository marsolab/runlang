# Testing

Run has first-class testing built into the language with the `test` keyword. Tests are
expressive, table-driven tests are a language construct, and fuzzing is built in.

## Writing Tests

A test is a `test` block with a string description:

```run
package math

fun add(a int, b int) int {
    return a + b
}

test "add returns correct sums" {
    expect_eq(add(2, 3), 5)
    expect_eq(add(-1, 1), 0)
    expect_eq(add(0, 0), 0)
}
```

No naming conventions or function signatures to remember. The string description
appears directly in test output.

## Assertions

Assertions are built-in functions available inside `test` blocks. They produce
clear failure messages with source location and actual vs expected values:

```run
test "assertions" {
    expect(len(items) > 0)           // condition check
    expect_eq(got, want)             // equality with diff
    expect_ne(a, b)                  // inequality
    expect_err(parse("???"))         // expects an error
    expect_ok(parse("42"))           // expects success
    expect_nil(optional_value)       // expects null
    expect_not_nil(result)           // expects non-null
    expect_contains(body, "hello")   // substring check
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
] {
    expect_eq(add(row.a, row.b), row.want)
}
```

Each case runs as a separate subtest. The string before `::` is the case name
(shown in output), the struct after `::` is the test data (accessed via `row`):

```run
test "parse_int" for [
    "simple"     :: { input: "42",   want: 42 },
    "negative"   :: { input: "-7",   want: -7 },
    "whitespace" :: { input: " 12 ", want: 12 },
] {
    result := try parse_int(row.input)
    expect_eq(result, row.want)
}
```

For concise access to row fields, use destructuring with `as`:

```run
test "add" for [
    "positive" :: { a: 2, b: 3, want: 5 },
    "zeros"    :: { a: 0, b: 0, want: 0 },
] as { a, b, want } {
    expect_eq(add(a, b), want)
}
```

## Subtests

For dynamic or conditional subtests, use `t.run`:

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

## Fuzzing

Fuzz tests are declared with `fuzz` and exercise your code with random inputs:

```run
test "json roundtrip" fuzz(data []byte) {
    parsed := parse_json(data) or return
    output := to_json(parsed)
    reparsed := try parse_json(output)
    expect_eq(parsed, reparsed)
}
```

Provide seed inputs for deterministic coverage:

```run
test "parse_int never panics" fuzz(input string) seed [
    "0", "-1", "999999999", "", "abc",
] {
    _ = parse_int(input)
}
```

Run fuzz tests with `run test -fuzz "json" -fuzz-time 30s`.

## Benchmarks

Use `bench` blocks to measure performance:

```run
bench "sort 1000 elements" {
    data := generate_random_slice(1000)
    b.reset_timer()
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
] {
    data := generate_random_slice(row.size)
    b.reset_timer()
    for _ in 0..b.n {
        sort(data)
    }
}
```

Run benchmarks with `run test -bench`.

## Lifecycle Hooks

Setup and teardown for test files:

```run
test before_each {
    try reset_state()
}

test after_each {
    try cleanup()
}
```

`before_all` / `after_all` run once per file. `before_each` / `after_each`
run around every test.

## Parallel Tests

Mark tests as safe to run concurrently:

```run
test "independent operation" {
    t.parallel()
    // This test runs in parallel with other parallel-marked tests
    result := try expensive_computation()
    expect_eq(result, expected)
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
