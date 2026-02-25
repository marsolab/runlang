# Project Structure

Run follows a simple, conventional directory layout for organizing projects.

## Standard layout

```
myproject/
    cmd/
        myapp/
            main.run       // command-line entry point
    pkg/
        auth/
            auth.run       // higher-level module: authentication
        http/
            server.run     // higher-level module: HTTP server
    lib/
        hash/
            hash.run       // lower-level library: hashing
        buffer/
            buffer.run     // lower-level library: buffer utilities
    README.md
```

## Directory roles

- **`cmd/`** — Entry points for command-line tools. Each subdirectory is a separate executable with a `main.run` file.
- **`pkg/`** — Higher-level modules that form the application's core logic. These may depend on `lib/` packages.
- **`lib/`** — Lower-level, reusable libraries. These should have minimal dependencies and are candidates for sharing across projects.

## Simple projects

Not every project needs this structure. A small program can be a single file:

```
hello/
    main.run
```

As your project grows, introduce directories naturally. Move reusable code into `lib/`, application logic into `pkg/`, and entry points into `cmd/`.

## Package naming

Each directory is a package. The package name matches the directory name:

```run
// pkg/auth/auth.run
package auth

pub fn login(user: string, pass: string) !Session {
    // ...
}
```

```run
// cmd/myapp/main.run
package main

use "auth"

fn main() {
    session := try auth.login("admin", "secret")
}
```

Keep package names short, lowercase, and descriptive. Avoid generic names like `utils` or `common`.
