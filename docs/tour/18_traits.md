# Traits

Traits define a set of methods that a type must implement. Unlike Go interfaces, trait implementations in Run are explicit — you must declare `impl Trait for Type`.

```run
package main

use "fmt"

trait Stringer {
    fn string(self: @Self) string
}

pub struct Point {
    x: f64
    y: f64
}

impl Stringer for Point {
    fn string(self: @Point) string {
        return fmt.sprintf("(%f, %f)", self.x, self.y)
    }
}

fn print_it(s: Stringer) {
    fmt.println(s.string())
}

fn main() {
    p := Point{ x: 1.0, y: 2.0 }
    print_it(p)
}
```

## Key differences from Go interfaces

- Traits require an explicit `impl` block — they are not satisfied implicitly.
- No operator overloading is allowed through traits.
- A type can implement multiple traits.
