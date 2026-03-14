---
title: "The unsafe Package"
sidebar:
  order: 33
---

Run is safe by default. Memory safety comes from generational references, concurrency safety comes from channels. But sometimes you need to go lower — raw pointer manipulation, type layout inspection, or shared memory with manual synchronization.

For that, there's the `unsafe` package. It's a standard library package, not a keyword or special syntax. Just like Go's `import "unsafe"`, importing it is the signal.

## Importing unsafe

```go
package main

use "fmt"
use "unsafe"

pub fun main() {
    var x int = 42
    var p unsafe.Pointer = unsafe.ptr(&x)
    fmt.println("size of int:", unsafe.sizeof(int))
    fmt.println("pointer:", p)
}
```

No block wrapping. No special keyword. `use "unsafe"` in a file tells you and your team: this file does low-level operations.

## What the package provides

```go
use "unsafe"

// Raw pointer type — can be converted to/from any &T or @T
var p unsafe.Pointer = unsafe.ptr(&my_value)

// Convert back to a typed pointer
var typed &int = unsafe.cast(&int, p)

// Type layout
var size int = unsafe.sizeof(MyStruct)
var align int = unsafe.alignof(MyStruct)
var off int = unsafe.offsetof(MyStruct, "field_name")

// Create a slice from a raw pointer and length
var s []byte = unsafe.slice(raw_ptr, 1024)
```

## Shared memory with sync

When you need shared mutable state between concurrent tasks, use `sync` primitives directly. Engineers know mutexes are dangerous — the language doesn't need to remind you on every line.

```go
package main

use "fmt"
use "sync"

pub fun main() {
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

## Guidelines

- Prefer channels over shared memory when performance allows
- Keep files that import `unsafe` focused and small
- `grep "unsafe"` across your project to audit all low-level code
- The package is for escaping safety guarantees, not for everyday code
