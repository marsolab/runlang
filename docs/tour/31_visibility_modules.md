# Visibility and Modules

Run uses a simple module system: each file is a module and each directory is a package. Visibility is controlled by the `pub` keyword.

## Private by default

Everything in Run is private by default. Only items marked with `pub` are accessible from other packages.

```run
// math/vector.run

pub Vec3 struct {
    pub x: f64
    pub y: f64
    pub z: f64
}

// public — callable from other packages
pub fun Vec3.length(self: @Vec3) f64 {
    return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z)
}

// private — only visible within the math package
fun normalize_internal(v: &Vec3) {
    len := v.length()
    v.x = v.x / len
    v.y = v.y / len
    v.z = v.z / len
}
```

## Files and packages

A single `.run` file is a module. All files in the same directory belong to the same package and can access each other's private items.

```
myproject/
    main.run          // package main
    math/
        vector.run    // package math
        matrix.run    // package math — can see vector.run's private items
    net/
        http.run      // package net
```

## Using packages

Import a package with `use` and access its public items through the package name.

```run
package main

use "math"
use "fmt"

fun main() {
    v := math.Vec3{ x: 1.0, y: 2.0, z: 3.0 }
    fmt.println(v.length())
}
```

This system is deliberately simple. There are no complex visibility modifiers or nested module hierarchies — just `pub` or private, at the package boundary.
