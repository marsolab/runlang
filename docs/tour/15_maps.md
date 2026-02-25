# Maps

Maps are unordered collections of key-value pairs. They are a built-in type in Run.

```run
package main

use "fmt"

fn main() {
    ages := map[string]int{
        "Alice": 30,
        "Bob": 25,
    }

    fmt.println(ages["Alice"]) // 30

    ages["Charlie"] = 35
    fmt.println(ages["Charlie"]) // 35
}
```

Maps, like slices and channels, have language-level support and do not require generics.
