---
title: "Immutable Variables"
sidebar:
  order: 6
---

Immutable variables are declared with the `let` keyword. They must be assigned a value and cannot be reassigned.

```go
package main

use "fmt"

let pi f64 = 3.14159
let max_size int = 1024
let greeting string = "Hello"

pub fun main() {
    fmt.println(pi)
    fmt.println(max_size)
    fmt.println(greeting)
}
```

The compiler enforces immutability — any attempt to reassign a `let` variable is a compile-time error. The error message points to the original declaration and suggests using `var` if reassignment is needed. Use `let` when a value should never change, and `var` when it needs to be updated.

:::note[Coming from other languages?]
If you're used to `const` from JavaScript or C++, Run uses `let` for immutable bindings. The compiler will suggest this if you accidentally type `const`.
:::
