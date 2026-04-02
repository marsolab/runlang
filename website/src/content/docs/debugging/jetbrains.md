---
title: "Debugging in JetBrains IDEs"
sidebar:
  order: 1
---

This guide covers setting up debugging for Run programs in IntelliJ IDEA, CLion, GoLand, and other JetBrains IDEs.

## Prerequisites

- A JetBrains IDE with the **Debug Adapter Protocol** support (2023.1+)
- The `run` compiler installed and on your `PATH`
- GDB or LLDB installed on your system

## Setup

### Option 1: External Tool + DAP (Recommended)

1. Open **Settings > Tools > External Tools**
2. Click **+** to add a new tool:
   - **Name**: `Run Debug`
   - **Program**: `run`
   - **Arguments**: `debug --dap $FilePath$`
   - **Working directory**: `$ProjectFileDir$`

3. Open **Run > Edit Configurations**
4. Click **+** > **Debug Adapter Protocol**
5. Configure:
   - **Name**: `Debug Run Program`
   - **Debug adapter**: **Executable**
   - **Path**: path to `run` binary (e.g., `/usr/local/bin/run`)
   - **Arguments**: `debug --dap`
   - **Configuration**: Set `program` to the file path:
     ```json
     {
       "request": "launch",
       "program": "$FilePath$"
     }
     ```

### Option 2: Shell Script Wrapper

Create a wrapper script `run-debug-adapter.sh`:

```bash
#!/bin/bash
exec run debug --dap "$@"
```

Make it executable: `chmod +x run-debug-adapter.sh`

Then configure the DAP adapter to use this script.

## Using the Debugger

1. Open a `.run` file in the editor
2. Click in the gutter to set breakpoints
3. Run your debug configuration (`Shift+F9`)
4. Use the Debug tool window to:
   - Step over (`F8`), step into (`F7`), step out (`Shift+F8`)
   - Inspect variables in the Variables pane
   - Evaluate expressions in the Debug Console
   - View the call stack with demangled Run function names

## Conditional Breakpoints

Right-click a breakpoint and select **More** to set:
- **Condition**: A Run expression (e.g., `i > 10`)
- **Hit count**: Break after N hits

## Troubleshooting

### "Failed to start debugger"
- Verify `run` is on your PATH: `which run`
- Verify GDB or LLDB is installed: `gdb --version` or `lldb --version`
- Check the **Debug Console** output for error messages

### Breakpoints not hitting
- Ensure the file path matches exactly (no symlinks)
- Check that `#line` directives in generated C code point to the correct `.run` source
- Try setting a breakpoint on a line with a statement (not a blank line or comment)

### Variables showing C types
- The DAP server maps C types to Run types automatically
- If you see `int64_t` instead of `int`, the type mapping may not cover that type
- SSA temporaries (`_t0`, `_t1`, etc.) are automatically filtered out
