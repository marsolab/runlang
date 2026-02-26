# Design Philosophy

Run is built on a few deliberate principles. Understanding them helps you write idiomatic code and explains why certain features are absent.

## Simplicity over expressiveness

Run optimizes for readability and a small learning curve. There is one way to loop (`for`), one way to handle errors (`!T` with `try` and `switch`), and one way to define types (`struct`). This means less time debating style and more time solving problems.

## No generics

This is Run's most opinionated decision. Generics add significant complexity to a language — in syntax, error messages, and mental overhead. Run avoids them entirely.

Built-in types that would normally require generics — slices, maps, channels, nullable types, error unions — have language-level support instead.

```run
// These work without generics — they are built into the language
names := ["Alice", "Bob"]              // []string
ages := map[string]int{"Alice": 30}    // map[string]int
ch := make_chan(int, 10)               // chan int
var x: int? = 42                       // int?
fun read() !string { ... }             // !string
```

For user-defined types, use interfaces and concrete implementations. In practice, this covers the vast majority of real-world needs without the complexity tax of generics.

## Memory safety without complexity

Run's generational references provide memory safety without a garbage collector (runtime pauses) or a borrow checker (compile-time complexity). The trade-off is a small runtime cost on pointer dereferences, which is negligible in most applications.

## Explicit over implicit

- Type conversions are explicit — no silent coercions
- Interface implementations are explicit — declared via `implements` block in struct
- Error handling is explicit — errors cannot be silently ignored
- Visibility is explicit — `pub` or private, nothing in between

## Go's pragmatism meets systems control

Run targets developers who like Go's straightforward approach but want more control over memory and performance. If Go is "C with garbage collection," Run is "Go without garbage collection" — keeping the simplicity while giving you deterministic resource management.
