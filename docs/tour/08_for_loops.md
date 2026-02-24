# For loops

Run uses `for` as its only loop construct. It covers all common looping patterns.

## Infinite loop

A bare `for` loops forever. Use `break` to exit.

```run
for {
    // runs forever
    break
}
```

## Conditional loop

A `for` with a condition works like `while` in other languages.

```run
package main

use "fmt"

fn main() {
    x := 0
    for x < 10 {
        fmt.println(x)
        x = x + 1
    }
}
```

## Range loop

Use `in` with a range expression to iterate over a sequence of numbers.

```run
package main

use "fmt"

fn main() {
    for i in 0..5 {
        fmt.println(i) // prints 0, 1, 2, 3, 4
    }
}
```

## Iterator loop

Use `in` to iterate over any iterable value like slices or strings.

```run
package main

use "fmt"

fn main() {
    names := ["Alice", "Bob", "Charlie"]
    for name in names {
        fmt.println(name)
    }
}
```
