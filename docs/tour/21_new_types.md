# Newtypes

The `type` keyword creates a distinct type from an existing one. Unlike a type alias, a newtype is not interchangeable with its underlying type — the compiler treats them as different types.

```run
package main

use "fmt"

type Celsius = f64
type Fahrenheit = f64

fun toFahrenheit(c: Celsius) Fahrenheit {
    return Fahrenheit(f64(c) * 9.0 / 5.0 + 32.0)
}

pub fun main() {
    temp := Celsius(100.0)
    fmt.println(toFahrenheit(temp))

    // let f Fahrenheit = temp  // error: type mismatch
}
```

New types are useful for preventing accidental misuse of values that share the same underlying representation but have different meanings — like mixing up meters and feet, or user IDs and order IDs.
