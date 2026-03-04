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

pub fun main() {
    switch read_config("config.txt") {
        .ok(content) :: fmt.println(content),
        .err(e) :: fmt.println("failed to read config"),
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
    .ok(val) :: use(val),
    .err(e) :: log(e),
}
```

This approach makes error paths visible and forces you to handle them — errors cannot be silently ignored.

## Adding context to errors

When propagating errors with `try`, you can attach a context message using `::`. This helps trace where errors originated as they bubble up through function calls.

```run
fun load_config(path: string) !Config {
    content := try read_file(path) :: "reading config file"
    return try parse_config(content) :: "parsing config"
}
```

If `read_file` fails, the error carries the context `"reading config file"` along with it. As the error propagates further up the call stack, each `try` with `::` adds another layer of context, building a trace:

```
error: not_found
  reading config file (config.run:2)
  initializing app (main.run:10)
```

Context is optional — plain `try` still works exactly as before.
