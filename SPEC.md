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
- Default global allocator; functions can accept an **optional custom allocator** parameter
- No borrow checker, no GC, no reference counting

### Pointer Types

- `&T` — read/write pointer (default, Go-like semantics)
- `@T` — read-only pointer (compiler-enforced immutability on pointee)

## Variables

```
var a int           // declaration, zero-initialized
var a int = 32      // explicit type with initialization
a := 32             // short declaration with type inference
const a int = 32    // compile-time constant
```

- Variables are **mutable by default**
- `const` for immutable bindings

## Functions

```
pub fn add(a int, b int) int {
    return a + b
}

fn private_helper(x int) int {
    return x * 2
}
```

- Zig-style signature: return type after parameters, no arrow
- `pub` keyword for public visibility, private by default
- Full closures supported: `fn(x int) int { return x + 1 }`

## Error Handling

Zig-style error unions. A function that can fail returns `!T`:

```
fn read_file(path str) !str {
    // returns str on success, error on failure
}

// Caller handles with try:
content := try read_file("config.txt")

// Or with switch:
switch read_file("config.txt") {
    .ok(content) => use(content),
    .err(e) => log(e),
}
```

- Error sets are **inferred by the compiler**
- No generics needed — `!T` is a built-in language construct

## Type System

### Primitive Types

- **Integers**: `int`, `uint`, `i32`, `i64`, `u32`, `u64`, `byte`
- **Floats**: `f32`, `f64`
- **Boolean**: `bool`
- **String**: `str` — UTF-8 byte slice

### Strings

- UTF-8 encoded byte slices
- Default iteration yields characters (unicode codepoints):
  - `for c in s { }` — iterate over characters
  - `for b in s.bytes { }` — iterate over raw bytes

### Structs

```
pub struct Point {
    x f64
    y f64
}

fn (p &Point) distance(other @Point) f64 {
    dx := p.x - other.x
    dy := p.y - other.y
    return math.sqrt(dx * dx + dy * dy)
}
```

- Methods declared **outside** the struct with a receiver (Go-style)
- `&T` receiver for read/write, `@T` receiver for read-only

### Traits (Explicit)

```
pub trait Stringer {
    fn (s @Self) to_string() str
}

impl Stringer for Point {
    fn (p @Point) to_string() str {
        return fmt.sprintf("(%f, %f)", p.x, p.y)
    }
}
```

- Explicit `impl Trait for Type` — no implicit/structural interfaces
- No operator overloading

### Sum Types / Tagged Unions

```
type State = .loading | .ready(Data) | .error(str)

switch state {
    .loading => show_spinner(),
    .ready(data) => render(data),
    .error(msg) => show_error(msg),
}
```

- First-class pattern matching via `switch`

### Nullable Types

```
var x int? = null
var y int? = 42

switch x {
    .some(val) => use(val),
    .null => handle_missing(),
}
```

- Compile-time null safety (Kotlin-style)
- `Type?` denotes a nullable type
- Must handle null explicitly before use

### Newtype

```
type UserID = int    // distinct type, not an alias
type Email = str
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
    1 => do_one(),
    2, 3 => do_two_or_three(),
    .variant(x) => use(x),
    _ => default(),
}
```

- No fallthrough
- Exhaustive matching on sum types

### Defer

```
fn process() !void {
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
run fn() { do_work() }
```

- `run` spawns a green thread (goroutine-style)
- Lightweight, multiplexed onto OS threads by runtime

### Channels

```
var ch chan int
ch := make_chan(int)        // unbuffered
ch := make_chan(int, 100)   // buffered

ch <- 42                    // send
val := <-ch                 // receive
```

### Unsafe Shared Memory

For performance-critical code, shared memory with explicit synchronization is allowed
within `unsafe` blocks.

## Visibility and Modules

- **`pub`** keyword marks items as public; everything is **private by default**
- File = module, directory = package (Go-style)
- No semicolons; statements are newline-terminated

```
// math/vector.run
pub struct Vec3 { x f64, y f64, z f64 }

// main.run
import "math"
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
- `testing` — test framework
- `time` — time, duration, timers
- `log` — structured logging
