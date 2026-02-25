# Error Sets

When a function returns `!T`, the set of errors it can produce is inferred by the compiler. You do not need to declare error types manually.

## Inferred error sets

The compiler analyzes your function and determines every error that can be returned, including errors propagated with `try`.

```run
package main

use "fmt"
use "os"

fn load_config(path: str) !str {
    file := try os.open(path)      // may return os.NotFound, os.Permission, ...
    defer file.close()
    content := try file.read_all() // may return io.ReadError, ...
    return content
}
```

The error set of `load_config` is the union of all errors from `os.open` and `file.read_all`. You never need to write this out — the compiler tracks it for you.

## Handling specific errors

When you need to react differently to specific errors, use `switch` to match on the error variant.

```run
package main

use "fmt"
use "os"

fn main() {
    switch os.open("config.txt") {
        .ok(file) => {
            defer file.close()
            fmt.println("opened successfully")
        },
        .err(.not_found) => fmt.println("file not found"),
        .err(.permission) => fmt.println("access denied"),
        .err(e) => fmt.println("unexpected error:", e),
    }
}
```

## Propagating errors with `try`

The `try` keyword unwraps a success value or immediately returns the error from the current function. This keeps the happy path clean and readable.

```run
fn process() !int {
    data := try read_file("input.txt")   // returns error if read fails
    parsed := try parse_int(data)         // returns error if parse fails
    return parsed * 2                     // only reached on success
}
```

Errors in Run are values, not exceptions. They flow through the return type, making every error path visible in the function signature.
