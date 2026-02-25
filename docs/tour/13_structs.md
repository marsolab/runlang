# Structs

Structs are the primary way to define custom data types in Run.

```run
package main

use "fmt"

pub struct Point {
    x: f64
    y: f64
}

fn main() {
    p := Point{ x: 3.0, y: 4.0 }
    fmt.println(p.x)
    fmt.println(p.y)
}
```

## Field access

Struct fields are accessed using dot notation.

```run
p := Point{ x: 1.0, y: 2.0 }
p.x = 5.0
fmt.println(p.x) // 5.0
```

## Visibility

Structs can be made public with `pub`. Field visibility follows the same rules — fields are private by default within the struct's package.

```run
pub struct Config {
    pub host: string
    pub port: int
    secret: string  // private to this package
}
```

Methods are declared separately from structs and are covered in a later chapter.
