# Testing

Run has a built-in testing framework in the `testing` standard library package. Tests live alongside the code they test.

## Writing tests

A test is a function that takes a `testing.T` parameter. Use `t.expect` to assert conditions.

```run
package math

use "testing"

fn add(a: int, b: int) int {
    return a + b
}

fn test_add(t: &testing.T) {
    t.expect(add(2, 3) == 5)
    t.expect(add(-1, 1) == 0)
    t.expect(add(0, 0) == 0)
}
```

## Running tests

Run all tests in your project from the command line:

```
run test
```

To run tests in a specific package:

```
run test math
```

## Test organization

Tests are typically written in the same file as the code they test. This keeps tests close to the implementation and gives them access to private functions within the package.

```
math/
    vector.run        // contains Vec3 and its tests
    matrix.run        // contains Matrix and its tests
```

## Failing with a message

Use `t.fail` to report a failure with a descriptive message.

```run
fn test_divide(t: &testing.T) {
    result := divide(10, 3)
    if result != 3 {
        t.fail("expected 3, got", result)
    }
}
```

Writing tests from the start catches bugs early and gives you confidence to refactor. The `run test` command makes it easy to run them often.
