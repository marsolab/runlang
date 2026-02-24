# Concurrency

Run has built-in support for concurrency through green threads. Use the `run` keyword to spawn a lightweight concurrent task — similar to goroutines in Go.

```run
package main

use "fmt"
use "time"

fn say(msg: str) {
    for i in 0..3 {
        time.sleep(100)
        fmt.println(msg)
    }
}

fn main() {
    run say("hello")
    say("world")
}
```

The `run say("hello")` call starts `say` in a new green thread. The main function continues executing concurrently.

## Spawning multiple tasks

You can spawn as many concurrent tasks as you need. The runtime schedules them across available threads.

```run
package main

use "fmt"
use "time"

fn worker(id: int) {
    time.sleep(100)
    fmt.println("worker", id, "done")
}

fn main() {
    for i in 0..5 {
        run worker(i)
    }

    time.sleep(1000) // wait for workers to finish
}
```

To coordinate between concurrent tasks, use channels — covered in the next chapter.
