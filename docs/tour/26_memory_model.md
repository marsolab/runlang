# Memory Model

Run uses generational references for memory safety — no garbage collector, no borrow checker.

## How it works

Every heap allocation carries a generation number. When you create a non-owning reference to an object, the reference remembers the generation at the time it was created. On every dereference, the runtime checks that the object's current generation matches the remembered one. If the object has been freed and the memory reused, the generation won't match, and the program traps instead of silently reading garbage.

## Owning references

Owning references automatically free the pointed-to object when they go out of scope.

```run
package main

use "fmt"

pub struct Node {
    value: int
    next: &Node?
}

fn main() {
    let node := Node{ value: 42, next: null }
    // node is freed when main returns
}
```

## Non-owning references

Non-owning references observe but do not control the lifetime of the pointed-to object.

```run
fn sum_list(head: @Node) int {
    var total int = 0
    var current: @Node? = head
    for current != null {
        total = total + current.value
        current = current.next
    }
    return total
}
```

Here `@Node` is a read-only, non-owning reference. The runtime verifies on each access that the node is still alive.

## Why generational references?

This model avoids the runtime cost of garbage collection and the complexity of a borrow checker, while still catching use-after-free bugs at runtime. It is a pragmatic middle ground — safe by default, fast in practice.
