# Nullable Types

By default, values in Run cannot be `null`. To allow a value to be absent, use the `?` suffix to create a nullable type.

```run
package main

use "fmt"

fun find(names: []string, target: string) int? {
    for i, name in names {
        if name == target {
            return i
        }
    }
    return null
}

pub fun main() {
    names := []string{"Alice", "Bob", "Charlie"}

    switch find(names, "Bob") {
        .some(i) :: fmt.println("found at index", i),
        .null :: fmt.println("not found"),
    }
}
```

## Null safety

The compiler enforces null checks at compile time. You cannot use a nullable value without first checking whether it is `null`. This eliminates null pointer errors at runtime.

```run
var x int? = null

// x + 1    // error: cannot use nullable value directly

switch x {
    .some(val) :: fmt.println(val + 1),
    .null :: fmt.println("no value"),
}
```
