# Constants

Constants are declared with the `const` keyword. They must be assigned a value at compile time and cannot be changed.

```run
package main

use "fmt"

const pi f64 = 3.14159
const max_size int = 1024
const greeting str = "Hello"

fn main() {
    fmt.println(pi)
    fmt.println(max_size)
    fmt.println(greeting)
}
```

Unlike variables, constants require both a type and a value at the point of declaration.
