# Type Conversions

Run requires explicit conversions between types. There are no implicit coercions — even between numeric types of different sizes.

```run
package main

use "fmt"

fn main() {
    x := 42           // int
    y := f64(x)       // convert int to f64
    z := i32(x)       // convert int to i32

    fmt.println(y)    // 42.0
    fmt.println(z)    // 42
}
```

## Numeric conversions

You can convert between any numeric types using the target type as a function.

```run
package main

use "fmt"

fn main() {
    big := 100000
    small := i32(big)

    ratio := 3.7
    truncated := int(ratio)  // 3 — truncates toward zero

    fmt.println(small)
    fmt.println(truncated)
}
```

Be aware that converting from a larger type to a smaller one can lose information. Converting a float to an integer truncates the fractional part.

## Newtype conversions

Newtypes require explicit conversion to and from their underlying type:

```run
newtype Celsius f64

temp := Celsius(100.0)
raw := f64(temp)       // extract the underlying value
```

This explicitness prevents subtle bugs from accidental type mixing. If the compiler reports a type mismatch, an explicit conversion makes your intent clear.
