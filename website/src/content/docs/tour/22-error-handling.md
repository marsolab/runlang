---
title: "Error Handling"
sidebar:
  order: 22
---

Run uses error unions for error handling, inspired by Zig. A function that can fail returns `!T` — either a value of type `T` or an error. A function that returns nothing but can fail uses bare `!`.

```go
package main

use "fmt"
use "os"

fun read_config(path: string) !string {
    file := try os.open(path)
    defer file.close()
    return try file.readAll()
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

```go
fun process() !int {
    data := try readFile("input.txt")
    result := try parse(data)
    return result
}
```

## Void error unions

When a function performs a side effect that can fail but has no return value, use bare `!`:

```go
fun save(path: string, data: string) ! {
    file := try os.create(path)
    defer file.close()
    try file.write(data)
}
```

The caller uses `try` or `switch` the same way — the `.ok` branch simply has no value:

```go
try save("output.txt", content)

switch save("output.txt", content) {
    .ok :: fmt.println("saved"),
    .err(e) :: fmt.println("write failed:", e),
}
```

## Matching on errors

Use `switch` to handle both success and error cases explicitly.

```go
switch do_work() {
    .ok(val) :: use(val),
    .err(e) :: log(e),
}
```

This approach makes error paths visible and forces you to handle them — errors cannot be silently ignored.

## Adding context to errors

When propagating errors with `try`, you can attach a context message using `::`. This helps trace where errors originated as they bubble up through function calls.

```go
fun load_config(path: string) !Config {
    content := try readFile(path) :: "reading config file"
    return try parse_config(content) :: "parsing config"
}
```

If `readFile` fails, the error carries the context `"reading config file"` along with it. As the error propagates further up the call stack, each `try` with `::` adds another layer of context, building a trace:

```
error: not_found
  reading config file (config.run:2)
  initializing app (main.run:10)
```

Context is optional — plain `try` still works exactly as before.
