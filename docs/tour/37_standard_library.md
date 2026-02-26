# Standard Library

Run ships with a comprehensive standard library, comparable in scope to Go's. It covers the most common tasks so you can build real applications without third-party dependencies.

## Core packages

| Package    | Description                          |
|------------|--------------------------------------|
| `fmt`      | String formatting and printing       |
| `strings`  | String searching, splitting, joining |
| `bytes`    | Byte slice utilities                 |
| `math`     | Mathematical functions and constants |
| `time`     | Time, durations, and timers          |

## I/O and system

| Package    | Description                          |
|------------|--------------------------------------|
| `io`       | Readers, writers, buffered I/O       |
| `os`       | File system, processes, environment  |
| `log`      | Structured logging                   |

## Networking

| Package    | Description                          |
|------------|--------------------------------------|
| `net`      | TCP/UDP sockets, DNS resolution      |
| `http`     | HTTP server and client               |

## Data and encoding

| Package    | Description                          |
|------------|--------------------------------------|
| `json`     | JSON encoding and decoding           |
| `crypto`   | Hashing, encryption, TLS            |

## Concurrency and testing

| Package    | Description                          |
|------------|--------------------------------------|
| `sync`     | Mutexes, atomics, wait groups        |
| `testing`  | Built-in test framework              |

## Example: a small HTTP server

```run
package main

use "http"
use "fmt"

fun handle(w: &http.ResponseWriter, r: @http.Request) {
    w.write("Hello from Run!")
}

fun main() {
    http.handle_fn("/", handle)
    fmt.println("listening on :8080")
    http.listen_and_serve(":8080")
}
```

The standard library is designed to be practical and unsurprising. When you need something common — reading a file, serving HTTP, encoding JSON — it is already there.
