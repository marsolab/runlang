# Run

A systems programming language combining Go's simplicity with low-level control.

Run targets developers who want memory safety, performance, and straightforward syntax — without a garbage collector or borrow checker. It uses **generational references** for memory safety with deterministic destruction, keeping the language simple while giving you full control.

## A Quick Look

```run
pub Point struct {
    x f64
    y f64
}

fun (p @Point) length() f64 {
    return math.sqrt(p.x * p.x + p.y * p.y)
}

fun (p &Point) translate(dx f64, dy f64) {
    p.x = p.x + dx
    p.y = p.y + dy
}

pub fun main() !void {
    p := Point{ x: 3.0, y: 4.0 }
    p.translate(1.0, -1.0)

    content := try read_file("config.txt") :: "loading config"
    fmt.println(content)
}
```

## Key Features

- **Memory safety without GC or borrow checker** — generational references catch use-after-free at runtime with minimal overhead. Owning references auto-free on scope exit.
- **Go-style methods** — receivers declared outside the struct: `fun (p &Point) move(dx f64) { ... }`. Three receiver types: `&T` (read/write), `@T` (read-only), `T` (value copy).
- **Error unions with context** — functions return `!T` for fallible operations. Propagate with `try` and attach context: `try expr :: "loading config"`.
- **Sum types and pattern matching** — `type State = .loading | .ready(Data) | .error(string)` with exhaustive `switch`.
- **Green threads and channels** — `run my_function()` spawns lightweight threads. Communicate with `chan[T]` channels.
- **Nullable types** — `T?` with compile-time null safety. Must handle `null` explicitly.
- **No generics by design** — built-in collections (slices, maps, channels) have language-level support, keeping the type system simple.
- **Newlines are significant** — no semicolons, clean visual structure.

## Getting Started

### Prerequisites

Run's compiler is written in [Zig](https://ziglang.org/). You need **Zig 0.15** or later.

### Build from Source

```bash
git clone https://github.com/marsolab/runlang.git
cd runlang
zig build
```

This produces the `run` compiler binary.

### Usage

```bash
# Compile and run a program
zig build run -- run hello.run

# Compile to a native binary
zig build run -- build hello.run

# Type-check without compiling
zig build run -- check hello.run

# Debug: dump lexer tokens
zig build run -- tokens hello.run

# Debug: dump parsed AST
zig build run -- ast hello.run
```

### Run Tests

```bash
zig build test
```

## Learn the Language

- **[Language Tour](docs/tour/)** — a 40-part progressive tutorial covering everything from hello world to concurrency and memory management
- **[Language Specification](SPEC.md)** — complete reference for Run's syntax, type system, memory model, and standard library design

## Current Status

Run is in **early development**. The compiler frontend is functional, but code generation is not yet implemented.

| Component | Status |
|---|---|
| Lexer | Complete |
| Parser | Complete |
| Naming conventions | Complete |
| Semantic analysis | Not started |
| Type checking | Not started |
| Code generation | Not started |
| Standard library | Not started |

This is a great time to get involved — the language design is taking shape, and there are significant pieces to build.

## Project Structure

```
src/
├── main.zig      CLI entry point and command dispatch
├── token.zig     Token types (~90 variants) and keyword map
├── lexer.zig     Single-pass stateless scanner
├── parser.zig    Recursive descent parser with precedence climbing
├── ast.zig       Flat AST representation (node array + extra_data)
├── naming.zig    Naming convention enforcement
└── root.zig      Module re-exports and test discovery
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and how to submit changes.

Please read our [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## License

[MIT](LICENSE) — Marsolab
