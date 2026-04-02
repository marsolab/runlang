---
title: "Variables"
sidebar:
  order: 5
---

Run has two keywords for declaring variables: `var` for mutable bindings and `let` for immutable bindings.

## Mutable variables with `var`

Use `var` to declare a variable that can be reassigned. Variables declared without an initializer are zero-initialized.

```go
var x int        // x is 0
var y f64        // y is 0.0
var z bool       // z is false
var s string        // s is ""
```

You can also provide an initial value:

```go
var x int = 42
var name string = "Run"
```

## Immutable variables with `let`

Use `let` to declare a variable that cannot be reassigned. An initializer is required — the value is fixed once set.

```go
let pi f64 = 3.14159
let name string = "Run"
let x = 42         // type inferred
```

Attempting to reassign a `let` variable is a compile-time error. The compiler shows where the variable was originally defined and suggests using `var` instead.

## Short declarations

The `:=` operator declares a mutable variable and infers its type from the right-hand side.

```go
package main

use "fmt"

pub fun main() {
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
- `""` for `string`
- `null` for nullable types
