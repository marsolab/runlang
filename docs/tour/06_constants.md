# Immutable Variables

Immutable variables are declared with the `let` keyword. They must be assigned a value and cannot be reassigned.

```run
package main

use "fmt"

let pi f64 = 3.14159
let max_size int = 1024
let greeting str = "Hello"

fun main() {
    fmt.println(pi)
    fmt.println(max_size)
    fmt.println(greeting)
}
```

The compiler enforces immutability — any attempt to reassign a `let` variable is a compile-time error. Use `let` when a value should never change, and `var` when it needs to be updated.
