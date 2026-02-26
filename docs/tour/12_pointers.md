# Pointers

Run has two pointer types that control access to the pointed-to value.

## Read/write pointers

`&T` is a read/write pointer. It allows both reading and modifying the pointed-to value.

```run
package main

use "fmt"

fun increment(p: &int) {
    p.* = p.* + 1
}

fun main() {
    var x int = 10
    increment(&x)
    fmt.println(x) // 11
}
```

## Read-only pointers

`@T` is a read-only pointer. It allows reading but not modifying the pointed-to value.

```run
fun print_value(p: @int) {
    fmt.println(p.*) // ok: reading
    // p.* = 42      // error: cannot write through read-only pointer
}
```

This distinction is enforced at compile time and helps express intent clearly — use `@T` when a function only needs to observe a value, and `&T` when it needs to modify it.
