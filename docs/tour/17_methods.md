# Methods

In Run, methods are declared separately from structs using receiver syntax. This is similar to Go — the struct definition contains only data, and methods are defined alongside it.

```run
package main

use "fmt"

pub Rectangle struct {
    width: f64
    height: f64
}

fun Rectangle.area(self: @Rectangle) f64 {
    return self.width * self.height
}

fun Rectangle.scale(self: &Rectangle, factor: f64) {
    self.width = self.width * factor
    self.height = self.height * factor
}

fun main() {
    var r := Rectangle{ width: 3.0, height: 4.0 }
    fmt.println(r.area()) // 12.0

    r.scale(2.0)
    fmt.println(r.area()) // 48.0
}
```

## Receiver types

- `@Rectangle` — a read-only receiver. The method can read but not modify the struct.
- `&Rectangle` — a read/write receiver. The method can modify the struct's fields.

Choose `@T` when the method only observes the value, and `&T` when it needs to mutate it.
