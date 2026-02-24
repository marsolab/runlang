# Strings

Strings in Run are UTF-8 encoded byte sequences. The string type is `str`.

```run
package main

use "fmt"

fn main() {
    greeting := "Hello, Run!"
    fmt.println(greeting)
}
```

## Iteration

Strings support two iteration modes.

### Byte iteration

Use `.bytes` to iterate over the raw bytes of a string.

```run
for b in greeting.bytes {
    fmt.println(b)
}
```

### Character iteration

Use `.chars` to iterate over Unicode characters (code points).

```run
for ch in greeting.chars {
    fmt.println(ch)
}
```

Character iteration handles multi-byte UTF-8 sequences correctly, making it the preferred way to process text.
