---
title: "Index Iteration"
sidebar:
  order: 30
---


When iterating over a collection, you often need the index alongside the value. Run supports this with a two-variable `for` loop.

```go
package main

use "fmt"

pub fun main() {
    names := []string{"Alice", "Bob", "Charlie"}

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

```go
package main

use "fmt"

pub fun main() {
    scores := []int{85, 92, 78, 95, 88}

    var best_index int = 0
    var best_score int = scores[0]

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

```go
package main

use "fmt"

pub fun main() {
    ages := map[string]int{
        "Alice": 30,
        "Bob": 25,
    }

    for key, value in ages {
        fmt.println(key, "is", value)
    }
}
```
