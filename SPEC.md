# Run Language Specification v0.1

## Philosophy

- **Go's simplicity** meets **systems-level control**
- Target audience: Go developers who want more control over memory and performance
- Core differentiator: **simplicity**
- Lower-level than high-level: suitable for OS/kernels and very fast web applications

## Memory Model

Run uses **generational references** (inspired by Vale) for memory safety without a
borrow checker or garbage collector.

- Every allocation carries a **generation number**
- Non-owning references store a **remembered generation**
- On dereference, a runtime generation check verifies the object is still alive
- Owning references auto-free when they go out of scope (deterministic destruction)
- Default global allocator; collection allocations can optionally specify a custom allocator
- No borrow checker, no GC, no reference counting

### Pointer Types

- `&T` — read/write pointer (default, Go-like semantics)
- `@T` — read-only pointer (compiler-enforced immutability on pointee)

### Allocation Expressions

Run provides a built-in `alloc` expression for collection and channel allocation:

```run
s := alloc([]int, 64)
m := alloc(map[string]string, 32)
c := alloc(chan[int])
```

Valid allocation targets are:
- slices (`[]T`)
- maps (`map[K]V`)
- channels (`chan T` or `chan[T]`)

`alloc` arguments:
- `alloc(type)` — use type defaults
- `alloc(type, capacity)` — set initial capacity/buffer
- `alloc(type, capacity, allocator: expr)` — custom allocator
- `alloc(type, allocator: expr)` — custom allocator with default capacity

Default behavior when capacity is omitted:
- slice: empty slice with capacity 0 (grows on append)
- map: map with runtime default buckets
- channel: unbuffered channel

Custom allocators in `alloc` are **named** via `allocator:` for readability and to avoid positional ambiguity.


## Variables

```
var a int           // mutable, zero-initialized
var a int = 32      // mutable, explicit type with initialization
a := 32             // mutable, short declaration with type inference
let a int = 32      // immutable, explicit type
let a = compute()   // immutable, type inference
```

- `var` — mutable binding, can be reassigned
- `let` — immutable binding, must be initialized, cannot be reassigned (compiler-enforced)
- `:=` — short declaration (mutable, equivalent to `var` with type inference)

## Packages and Imports

Every `.run` source file must begin with a package declaration:

```run
package main
```

`package main` is the executable entry package and must define `pub fun main`.

Imports use the `use` keyword:

```run
use "fmt"
use "math/rand"
```

`import` is not a language keyword.

## Functions

```
pub fun add(a int, b int) int {
    return a + b
}

fun private_helper(x int) int {
    return x * 2
}
```

- Zig-style signature: return type after parameters, no arrow
- `pub` keyword for public visibility, private by default
- Full closures supported: `fun(x int) int { return x + 1 }`

### Methods (Go-style Receivers)

Methods are functions with a **receiver** parameter, declared outside the struct:

```
fun (name ReceiverType) method_name(params) return_type { body }
```

The receiver appears in parentheses between `fun` and the method name — identical to Go's
method declaration syntax. Methods are not defined inside the struct body; the struct
contains only data.

```
pub type Point struct {
    x f64
    y f64
}

// Read-only receiver — cannot modify p
fun (p @Point) length() f64 {
    return math.sqrt(p.x * p.x + p.y * p.y)
}

// Read/write receiver — can modify p
fun (p &Point) translate(dx f64, dy f64) {
    p.x = p.x + dx
    p.y = p.y + dy
}
```

**Receiver types:**
- `&T` — read/write pointer receiver. The method can read and modify the struct.
- `@T` — read-only pointer receiver. Compiler-enforced immutability on the receiver.
- `T` — value receiver. The method receives a copy of the struct. Useful for small types where copying is cheaper than pointer indirection.

Methods can be made public with `pub`:

```
pub fun (p @Point) distance(other @Point) f64 {
    dx := p.x - other.x
    dy := p.y - other.y
    return math.sqrt(dx * dx + dy * dy)
}
```

The colon between receiver name and type is optional: `(p &Point)` and `(p: &Point)` are
both valid.

### Multiple Return Values

Functions can return multiple values using anonymous structs (Zig-style):

```
fun divmod(a int, b int) struct { quotient int, remainder int } {
    return .{ quotient: a / b, remainder: a % b }
}

// Caller accesses fields on the result:
result := divmod(10, 3)
result.quotient   // 3
result.remainder  // 1
```

- Anonymous struct types can be used anywhere a type is expected
- Anonymous struct literals use `.{ field: value }` syntax
- Fields can be separated by commas or newlines
- Works with error unions: `fun parse(s string) !struct { value int, rest string }`
- Works with pointers: `fun make() &struct { x int, y int }`

## Error Handling

Zig-style error unions. A function that can fail returns `!T`:

```
fun read_file(path string) !string {
    // returns string on success, error on failure
}

// Caller handles with try:
content := try read_file("config.txt")

// Or with switch:
switch read_file("config.txt") {
    .ok(content) :: use(content),
    .err(e) :: log(e),
}
```

- Error sets are **inferred by the compiler**
- No generics needed — `!T` is a built-in language construct

### Error Context

When propagating errors with `try`, you can attach context using `::`:

```
content := try read_file(path) :: "loading config"
```

If the expression returns an error, the context string is attached to the error
before it propagates. This builds a chain of context as errors bubble up through
the call stack, making it easy to trace the origin of failures.

Plain `try` (without context) still propagates errors unchanged.

## Type System

### Primitive Types

- **Integers**: `int`, `uint`, `i32`, `i64`, `u32`, `u64`, `byte`
- **Floats**: `f32`, `f64`
- **Boolean**: `bool`
- **String**: `string` — UTF-8 byte slice

### Strings

- UTF-8 encoded byte slices
- Default iteration yields characters (unicode codepoints):
  - `for c in s { }` — iterate over characters
  - `for b in s.bytes { }` — iterate over raw bytes

### Structs

```
pub type Point struct {
    x f64
    y f64
}
```

- Type declarations start with the `type` keyword, `pub` modifier for exported types
- Structs contain only data — no methods inside the body
- Methods are declared outside with a Go-style receiver (see **Methods** under Functions)

### Interfaces (Explicit)

```
pub type Stringer interface {
    fun to_string() string
}

pub type Point struct {
    implements(
        Stringer
    )

    x f64
    y f64
}

fun (p @Point) to_string() string {
    return fmt.sprintf("(%f, %f)", p.x, p.y)
}
```

- `interface` defines a set of method signatures (no receiver in signatures)
- Structs declare which interfaces they implement via an `implements` block
- Method implementations remain outside the struct with a receiver (Go-style)
- No operator overloading

### Sum Types / Tagged Unions

```
type State = .loading | .ready(Data) | .error(string)

switch state {
    .loading :: show_spinner(),
    .ready(data) :: render(data),
    .error(msg) :: show_error(msg),
}
```

- First-class pattern matching via `switch`

### Nullable Types

```
var x int? = null
var y int? = 42

switch x {
    .some(val) :: use(val),
    .null :: handle_missing(),
}
```

- Compile-time null safety (Kotlin-style)
- `Type?` denotes a nullable type
- Must handle null explicitly before use

### Newtype

```
type UserID = int    // distinct type, not an alias
type Email = string
```

- Creates a new type that is **not interchangeable** with the underlying type

## Control Flow

### For (unified loop)

```
for { }                          // infinite loop
for condition { }                // while loop
for i in 0..10 { }              // range iteration
for item in collection { }      // iterator
for i, item in collection { }   // index + value
```

- `break` and `continue` supported

### Switch (pattern matching)

```
switch value {
    1 :: do_one(),
    2, 3 :: do_two_or_three(),
    .variant(x) :: use(x),
    _ :: default(),
}
```

- No fallthrough
- Exhaustive matching on sum types

### Defer

```
fun process() !void {
    file := try os.open("data.txt")
    defer file.close()

    // file.close() runs when function exits
}
```

- Go-style defer for cleanup

## Concurrency

### Green Threads

```
run my_function()
run fun() { do_work() }
```

- `run` spawns a green thread (goroutine-style)
- Lightweight, multiplexed onto OS threads by runtime

### Channels

```
var ch chan int
ch := alloc(chan[int])      // unbuffered
ch := alloc(chan[int], 100) // buffered

ch <- 42                    // send
val := <-ch                 // receive
```

### The `unsafe` Package

The `unsafe` package is a standard library package providing low-level operations
that bypass Run's safety guarantees. Like Go's unsafe import convention, its presence in
a file's `use` declarations is the signal that dangerous operations are in use.

```
use "unsafe"

var p unsafe.Pointer = unsafe.ptr(&x)     // raw pointer
var n int = unsafe.sizeof(MyStruct)       // type size in bytes
var off int = unsafe.offsetof(MyStruct, "field")  // field byte offset
```

- `unsafe.Pointer` — raw pointer type, convertible to/from any `&T` or `@T`
- `unsafe.ptr(p)` — convert a typed pointer to `unsafe.Pointer`
- `unsafe.cast(&T, p)` — convert `unsafe.Pointer` back to a typed pointer
- `unsafe.sizeof(T)` — size of type `T` in bytes
- `unsafe.alignof(T)` — alignment of type `T`
- `unsafe.offsetof(T, field)` — byte offset of a field within a struct
- `unsafe.slice(p, len)` — create a slice from a raw pointer and length

No special keyword or block syntax — `use "unsafe"` is a regular use statement and
`grep "unsafe"` finds every file that uses low-level operations.

## Visibility and Modules

- **`pub`** keyword marks items as public; everything is **private by default**
- File = module, directory = package (Go-style)
- No semicolons; statements are newline-terminated

```
// math/vector.run
pub type Vec3 struct { x f64, y f64, z f64 }

// main.run
use "math"
v := math.Vec3{ x: 1.0, y: 2.0, z: 3.0 }
```

## No Generics

Deliberate choice for simplicity. Built-in types (slices, channels, maps) have
language-level support without requiring user-facing generics.

## Compilation

- Compiler written in **Zig**
- Native codegen via **Zig's own backend** (no LLVM dependency)
- File extension: `.run`

## Standard Library (Go-level comprehensive)

- `io` — readers, writers, buffered I/O
- `os` — file system, processes, environment
- `net` — TCP/UDP sockets, DNS
- `http` — HTTP server and client
- `json` — JSON encoding/decoding
- `crypto` — hashing, encryption, TLS
- `fmt` — string formatting
- `strings` — string manipulation
- `bytes` — byte slice utilities
- `math` — math functions
- `sync` — mutexes, atomics, wait groups
- `unsafe` — raw pointers, type layout, pointer arithmetic
- `testing` — test framework
- `time` — time, duration, timers
- `log` — structured logging
