# Debugging Run Programs in Neovim

This guide covers setting up debugging for Run programs in Neovim using [nvim-dap](https://github.com/mfussenegger/nvim-dap).

## Prerequisites

- Neovim 0.8+ with [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed
- The `run` compiler installed and on your `PATH`
- GDB or LLDB installed on your system

## Installation

Install nvim-dap using your preferred plugin manager:

### lazy.nvim

```lua
{
  "mfussenegger/nvim-dap",
  config = function()
    require("dap-run")  -- see configuration below
  end,
}
```

### packer.nvim

```lua
use {
  "mfussenegger/nvim-dap",
  config = function()
    require("dap-run")
  end,
}
```

## Configuration

Create `~/.config/nvim/lua/dap-run.lua`:

```lua
local dap = require("dap")

-- Register the Run debug adapter
dap.adapters.run = {
  type = "executable",
  command = "run",
  args = { "debug", "--dap" },
}

-- Configure launch for .run files
dap.configurations.run = {
  {
    type = "run",
    request = "launch",
    name = "Debug Run Program",
    program = "${file}",
  },
}

-- Associate .run files with the run filetype
vim.filetype.add({
  extension = {
    run = "run",
  },
})
```

## Keybindings

Add to your Neovim config (e.g., `init.lua`):

```lua
local dap = require("dap")

-- Debugging keymaps
vim.keymap.set("n", "<F5>", dap.continue, { desc = "Debug: Continue" })
vim.keymap.set("n", "<F10>", dap.step_over, { desc = "Debug: Step Over" })
vim.keymap.set("n", "<F11>", dap.step_into, { desc = "Debug: Step Into" })
vim.keymap.set("n", "<F12>", dap.step_out, { desc = "Debug: Step Out" })
vim.keymap.set("n", "<leader>b", dap.toggle_breakpoint, { desc = "Debug: Toggle Breakpoint" })
vim.keymap.set("n", "<leader>B", function()
  dap.set_breakpoint(vim.fn.input("Breakpoint condition: "))
end, { desc = "Debug: Set Conditional Breakpoint" })
```

## Usage

1. Open a `.run` file
2. Set breakpoints with `<leader>b`
3. Start debugging with `<F5>`
4. Step through code with `<F10>` (over), `<F11>` (into), `<F12>` (out)
5. Use `:lua require("dap").repl.open()` to open the debug REPL

## Optional: nvim-dap-ui

For a richer debugging experience with variable inspection and watch windows:

```lua
{
  "rcarriga/nvim-dap-ui",
  dependencies = { "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" },
  config = function()
    local dapui = require("dapui")
    dapui.setup()

    local dap = require("dap")
    dap.listeners.after.event_initialized["dapui_config"] = dapui.open
    dap.listeners.before.event_terminated["dapui_config"] = dapui.close
    dap.listeners.before.event_exited["dapui_config"] = dapui.close
  end,
}
```

## Conditional Breakpoints

Set a conditional breakpoint:

```lua
require("dap").set_breakpoint("i > 10")
```

Or interactively with the `<leader>B` keymap configured above.

## Troubleshooting

### "Adapter run not found"
- Ensure `run` is on your PATH: `:!which run`
- Check that the adapter configuration uses `type = "executable"`

### Breakpoints not verified
- The DAP server compiles the program when `launch` is sent
- Check `:DapShowLog` for compilation errors
- Ensure the file is saved before starting the debugger

### No variables shown
- Variables are fetched from GDB via the MI protocol
- Ensure GDB or LLDB is installed
- SSA temporaries (`_t0`, `_t1`) are automatically hidden
