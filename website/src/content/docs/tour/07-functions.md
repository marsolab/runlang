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
