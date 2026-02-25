# Unsafe Blocks

Run is safe by default, but sometimes you need to bypass safety checks for performance-critical code. The `unsafe` keyword marks regions where the compiler's safety guarantees are relaxed.

## Shared memory

The primary use of `unsafe` in Run is for shared mutable state between concurrent tasks. Normally, concurrency in Run uses channels for communication. When you need shared memory instead, you must be explicit about it.

```run
package main

use "fmt"
use "sync"

fn main() {
    let counter int = 0
    let mu sync.Mutex

    for i in 0..10 {
        run fn() {
            unsafe {
                mu.lock()
                counter = counter + 1
                mu.unlock()
            }
        }
    }

    // wait for tasks to finish
    unsafe {
        mu.lock()
        fmt.println("counter:", counter)
        mu.unlock()
    }
}
```

## Why unsafe?

The `unsafe` block serves as documentation and a search target. When something goes wrong with concurrent code, you know exactly where to look. It also signals to other developers that extra care is needed when modifying this section.

## Guidelines

- Keep `unsafe` blocks as small as possible
- Prefer channels over shared memory when performance allows
- Always protect shared state with synchronization primitives like `sync.Mutex`
- Comment why the `unsafe` block is necessary
