# Operators

Run provides the standard set of operators for arithmetic, comparison, and logic.

## Arithmetic operators

```run
package main

use "fmt"

fn main() {
    a := 10
    b := 3

    fmt.println(a + b)   // 13  addition
    fmt.println(a - b)   // 7   subtraction
    fmt.println(a * b)   // 30  multiplication
    fmt.println(a / b)   // 3   integer division
    fmt.println(a % b)   // 1   remainder
}
```

Integer division truncates toward zero. Use floating-point types when you need fractional results.

## Comparison operators

Comparisons return a `bool` value.

```run
package main

use "fmt"

fn main() {
    x := 5
    y := 10

    fmt.println(x == y)  // false  equal
    fmt.println(x != y)  // true   not equal
    fmt.println(x < y)   // true   less than
    fmt.println(x > y)   // false  greater than
    fmt.println(x <= y)  // true   less or equal
    fmt.println(x >= y)  // false  greater or equal
}
```

## Logical operators

Logical operators work on `bool` values and short-circuit.

```run
package main

use "fmt"

fn main() {
    a := true
    b := false

    fmt.println(a and b)  // false
    fmt.println(a or b)   // true
    fmt.println(not a)    // false
}
```

## Assignment operators

Run supports compound assignment for convenience.

```run
let x int = 10
x += 5   // x is now 15
x -= 3   // x is now 12
x *= 2   // x is now 24
x /= 4   // x is now 6
x %= 5   // x is now 1
```
