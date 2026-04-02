---
title: "Debugging in VS Code"
sidebar:
  order: 0
---

This guide covers setting up debugging for Run programs in Visual Studio Code.

## Prerequisites

- VS Code 1.80+
- The `run` compiler installed and on your `PATH`
- GDB or LLDB installed on your system

## Quick Start

### Using the Extension (Recommended)

1. Install the Run Debug extension from `editors/vscode/` (see [extension README](../../editors/vscode/README.md))
2. Open a `.run` file
3. Press `F5` to start debugging

### Without the Extension

You can use the generic DAP support with a `launch.json` configuration:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "run",
      "request": "launch",
      "name": "Debug Run Program",
      "program": "${file}"
    }
  ]
}
```

## Features

### Breakpoints

- Click in the gutter to toggle breakpoints
- Right-click a breakpoint for conditional options:
  - **Expression condition**: e.g., `i > 10`
  - **Hit count**: Break after N hits

### Stepping

| Action | Shortcut |
|--------|----------|
| Continue | `F5` |
| Step Over | `F10` |
| Step Into | `F11` |
| Step Out | `Shift+F11` |

### Variable Inspection

- Hover over variables to see their values
- Use the **Variables** pane in the Debug sidebar
- Variables display Run type names (e.g., `int` instead of `int64_t`)
- SSA temporaries are automatically hidden

### Debug Console

Type Run expressions in the Debug Console to evaluate them:

```
> myVariable
42
> obj.field
"hello"
```

### Rich Inspection (Custom Requests)

The DAP server supports custom inspection commands for Run runtime types. These can be accessed via the Debug Console or extensions:

- `run/inspectGenRef`: Inspect generational reference validity
- `run/inspectChannel`: View channel buffer state and waiters
- `run/inspectMap`: View map entry count

### Batch Commands (AI Agent Support)

The `runBatch` custom request allows multiple DAP commands in a single request, reducing round-trips for AI coding agents:

```json
{
  "command": "runBatch",
  "arguments": {
    "commands": [
      { "command": "setBreakpoints", "args": { "source": {"path": "main.run"}, "breakpoints": [{"line": 5}] } },
      { "command": "continue", "args": {} }
    ]
  }
}
```

## Architecture

```
VS Code  <--DAP/stdio-->  run debug --dap  <--GDB/MI-->  GDB/LLDB  <-->  ./program
```

1. VS Code sends DAP requests over stdin
2. The Run DAP server compiles the program with debug symbols
3. GDB or LLDB is launched via the MI protocol
4. Debug operations are translated between DAP and GDB/MI
5. Source mapping uses `#line` directives to map C code back to `.run` source
