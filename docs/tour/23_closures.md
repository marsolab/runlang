# Closures

Functions in Run are first-class values. They can be assigned to variables, passed as arguments, and returned from other functions.

```run
package main

use "fmt"

fun apply(x: int, f: fun(int) int) int {
    return f(x)
}

fun main() {
    double := fun(x: int) int { return x * 2 }
    fmt.println(apply(5, double)) // 10
}
```

## Capturing variables

Closures capture variables from their enclosing scope.

```run
package main

use "fmt"

fun make_counter() fun() int {
    var count int = 0
    return fun() int {
        count = count + 1
        return count
    }
}

fun main() {
    counter := make_counter()
    fmt.println(counter()) // 1
    fmt.println(counter()) // 2
    fmt.println(counter()) // 3
}
```

Each call to `make_counter` creates a new independent counter with its own `count` variable.
