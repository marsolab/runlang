# Interfaces

Interfaces define a set of methods that a type must implement. Interface implementations in Run are explicit — you must declare which interfaces a struct implements inside its definition.

```run
package main

use "fmt"

pub type Stringer interface {
    string() string
}

pub type Writer interface {
    write(p []byte) !int
}

pub type Point struct {
    implements (
        Stringer,
        Writer,
    )

    x: f64
    y: f64
}

fun (p @Point) string() string {
    return fmt.sprintf("(%f, %f)", p.x, p.y)
}

fun print_it(s: Stringer) {
    fmt.println(s.string())
}

pub fun main() {
    p := Point{ x: 1.0, y: 2.0 }
    print_it(p)
}
```

## Key points

- Interfaces require an explicit `implements` block inside the struct — they are not satisfied implicitly.
- No operator overloading is allowed through interfaces.
- A type can implement multiple interfaces.
