---
title: "Slices and Arrays"
sidebar:
  order: 14
---

## Arrays

Arrays have a fixed size known at compile time.

```go
let numbers [5]int = [5]int{1, 2, 3, 4, 5}
fmt.println(numbers[0]) // 1
```

## Slices

Slices are dynamically-sized views into arrays. They are the most common way to work with sequences in Run.

```go
package main

use "fmt"

pub fun main() {
    names := []string{"Alice", "Bob", "Charlie"}

    for name in names {
        fmt.println(name)
    }

    fmt.println(names[1]) // Bob
}
```

Slices, arrays, channels, and maps are built-in types with language-level support. No generics are needed to use them.
