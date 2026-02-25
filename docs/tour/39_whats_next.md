# What's Next

Congratulations — you have completed the Run language tour! Here is a summary of what you learned and where to go from here.

## What you covered

- **Basics** — variables, constants, types, functions, operators
- **Control flow** — for loops, if/else, switch, break/continue, defer
- **Data types** — structs, slices, maps, strings, pointers
- **Type system** — methods, traits, sum types, nullable types, newtypes
- **Error handling** — error unions with `!T`, `try`, and `switch`
- **Closures** — first-class functions and captured variables
- **Concurrency** — green threads with `run`, channels for communication
- **Memory model** — generational references, owning and non-owning pointers
- **Tooling** — testing, project structure, standard library

## A complete example

Here is a small program that ties several concepts together:

```run
package main

use "fmt"
use "os"

pub struct Config {
    host: string
    port: int
}

trait Display {
    fn string(self: @Self) string
}

impl Display for Config {
    fn string(self: @Config) string {
        return fmt.sprintf("%s:%d", self.host, self.port)
    }
}

fn load_config(path: string) !Config {
    content := try os.read_file(path)
    host := try parse_field(content, "host")
    port := try parse_int(try parse_field(content, "port"))
    return Config{ host: host, port: port }
}

fn main() {
    switch load_config("server.conf") {
        .ok(config) => {
            fmt.println("starting server on", config.string())
        },
        .err(e) => {
            fmt.println("error:", e)
            os.exit(1)
        },
    }
}
```

## Next steps

- **Read the specification** — the full language spec covers every detail
- **Build something** — the best way to learn is to write a real program
- **Explore the standard library** — `fmt`, `http`, `json`, and more are ready to use
- **Join the community** — ask questions, share what you build, and help improve Run

Happy coding!
