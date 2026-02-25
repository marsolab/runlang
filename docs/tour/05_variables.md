# Variables

Run has two keywords for declaring variables: `var` for mutable bindings and `let` for immutable bindings.

## Mutable variables with `var`

Use `var` to declare a variable that can be reassigned. Variables declared without an initializer are zero-initialized.

```run
var x int        // x is 0
var y f64        // y is 0.0
var z bool       // z is false
var s str        // s is ""
```

You can also provide an initial value:

```run
var x int = 42
var name str = "Run"
```

## Immutable variables with `let`

Use `let` to declare a variable that cannot be reassigned. An initializer is required — the value is fixed once set.

```run
let pi f64 = 3.14159
let name str = "Run"
let x = 42         // type inferred
```

Attempting to reassign a `let` variable is a compile-time error.

## Short declarations

The `:=` operator declares a mutable variable and infers its type from the right-hand side.

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

Short declarations are the most common way to declare variables in Run. They are equivalent to `var` with type inference.

## Zero values

Variables declared with `var` without an explicit initial value are given their zero value:

- `0` for numeric types
- `false` for `bool`
- `""` for `str`
- `null` for nullable types
