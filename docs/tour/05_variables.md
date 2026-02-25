# Variables

Run uses a single keyword — `let` — for all variable declarations. The compiler determines at compile time whether each variable is mutable or immutable by analyzing whether it is ever reassigned.

## The `let` keyword

Use `let` to declare a variable with an explicit type. Variables declared without an initializer are zero-initialized by default.

```run
let x int        // x is 0
let y f64        // y is 0.0
let z bool       // z is false
let s str        // s is ""
```

You can also provide an initial value:

```run
let x int = 42
let name str = "Run"
```

## Short declarations

The `:=` operator declares a variable and infers its type from the right-hand side.

```run
package main

use "fmt"

fn main() {
    x := 42
    name := "Run"
    pi := 3.14159

    fmt.println(x)
    fmt.println(name)
    fmt.println(pi)
}
```

Short declarations are the most common way to declare variables in Run. The compiler infers the type from the assigned value.

## Compile-time immutability

The compiler analyzes how each variable is used. If a variable is never reassigned after initialization, the compiler treats it as immutable and can optimize accordingly. If you later try to reassign a variable the compiler has determined to be immutable, it will produce an error.

## Zero values

Variables declared without an explicit initial value are given their zero value:

- `0` for numeric types
- `false` for `bool`
- `""` for `str`
- `null` for nullable types
