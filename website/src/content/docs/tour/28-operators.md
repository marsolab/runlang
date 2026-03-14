---
title: "Operators"
sidebar:
  order: 28
---


Run provides the standard set of operators for arithmetic, comparison, and logic.

## Arithmetic operators

```go
package main

use "fmt"

pub fun main() {
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

```go
package main

use "fmt"

pub fun main() {
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

```go
package main

use "fmt"

pub fun main() {
    a := true
    b := false

    fmt.println(a and b)  // false
    fmt.println(a or b)   // true
    fmt.println(not a)    // false
}
```

## Assignment operators

Run supports compound assignment for convenience.

```go
var x int = 10
x += 5   // x is now 15
x -= 3   // x is now 12
x *= 2   // x is now 24
x /= 4   // x is now 6
x %= 5   // x is now 1
```

## Bitwise operators

Bitwise operators work on integers and are often used with bit masks.

```go
package main

use "fmt"

pub fun main() {
    a := 60  // 0011 1100
    b := 13  // 0000 1101

    fmt.println(a & b)   // 12  0000 1100  bitwise AND
    fmt.println(a | b)   // 61  0011 1101  bitwise OR
    fmt.println(a ^ b)   // 49  0011 0001  bitwise XOR
    fmt.println(~a)       // bitwise NOT
}
```

## Shift operators

Shift operators move bits left or right.

```go
package main

use "fmt"

pub fun main() {
    // Shift operators
    let a = 1 << 4   // 16
    let b = 16 >> 2  // 4

    fmt.println(a)
    fmt.println(b)
}
```
