---
title: "Functions"
sidebar:
  order: 7
---

Functions are declared with the `fun` keyword. Parameters use `name: type` syntax, and the return type follows the parameter list.

```go
package main

use "fmt"

fun add(a: int, b: int) int {
    return a + b
}

pub fun main() {
    result := add(3, 4)
    fmt.println(result)
}
```

## Visibility

Functions are private by default. Use `pub` to make a function accessible from other packages.

```go
pub fun add(a: int, b: int) int {
    return a + b
}

fun helper() {
    // only visible within this package
}
```

## No return value

Functions that do not return a value simply omit the return type.

```go
fun greet(name: string) {
    fmt.println("Hello, " + name)
}
```

## Failable functions

A function that can fail returns `!T` — an error union. A function that returns nothing but can fail uses bare `!`:

```go
fun divide(a: int, b: int) !int {
    if b == 0 {
        return error.division_by_zero
    }
    return a / b
}

fun save(path: string, data: string) ! {
    file := try os.create(path)
    defer file.close()
    try file.write(data)
}
```

Error handling is covered in detail in the [Error Handling](/tour/22-error-handling) chapter.
