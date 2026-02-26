# Functions

Functions are declared with the `fun` keyword. Parameters use `name: type` syntax, and the return type follows the parameter list.

```run
package main

use "fmt"

fun add(a: int, b: int) int {
    return a + b
}

fun main() {
    result := add(3, 4)
    fmt.println(result)
}
```

## Visibility

Functions are private by default. Use `pub` to make a function accessible from other packages.

```run
pub fun add(a: int, b: int) int {
    return a + b
}

fun helper() {
    // only visible within this package
}
```

## No return value

Functions that do not return a value simply omit the return type.

```run
fun greet(name: string) {
    fmt.println("Hello, " + name)
}
```
