# Packages

In Run, packages are a way to organize your code into logical groups.

## Package main

Programs start their execution in package main.

By convention, the package name is the same as the last element of the import path. For instance, the "math/rand" package comprises files that begin with the statement `package rand`.

```run
package main

use "fmt"
use "math/rand"

fun main() {
    fmt.println("A random number:", rand.intn(100))
}
```

Each source file belongs to exactly one package. A directory of `.run` files forms a package — all files in the same directory share the same package name.
