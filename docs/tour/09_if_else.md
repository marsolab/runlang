# If / Else

Run's `if` statements do not require parentheses around the condition, but braces are always required.

```run
package main

use "fmt"

fun main() {
    x := 42

    if x > 0 {
        fmt.println("positive")
    } else if x < 0 {
        fmt.println("negative")
    } else {
        fmt.println("zero")
    }
}
```

## If with short declaration

You can use a short declaration (`:=`) right before the `if` condition to declare a variable scoped to the `if`/`else` chain. This is useful when you need a value only for the duration of a check.

```run
package main

use "fmt"
use "math"

fun main() {
    // v is declared and used within the if/else chain
    if v := math.pow(2, 10); v < 1000 {
        fmt.println("small:", v)
    } else {
        fmt.println("large:", v)
    }

    // v is not accessible here
}
```

The short declaration keeps temporary variables out of the surrounding scope. This is especially handy when working with error-returning functions:

```run
if data := try read_file("config.txt"); data != null {
    process(data)
} else {
    fmt.println("no config found")
}
```

## Ternary if

For simple conditional values, use the ternary form with `::` to pick between two expressions on a single line.

```run
package main

use "fmt"

fun main() {
    x := 10

    label := if x > 0 :: "positive" else "non-positive"
    fmt.println(label)

    // Works inline in any expression
    fmt.println("abs:", if x < 0 :: -x else x)
}
```

The ternary form is `if <condition> :: <then_value> else <else_value>`. Both branches are required. Use block `if`/`else` for multi-line logic; use the ternary form when you just need to pick a value.
