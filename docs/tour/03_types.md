# Type System

Run has a simple type system with the following built-in types:

## Integer types

- `int`  - platform-sized signed integer
- `uint` - platform-sized unsigned integer
- `i32`  - 32-bit signed integer
- `i64`  - 64-bit signed integer
- `u32`  - 32-bit unsigned integer
- `u64`  - 64-bit unsigned integer
- `byte` - alias for `u8`, a single byte

## Floating point types

- `f32` - 32-bit floating point number
- `f64` - 64-bit floating point number

## Other types

- `bool` - boolean value, `true` or `false`
- `str`  - UTF-8 encoded string

## Type inference

Run can infer the type of a variable from its initial value. You rarely need to write types explicitly when using short declarations.

```run
package main

use "fmt"

fn main() {
    x := 42          // int
    pi := 3.14159    // f64
    name := "Run"    // str
    active := true   // bool

    fmt.println(x)
    fmt.println(pi)
    fmt.println(name)
    fmt.println(active)
}
```

When you need a specific numeric type, use an explicit type annotation:

```run
let small: i32 = 100
let big: u64 = 1_000_000
let precise: f64 = 0.1
```
