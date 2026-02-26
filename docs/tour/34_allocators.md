# Allocators

Run uses a default global allocator for heap allocations. For performance-critical or specialized use cases, functions can accept an optional custom allocator.

## The default allocator

Most code uses the default allocator without thinking about it. Heap allocations — like creating structs with `&T` or growing slices — happen automatically.

```run
package main

use "fmt"

fun main() {
    names := ["Alice", "Bob", "Charlie"]  // allocated with the default allocator
    fmt.println(names[0])
}
```

## Custom allocators

When you need control over how memory is allocated — for example, using an arena for batch allocations or a pool for fixed-size objects — you can pass a custom allocator to functions that support it.

```run
package main

use "fmt"
use "mem"

fun main() {
    arena := mem.arena_allocator(1024 * 1024)  // 1 MB arena
    defer arena.deinit()

    // allocations from the arena are freed all at once
    data := make_buffer(arena, 256)
    process(data)
}
```

## When to use custom allocators

- **Arena allocators** — for request-scoped or phase-scoped work where all allocations can be freed together
- **Pool allocators** — for many small, same-sized allocations
- **Tracking allocators** — for debugging memory usage during development

Most programs never need custom allocators. The default allocator works well for general use. Custom allocators are a tool for optimization once you understand your program's allocation patterns.
