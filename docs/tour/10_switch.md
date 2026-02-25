# Switch

Run's `switch` is used for pattern matching. There is no fallthrough — only the matched branch executes.

```run
package main

use "fmt"

fn describe(x: int) string {
    switch x {
        1 => return "one",
        2 => return "two",
        3 => return "three",
        _ => return "other",
    }
}

fn main() {
    fmt.println(describe(2))
    fmt.println(describe(99))
}
```

The `_` pattern is a wildcard that matches anything. It is often used as a default case.

`switch` is also used for matching on sum types and error unions, which are covered in later chapters.
