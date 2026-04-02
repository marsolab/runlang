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
fun readFile(path string) !string {
    // returns string on success, error on failure
}

// Caller handles with try:
content := try readFile("config.txt")

// Or with switch:
switch readFile("config.txt") {
    .ok(content) :: use(content),
    .err(e) :: log(e),
}
```

A function that returns nothing but can fail uses bare `!`:

```
fun save(path string) ! {
    try writeFile(path, data)
}

// Caller:
try save("output.txt")
```

- Error sets are **inferred by the compiler**
- No generics needed — `!T` is a built-in language construct
- Bare `!` is equivalent to an error union with a void success type

### Error Context

When propagating errors with `try`, you can attach context using `::`:

```
content := try readFile(path) :: "loading config"
```

If the expression returns an error, the context string is attached to the error
before it propagates. This builds a chain of context as errors bubble up through
the call stack, making it easy to trace the origin of failures.

Plain `try` (without context) still propagates errors unchanged.

## Type System

### Primitive Types

- **Integers**: `int`, `uint`, `i8`, `i16`, `i32`, `i64`, `u32`, `u64`, `byte`
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

Newtypes can implement interfaces using a block syntax that mirrors structs:

```
type Email string {
    implements(
        Stringer,
        fmt.Formatter,
    )
}

fun (e @Email) to_string() string {
    return string(e)
}
```

- The `implements(...)` block inside braces declares which interfaces the newtype satisfies
- Methods are declared outside with a Go-style receiver, same as structs
- Simple newtypes without interfaces need no block: `type UserID int`

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
fun process() ! {
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
that bypass Run's safety guarantees. Like Go's `import "unsafe"`, its presence in
a file's imports is the signal that dangerous operations are in use.

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

## Assembly Language

Run provides a universal, portable assembly language for very low-level optimizations — similar
to Go's Plan9 assembly. This gives developers an escape hatch below `unsafe` for performance-critical
code paths without sacrificing portability.

### Inline Assembly

Inline assembly blocks can appear inside any function using the `asm` keyword:

```run
fun fast_add(a u64, b u64) u64 {
    return asm(a -> r0, b -> r1) u64 {
        add r0, r0, r1
    }
}
```

- `asm(inputs) return_type { instructions }` — inline assembly expression
- **Inputs**: `expr -> register` binds a Run expression to an abstract register using the `->` (arrow right) operator
- **Return type**: the type of the value produced (read from `r0` by convention); optional for void assembly
- **Clobber list**: `asm(inputs; clobber: r2, r3, memory) { ... }` declares side effects — the `;` separates inputs from the clobber clause
- **No-input form**: `asm() { instructions }` for assembly with no inputs or outputs
- **Platform conditionals**: Inside the assembly body, `#platform_name { ... }` selects instructions for a specific target (e.g., `#x86_64`, `#arm64`). The `#` token introduces the platform selector

### Abstract Register Model

Run assembly uses **abstract register names** that map to platform registers at compile time:

| Abstract | x86-64 (System V) | ARM64 (AAPCS) |
|----------|-------------------|---------------|
| `r0`–`r15` | `rax`, `rbx`, `rcx`, ... | `x0`–`x15` |
| `f0`–`f15` | `xmm0`–`xmm15` | `v0`–`v15` (scalar) |
| `sp` | `rsp` | `sp` |
| `fp` | `rbp` | `x29` |

This allows writing assembly that is structurally portable while still mapping to
efficient native instructions. For platform-specific instructions, use conditional
sections:

```run
asm(data -> r0) {
    #x86_64 {
        popcnt r0, r0
    }
    #arm64 {
        cnt v0.8b, v0.8b
        addv b0, v0.8b
        fmov r0, s0
    }
}
```

### External Assembly Files

For larger assembly routines, use external `.rasm` files with platform suffixes:

- `fast_math.rasm` — portable assembly (abstract registers only)
- `fast_math_amd64.rasm` — x86-64 specific
- `fast_math_arm64.rasm` — ARM64 specific

The build system selects the correct file based on the target architecture. If a
platform-specific file exists, it takes priority over the portable version.

```
// fast_math_amd64.rasm
pub fun simd_dot_product(a @[]f32, b @[]f32, len int) f32 {
    // x86-64 native assembly using real register names
    vxorps ymm0, ymm0, ymm0
    // ...
}
```

External assembly functions are callable from Run code like any other function.

### Implementation

Inline assembly lowers to GCC/Clang `__asm__` blocks in the C codegen backend.
External `.rasm` files are assembled into `.S` files and compiled alongside the
generated C code. The runtime already uses this pattern for context switching
(`run_context_amd64.S`, `run_context_arm64.S`).

## SIMD Types and Operations

Run provides first-class SIMD vector and mask types as native primitives. The
`simd.*` namespace is compiler-recognized in this release, so these operations
do not rely on generic library overloading.

### Scalar and Vector Types

Lane access for integer vectors uses the scalar primitives `i8`, `i16`, and
`i32`.

128-bit vectors:
- `v4f32` — 4 × `f32` (SSE / NEON)
- `v2f64` — 2 × `f64`
- `v4i32` — 4 × `i32`
- `v8i16` — 8 × `i16`
- `v16i8` — 16 × `i8`

256-bit vectors (x86-64 AVX):
- `v8f32` — 8 × `f32`
- `v4f64` — 4 × `f64`
- `v8i32` — 8 × `i32`
- `v16i16` — 16 × `i16`
- `v32i8` — 32 × `i8`

Mask types:
- `v2bool`
- `v4bool`
- `v8bool`
- `v16bool`
- `v32bool`

### Operations

SIMD vectors support literal syntax, element-wise arithmetic, comparisons, and
lane access:

```run
a := v4f32{ 1.0, 2.0, 3.0, 4.0 }
b := v4f32{ 5.0, 6.0, 7.0, 8.0 }

c := a + b              // element-wise add: { 6.0, 8.0, 10.0, 12.0 }
d := a * b              // element-wise mul: { 5.0, 12.0, 21.0, 32.0 }
mask := c > a           // comparison result: v4bool

x := a[0]                     // read lane
a[2] = 9.0                    // write lane on a mutable local/parameter
```

Comparisons on matching vector types produce the mask type with the same lane
count. Lane indexing returns the corresponding scalar element type.

### Builtins

The compiler recognizes these `simd.*` builtins:
- `simd.hadd(v)` — horizontal reduction to the scalar lane type
- `simd.dot(a, b)` — dot product of matching vector types
- `simd.shuffle(v, idx0, ..., idxN)` — lane permutation; indices must be integer literals, and the call must provide exactly one index per lane
- `simd.min(a, b)`, `simd.max(a, b)` — element-wise minimum/maximum
- `simd.select(mask, a, b)` — choose lanes from `a` or `b` using the matching mask type
- `simd.load(ptr)` — aligned load from a pointer-to-vector
- `simd.loadUnaligned(ptr)` — unaligned load from a pointer-to-vector
- `simd.store(ptr, v)` — aligned store through a mutable pointer-to-vector
- `simd.width()` — available fast-path width in the compiled binary (`256` with AVX-enabled builds, `128` with SSE/NEON builds, otherwise `0`)

### Memory and Alignment

`simd.load`, `simd.loadUnaligned`, and `simd.store` operate on pointers to the
vector type itself, not pointers to slices or arrays:

```run
var data = v4f32{ 1.0, 2.0, 3.0, 4.0 }
let ptr = &data

let loaded = simd.load(ptr)
simd.store(ptr, loaded)
```

SIMD types are automatically aligned to their natural boundary:
- 128-bit types: 16-byte aligned
- 256-bit types: 32-byte aligned

The allocator respects SIMD alignment for heap allocations, stack locals are
emitted with matching alignment, and `unsafe.alignof(T)` reports the correct
SIMD alignment for these types.

### Platform Mapping

SIMD operations lower to C compiler intrinsics in the codegen backend:
- **x86-64**: SSE/AVX intrinsics (`_mm_add_ps`, `_mm256_mul_ps`, etc.) via `<immintrin.h>`
- **ARM64**: NEON intrinsics (`vaddq_f32`, `vmulq_f32`, etc.) via `<arm_neon.h>`

On platforms without a matching hardware fast path, the compiler emits scalar
fallback helpers so the same source still compiles and runs.

SIMD types do **not** require the `unsafe` package — they are safe, first-class types.
For operations not covered by the built-in functions, use inline assembly (see Assembly Language).

### Standard Library: `simd` Package

The `simd` namespace exposes the compiler-recognized builtins listed above. The
older per-type helper names such as `sum_f32` and `blend_f32` are not part of
this API.

## NUMA Awareness

Run provides tools for building NUMA-friendly applications. On multi-socket systems,
memory locality and thread placement significantly impact performance. Run exposes
NUMA topology through the runtime and integrates it with the scheduler and allocator.

### Topology Discovery

```run
use "runtime/numa"

nodes := numa.nodeCount()           // number of NUMA nodes
current := numa.currentNode()       // node the current green thread is on
cpus := numa.cpus_on_node(0)         // CPU IDs belonging to node 0
dist := numa.distance(0, 1)          // relative distance between nodes
```

The runtime discovers NUMA topology at startup:
- **Linux**: parses `/sys/devices/system/node/` sysfs entries directly (no `libnuma` dependency)
- **Windows**: `GetNumaProcessorNodeEx`, `GetNumaAvailableMemoryNode`
- **macOS/Apple Silicon**: UMA (single node) — NUMA APIs return trivial values

### NUMA-Aware Allocation

NUMA-local allocators conform to a minimal allocator vtable (`alloc_fn`, `free_fn`, `ctx`)
and can be passed to `alloc()` using Run's existing custom allocator support:

```run
use "runtime/numa"

// Create an allocator that allocates on a specific NUMA node
nodeAlloc := numa.allocator(node: 0)

// Use it with alloc
data := alloc([]f32, 1024, allocator: nodeAlloc)
```

The runtime's per-P slab caches automatically allocate from the NUMA node
their bound OS thread is running on. For most applications, the default
allocator already provides good NUMA locality without explicit configuration.

### Thread Affinity

Green threads can be pinned to specific NUMA nodes:

```run
use "runtime/numa"

// Spawn a green thread on a specific NUMA node
run(node: 0) process_local_data(data)

// Pin the current green thread
numa.pin(node: 1)
```

### Scheduler Integration

The GMP scheduler is NUMA-aware:
- **Processors (P)** are assigned to NUMA nodes
- **Work stealing** prefers same-NUMA-node Ps before cross-node Ps
- **OS threads (M)** are pinned to CPUs on their P's NUMA node
- The `G.last_p` affinity hint prefers same-NUMA-node Ps for rescheduling

This means green threads naturally stay on the NUMA node where their data lives,
minimizing cross-node memory traffic without explicit management in most cases.

### Platform Support

| Feature | Linux | Windows | macOS |
|---------|-------|---------|-------|
| Topology discovery | `/sys/devices/system/node/` (sysfs) | `GetNumaProcessorNodeEx` | UMA (trivial) |
| NUMA-local alloc | `mmap` + `mbind(MPOL_BIND)` | `VirtualAllocExNuma` | Default alloc |
| Thread affinity | `pthread_setaffinity_np` | `SetThreadAffinityMask` | No-op (no API) |

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
- Newlines are statement separators (no semicolons)
- Rust-style diagnostics with source context, caret annotations, and contextual help
- Ordering comparisons (`<`, `>`, `<=`, `>=`) require numeric operands
- Equality comparisons (`==`, `!=`) work on any compatible type pair

## Testing

Run has first-class testing built into the language via the `test` and `bench` keywords.
Tests combine Zig's `test` blocks with Go's explicit test context and a composable
operator system.

### Test Blocks

```
use "testing"

test "addition works" (t) {
    t.expect(add(2, 3), t.eq(5))
    t.expect(add(-1, 1), t.eq(0))
}
```

- `test` blocks are top-level declarations
- String description is human-readable (not an identifier)
- `(t)` receives the test context `&T` explicitly (like Go)
- `t.expect(got, operator)` is the single assertion method
- Operators (`t.eq`, `t.gt`, `t.contains`, etc.) are methods on `T`
- Tests are stripped from production builds

### Table-Driven Tests

```
for test "parseInt" in [
    "simple"   :: { input: "42",  want: 42 },
    "negative" :: { input: "-7",  want: -7 },
    "zero"     :: { input: "0",   want: 0  },
] (t) {
    result := try parseInt(row.input)
    t.expect(result, t.eq(row.want))
}
```

- `for test` / `for bench` introduces a table-driven variant
- Each case is `"name" :: { fields }` — reuses `::` from `switch`
- Row fields accessed via `row` binding, or destructured with `as { fields }`

### Fuzzing

```
test "json roundtrip" fuzz(data []byte) (t) {
    parsed := parseJson(data) or return
    output := toJson(parsed)
    reparsed := try parseJson(output)
    t.expect(reparsed, t.eq(parsed))
}
```

- `fuzz(params)` declares fuzz inputs (`[]byte`, `string`, `int`, `f64`, `bool`)
- Optional `seed [...]` provides a seed corpus
- `or return` skips inputs that don't meet preconditions

### Benchmarks

```
bench "sort 1000" (b) {
    data := generateRandomSlice(1000)
    b.resetTimer()
    for _ in 0..b.n {
        sort(data)
    }
}
```

- `bench` blocks receive `(b)` — the benchmark context `&B`, explicitly
- `b.n` is the iteration count set by the framework
- Table-driven benchmarks via `for bench "name" in ["case" :: {}, ...]`

### Lifecycle Hooks

```
test beforeAll { }    // once before all tests in file
test afterAll { }     // once after all tests in file
test beforeEach { }   // before each test
test afterEach { }    // after each test
```

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
