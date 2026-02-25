# Interfaces

Interfaces define a set of methods that a type must implement. Interface implementations in Run are explicit — you must declare which interfaces a struct implements inside its definition.

```run
package main

use "fmt"

interface Stringer {
    fn string() string
}

pub Point struct {
    implements {
        Stringer
    }

    x: f64
    y: f64
}

fn (self: @Point) string() string {
    return fmt.sprintf("(%f, %f)", self.x, self.y)
}

fn print_it(s: Stringer) {
    fmt.println(s.string())
}

fn main() {
    p := Point{ x: 1.0, y: 2.0 }
    print_it(p)
}
```

## Key points

- Interfaces require an explicit `implements` block inside the struct — they are not satisfied implicitly.
- No operator overloading is allowed through interfaces.
- A type can implement multiple interfaces.
