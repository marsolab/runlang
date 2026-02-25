# Compile-Time Immutability

Run does not have a separate `const` keyword. Instead, the compiler analyzes every variable declared with `let` (or `:=`) and determines at compile time whether it is ever reassigned.

```run
package main

use "fmt"

let pi f64 = 3.14159
let max_size int = 1024
let greeting str = "Hello"

fn main() {
    fmt.println(pi)
    fmt.println(max_size)
    fmt.println(greeting)
}
```

Since `pi`, `max_size`, and `greeting` are never reassigned, the compiler treats them as immutable and can optimize them as constants. If you later add code that reassigns one of these variables, the compiler will allow it — immutability is inferred, not declared.
