# Strings

Strings in Run are UTF-8 encoded byte sequences. The string type is `string`.

```run
package main

use "fmt"

fn main() {
    greeting := "Hello, Run!"
    fmt.println(greeting)
}
```

## Iteration

Iterating over a string yields characters (Unicode code points) by default.

### Character iteration (default)

Ranging over a string directly gives you one character per iteration. This handles multi-byte UTF-8 sequences correctly.

```run
for ch in greeting {
    fmt.println(ch)
}
```

### Byte iteration

Use `.bytes` to iterate over the raw bytes of a string instead.

```run
for b in greeting.bytes {
    fmt.println(b)
}
```

Byte iteration is faster but does not respect character boundaries — a multi-byte character will appear as multiple separate bytes.
