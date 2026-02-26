# Sum Types

Sum types (also called tagged unions or enums with data) let you define a type that can be one of several variants. Each variant can optionally carry associated data.

```run
package main

use "fmt"

type Color = .red | .green | .blue | .custom(int)

fun color_name(c: Color) string {
    switch c {
        .red :: return "red",
        .green :: return "green",
        .blue :: return "blue",
        .custom(val) :: return fmt.sprintf("custom(%d)", val),
    }
}

fun main() {
    c := Color.red
    fmt.println(color_name(c))

    custom := Color.custom(0xFF00FF)
    fmt.println(color_name(custom))
}
```

## Exhaustive matching

When you `switch` on a sum type, the compiler checks that every variant is handled. If you miss a case, the program will not compile. This prevents bugs from unhandled states.

```run
type State = .loading | .ready(Data) | .error(string)

fun handle(s: State) {
    switch s {
        .loading :: fmt.println("loading..."),
        .ready(data) :: process(data),
        .error(msg) :: fmt.println(msg),
    }
}
```
