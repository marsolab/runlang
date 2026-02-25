# Channels

Channels are the primary way to communicate between concurrent tasks in Run. They allow one task to send a value and another to receive it.

## Creating channels

```run
ch := make_chan(int)       // unbuffered channel
ch := make_chan(int, 10)   // buffered channel with capacity 10
```

## Sending and receiving

Use `<-` to send and receive values.

```run
package main

use "fmt"

fn producer(ch: chan int) {
    for i in 0..5 {
        ch <- i  // send
    }
}

fn main() {
    ch := make_chan(int, 10)

    run producer(ch)

    for i in 0..5 {
        val := <-ch  // receive
        fmt.println(val)
    }
}
```

## Unbuffered channels

An unbuffered channel synchronizes the sender and receiver — the sender blocks until the receiver is ready, and vice versa. This makes unbuffered channels useful for direct handoffs between tasks.

## Buffered channels

A buffered channel allows sends to proceed without blocking until the buffer is full. This is useful when the sender and receiver run at different speeds.

```run
ch := make_chan(string, 5)
ch <- "hello"  // does not block (buffer has space)
```
