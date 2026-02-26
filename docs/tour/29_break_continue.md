# Break and Continue

`break` exits a loop immediately. `continue` skips the rest of the current iteration and moves to the next one.

## Break

Use `break` to exit a loop early when a condition is met.

```run
package main

use "fmt"

fun main() {
    for i in 0..100 {
        if i > 4 {
            break
        }
        fmt.println(i)
    }
    // prints 0, 1, 2, 3, 4
}
```

## Continue

Use `continue` to skip the current iteration.

```run
package main

use "fmt"

fun main() {
    for i in 0..10 {
        if i % 2 == 0 {
            continue
        }
        fmt.println(i)
    }
    // prints 1, 3, 5, 7, 9
}
```

## Breaking out of nested loops

In nested loops, `break` and `continue` apply to the innermost loop. To break out of an outer loop, use a labeled loop.

```run
package main

use "fmt"

fun main() {
    outer: for i in 0..5 {
        for j in 0..5 {
            if i + j >= 4 {
                break :outer
            }
            fmt.println(i, j)
        }
    }
}
```

Labels give you precise control over which loop to break from or continue, avoiding the need for extra boolean flags.
