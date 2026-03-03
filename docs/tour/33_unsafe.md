# Unsafe

Run is safe by default, but sometimes you need shared mutable state between concurrent tasks for performance. When channels aren't fast enough, you reach for mutexes, atomics, and shared memory — and any engineer knows these are inherently dangerous.

Run doesn't wrap this in block syntax like Rust. Instead, it takes the Go approach: `import unsafe` is a file-level declaration that enables shared memory operations. The import itself is the signal.

## import unsafe

Any file that uses synchronization primitives or shared memory must declare `import unsafe` alongside its other imports:

```run
package main

import "fmt"
import "sync"
import unsafe

fun main() {
    var counter int = 0
    var mu sync.Mutex

    for i in 0..10 {
        run fun() {
            mu.lock()
            counter = counter + 1
            mu.unlock()
        }
    }

    mu.lock()
    fmt.println("counter:", counter)
    mu.unlock()
}
```

No curly braces around every critical section. No visual noise. The `import unsafe` at the top tells you everything you need to know: this file does concurrent shared-memory operations.

## Why this approach?

Engineers already understand that mutexes and shared memory can shoot you in the foot — you don't need the language to remind you on every line. What matters is:

1. **Auditability** — `grep "import unsafe"` finds every file in your project that touches shared state. Code review can prioritize these files.
2. **Low ceremony** — No syntactic overhead around individual lock/unlock pairs. The code reads like normal code.
3. **Compiler enforcement** — Using sync primitives without `import unsafe` is a compile error. You can't accidentally use shared memory.

## Guidelines

- Prefer channels over shared memory when performance allows
- Keep files that `import unsafe` focused and small
- Always protect shared state with synchronization primitives like `sync.Mutex`
- Use `import unsafe` as a signal to reviewers: this file needs extra scrutiny
