# Error Handling

Run uses error unions for error handling, inspired by Zig. A function that can fail returns `!T` — either a value of type `T` or an error.

```run
package main

use "fmt"
use "os"

fun read_config(path: string) !string {
    file := try os.open(path)
    defer file.close()
    return try file.read_all()
}

fun main() {
    switch read_config("config.txt") {
        .ok(content) => fmt.println(content),
        .err(e) => fmt.println("failed to read config"),
    }
}
```

## The `try` keyword

Use `try` to propagate errors. If the expression returns an error, `try` immediately returns that error from the enclosing function. Otherwise, it unwraps the value.

```run
fun process() !int {
    data := try read_file("input.txt")
    result := try parse(data)
    return result
}
```

## Matching on errors

Use `switch` to handle both success and error cases explicitly.

```run
switch do_work() {
    .ok(val) => use(val),
    .err(e) => log(e),
}
```

This approach makes error paths visible and forces you to handle them — errors cannot be silently ignored.
