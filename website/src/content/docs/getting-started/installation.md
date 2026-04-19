---
title: Installation
description: Install the Run compiler on macOS or Linux
---

## Quick Install

The fastest way to install Run on macOS or Linux is with the install script:

```bash
curl -fsSL https://runlang.dev/install.sh | sh
```

This will detect your platform and install the latest release to `~/.run/bin`.

:::tip
After installation, add `~/.run/bin` to your `PATH` if the installer doesn't do it automatically.
:::

## macOS

### Homebrew (recommended)

The easiest way to install Run on macOS is via Homebrew:

```bash
brew install marsolab/tap/run
```

To upgrade to the latest version:

```bash
brew upgrade run
```

### Install Script

Alternatively, use the install script:

```bash
curl -fsSL https://runlang.dev/install.sh | sh
```

### DMG

Download the latest `.dmg` from the [GitHub Releases](https://github.com/marsolab/runlang/releases) page. Open the disk image and drag the `run` binary to a directory on your `PATH`, such as `/usr/local/bin`.

## Linux

### Install Script

```bash
curl -fsSL https://runlang.dev/install.sh | sh
```

### Debian / Ubuntu (.deb)

Download the `.deb` package from the [GitHub Releases](https://github.com/marsolab/runlang/releases) page, then install it:

```bash
sudo dpkg -i run_<version>_amd64.deb
```

Or install directly with `apt`:

```bash
sudo apt install ./run_<version>_amd64.deb
```

### Fedora / RHEL (.rpm)

Download the `.rpm` package from the [GitHub Releases](https://github.com/marsolab/runlang/releases) page, then install it:

```bash
sudo rpm -i run-<version>.x86_64.rpm
```

Or with `dnf`:

```bash
sudo dnf install ./run-<version>.x86_64.rpm
```

### Arch Linux (AUR)

Run is available in the AUR as `run-lang`:

```bash
yay -S run-lang
```

Or with any other AUR helper of your choice.

### Snap

```bash
sudo snap install run-lang
```

## From Source

Building from source requires [Zig](https://ziglang.org/) version 0.16 or later.

```bash
git clone https://github.com/marsolab/runlang.git
cd runlang
zig build
```

The compiled binary will be at `zig-out/bin/run`. You can move it to a directory on your `PATH`:

```bash
sudo cp zig-out/bin/run /usr/local/bin/
```

Or install directly:

```bash
zig build -p ~/.local
```

:::note
Building from source gives you the latest development version, which may include unreleased features and changes.
:::

## Verify Installation

After installing, verify that Run is working:

```bash
run --version
```

You should see output like:

```
run 0.1.0
```

You can also run a quick test:

```bash
echo 'fun main() { fmt.println("Hello, World!") }' > hello.run
run run hello.run
```

## Uninstall

### Homebrew (macOS)

```bash
brew uninstall run
```

### Install Script

Remove the binary and configuration directory:

```bash
rm -rf ~/.run
```

Then remove the `PATH` entry from your shell configuration file (`~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`).

### Debian / Ubuntu

```bash
sudo apt remove run
```

### Fedora / RHEL

```bash
sudo dnf remove run
```

### Arch Linux (AUR)

```bash
yay -R run-lang
```

### Snap

```bash
sudo snap remove run-lang
```

### From Source

Simply remove the binary from wherever you placed it:

```bash
sudo rm /usr/local/bin/run
```

## Note about Zig

Run's compiler is written in [Zig](https://ziglang.org/), a systems programming language focused on correctness and performance. If you are building from source, you need Zig version **0.16 or later** installed on your system.

:::caution
Older versions of Zig (0.14 and below) are not compatible with the Run compiler due to breaking API changes in the Zig standard library.
:::

You can install Zig from [ziglang.org/download](https://ziglang.org/download/) or via your system's package manager:

```bash
# macOS
brew install zig

# Arch Linux
pacman -S zig

# Using zigup (cross-platform)
zigup 0.16.0
```
