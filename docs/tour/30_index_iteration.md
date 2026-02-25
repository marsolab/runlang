# Index Iteration

When iterating over a collection, you often need the index alongside the value. Run supports this with a two-variable `for` loop.

```run
package main

use "fmt"

fn main() {
    names := ["Alice", "Bob", "Charlie"]

    for i, name in names {
        fmt.println(i, name)
    }
    // 0 Alice
    // 1 Bob
    // 2 Charlie
}
```

## When to use it

Index iteration is useful when the position of an element matters — for example, when building output, searching for an item's position, or processing parallel collections.

```run
package main

use "fmt"

fn main() {
    scores := [85, 92, 78, 95, 88]

    let best_index int = 0
    let best_score int = scores[0]

    for i, score in scores {
        if score > best_score {
            best_score = score
            best_index = i
        }
    }

    fmt.println("highest score:", best_score, "at index", best_index)
}
```

## Iterating maps

When iterating over a map, you receive the key and value.

```run
package main

use "fmt"

fn main() {
    ages := map[str]int{
        "Alice": 30,
        "Bob": 25,
    }

    for key, value in ages {
        fmt.println(key, "is", value)
    }
}
```
