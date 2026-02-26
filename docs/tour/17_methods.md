# Methods

In Run, methods are functions with a **receiver** — declared outside the struct, just like in Go. The struct definition contains only data; methods are defined alongside it.

```run
package main

use "fmt"

pub Rectangle struct {
    width: f64
    height: f64
}

fun (r @Rectangle) area() f64 {
    return r.width * r.height
}

fun (r &Rectangle) scale(factor f64) {
    r.width = r.width * factor
    r.height = r.height * factor
}

fun main() {
    var r := Rectangle{ width: 3.0, height: 4.0 }
    fmt.println(r.area()) // 12.0

    r.scale(2.0)
    fmt.println(r.area()) // 48.0
}
```

## Receiver syntax

The receiver appears in parentheses between `fn`/`fun` and the method name:

```
fn (name Type) method_name(params) return_type { body }
```

This is the same pattern as Go's method declarations.

## Receiver types

- `@T` — read-only receiver. The method can read but not modify the struct.
- `&T` — read/write receiver. The method can modify the struct's fields.

Choose `@T` when the method only observes the value, and `&T` when it needs to mutate.

```run
// Read-only — cannot modify p
fun (p @Point) length() f64 {
    return math.sqrt(p.x * p.x + p.y * p.y)
}

// Read/write — can modify p
fun (p &Point) translate(dx f64, dy f64) {
    p.x = p.x + dx
    p.y = p.y + dy
}
```

## Public methods

Methods can be made public with `pub`, just like functions:

```run
pub fun (p @Point) distance(other @Point) f64 {
    dx := p.x - other.x
    dy := p.y - other.y
    return math.sqrt(dx * dx + dy * dy)
}
```

## Multiple methods

You can define any number of methods on the same type:

```run
pub Circle struct {
    radius: f64
}

fun (c @Circle) area() f64 {
    return 3.14159 * c.radius * c.radius
}

fun (c @Circle) circumference() f64 {
    return 2.0 * 3.14159 * c.radius
}

fun (c &Circle) grow(amount f64) {
    c.radius = c.radius + amount
}
```
