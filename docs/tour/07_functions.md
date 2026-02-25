# Functions

Functions are declared with the `fn` keyword. Parameters use `name: type` syntax, and the return type follows the parameter list.

```run
package main

use "fmt"

fn add(a: int, b: int) int {
    return a + b
}

fn main() {
    result := add(3, 4)
    fmt.println(result)
}
```

## Visibility

Functions are private by default. Use `pub` to make a function accessible from other packages.

```run
pub fn add(a: int, b: int) int {
    return a + b
}

fn helper() {
    // only visible within this package
}
```

## No return value

Functions that do not return a value simply omit the return type.

```run
fn greet(name: string) {
    fmt.println("Hello, " + name)
}
```
