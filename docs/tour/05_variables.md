# Variables

Run provides several ways to declare variables.

## The `var` keyword

Use `var` to declare a variable with an explicit type. Variables declared with `var` are zero-initialized by default.

```run
var x int        // x is 0
var y f64        // y is 0.0
var z bool       // z is false
var s string        // s is ""
```

You can also provide an initial value:

```run
var x int = 42
var name string = "Run"
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

## Zero values

Variables declared without an explicit initial value are given their zero value:

- `0` for numeric types
- `false` for `bool`
- `""` for `string`
- `null` for nullable types
