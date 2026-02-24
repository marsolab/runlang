# If / Else

Run's `if` statements do not require parentheses around the condition, but braces are always required.

```run
package main

use "fmt"

fn main() {
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

You can include a short variable declaration before the condition. The variable is scoped to the `if` block.

```run
package main

use "fmt"

fn abs(x: int) int {
    if x < 0 {
        return -x
    }
    return x
}

fn main() {
    fmt.println(abs(-7))
    fmt.println(abs(3))
}
```
