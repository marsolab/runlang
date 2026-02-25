# Closures

Functions in Run are first-class values. They can be assigned to variables, passed as arguments, and returned from other functions.

```run
package main

use "fmt"

fn apply(x: int, f: fn(int) int) int {
    return f(x)
}

fn main() {
    double := fn(x: int) int { return x * 2 }
    fmt.println(apply(5, double)) // 10
}
```

## Capturing variables

Closures capture variables from their enclosing scope.

```run
package main

use "fmt"

fn make_counter() fn() int {
    let count int = 0
    return fn() int {
        count = count + 1
        return count
    }
}

fn main() {
    counter := make_counter()
    fmt.println(counter()) // 1
    fmt.println(counter()) // 2
    fmt.println(counter()) // 3
}
```

Each call to `make_counter` creates a new independent counter with its own `count` variable.
