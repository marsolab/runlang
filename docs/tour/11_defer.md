# Defer

The `defer` statement schedules a call to run when the enclosing function returns. This is useful for cleanup actions like closing files or releasing resources.

```run
package main

use "fmt"
use "os"

fun main() {
    file := os.open("data.txt")
    defer file.close()

    // work with file...
    // file.close() is called automatically when main returns
}
```

## Multiple defers

When multiple `defer` statements are used, they execute in reverse order (last in, first out).

```run
package main

use "fmt"

fun main() {
    defer fmt.println("first")
    defer fmt.println("second")
    defer fmt.println("third")

    // Output:
    // third
    // second
    // first
}
```

Deferred calls are guaranteed to run even if the function returns early or encounters an error.
