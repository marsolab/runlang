# Run Language Debug Extension for VS Code

Debug Run programs directly from VS Code using the built-in DAP (Debug Adapter Protocol) server.

## Prerequisites

- The `run` compiler must be installed and available on your `PATH`
- GDB or LLDB must be installed (the debugger auto-detects which is available)

## Installation

### From Source

```bash
cd editors/vscode
bun install
bun run compile
```

Then press `F5` in VS Code to launch an Extension Development Host, or package with:

```bash
bunx vsce package
code --install-extension run-debug-0.1.0.vsix
```

## Usage

1. Open a `.run` file in VS Code
2. Set breakpoints by clicking in the gutter
3. Press `F5` or go to **Run > Start Debugging**
4. Select **Run Debug** if prompted for a debug configuration

### launch.json Configuration

Create or edit `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "run",
      "request": "launch",
      "name": "Debug Run Program",
      "program": "${file}",
      "stopOnEntry": false,
      "args": []
    }
  ]
}
```

### Configuration Options

| Property | Type | Description |
|----------|------|-------------|
| `program` | string | Path to the `.run` file to debug (required) |
| `stopOnEntry` | boolean | Stop on the first line (default: `false`) |
| `args` | string[] | Command-line arguments for the program |

## Features

- **Breakpoints**: Set, remove, conditional breakpoints, hit counts
- **Stepping**: Step over, step into, step out
- **Variables**: Inspect local variables with Run type names (not C types)
- **Call Stack**: Demangled Run function names
- **Evaluate**: Hover over variables or use the Debug Console
- **Rich Inspection**: Custom commands for generational refs, channels, and maps

## How It Works

The extension spawns `run debug --dap` as a stdio-based debug adapter process.
The Run compiler compiles the program with debug symbols (`-g`), then launches
GDB/LLDB via the MI protocol to provide debugging capabilities. The DAP server
translates between VS Code's Debug Adapter Protocol and the GDB/MI protocol.
