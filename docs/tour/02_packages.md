# Packages

In Run, packages are a way to organize your code into logical groups.

## Package main

Programs start their execution in package main.

The package name should match the last element of the import path. For instance, the `math/rand` package comprises files that begin with `package rand`.

```run
package main

use "fmt"
use "math/rand"

pub fun main() {
    fmt.println("A random number:", rand.intn(100))
}
```

Each source file belongs to exactly one package and must begin with `package <name>`. A directory of `.run` files forms a package — all files in the same directory share the same package name.

If a file declares `package main`, it must include `pub fun main()` as the program entrypoint.
