# Allocators

Run uses a default global allocator for heap allocations. For performance-critical or specialized use cases, `alloc` supports a named custom allocator argument.

## The default allocator

Most code uses the default allocator without thinking about it. Collection allocations can be explicit with `alloc(...)` and still default to the global allocator.

```run
package main

use "fmt"

pub fun main() {
    names := alloc([]string, 3)
    names = append(names, "Alice")
    names = append(names, "Bob")
    names = append(names, "Charlie")
    fmt.println(names[0])
}
```

## Custom allocators

When you need control over how memory is allocated — for example, using an arena for batch allocations or a pool for fixed-size objects — pass a named allocator argument to `alloc`: `allocator: your_allocator`.

```run
package main

use "fmt"
use "mem"

pub fun main() {
    arena := mem.arena_allocator(1024 * 1024)  // 1 MB arena
    defer arena.deinit()

    // allocations from the arena are freed all at once
    data := alloc([]byte, 256, allocator: arena)
    jobs := alloc(map[string]int, allocator: arena)
    queue := alloc(chan[string], 128, allocator: arena)
    process(data)
    _ = jobs
    _ = queue
}
```

## When to use custom allocators

- **Arena allocators** — for request-scoped or phase-scoped work where all allocations can be freed together
- **Pool allocators** — for many small, same-sized allocations
- **Tracking allocators** — for debugging memory usage during development

Most programs never need custom allocators. The default allocator works well for general use. Custom allocators are a tool for optimization once you understand your program's allocation patterns.

## Create your own allocator


Implement the `Allocator` interface to create a custom allocator.

```run
package main

use "fmt"
use "mem"

pub struct MyAllocator {
    implements {
        mem.Allocator
    }
    // ...
}

impl mem.Allocator for MyAllocator {
    pub fun alloc(size: int) -> *byte {
        // ...
    }

    pub fun free(ptr: *byte, size: int) {
        // ...
    }
}

pub fun main() {
    my_alloc := MyAllocator{}
    data := alloc([]byte, 1024, allocator: my_alloc)
    _ = data
}
```
