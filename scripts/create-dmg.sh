#!/usr/bin/env bash
#
# create-dmg.sh — Create a macOS DMG installer for the Run language compiler.
#
# Usage:
#   ./scripts/create-dmg.sh \
#       --version 0.1.0 \
#       --binary-path zig-out/bin/run \
#       --lib-path zig-out/lib/librunrt.a \
#       --include-dir zig-out/include/run \
#       --output-dir dist/
#

set -euo pipefail

VERSION=""
BINARY_PATH=""
LIB_PATH=""
INCLUDE_DIR=""
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: $0 --version VERSION --binary-path PATH --lib-path PATH --include-dir PATH [--output-dir DIR]

Arguments:
  --version VERSION      Release version (e.g. 0.1.0) [required]
  --binary-path PATH     Path to the 'run' binary [required]
  --lib-path PATH        Path to librunrt.a [required]
  --include-dir PATH     Path to the include/run directory containing .h files [required]
  --output-dir DIR       Directory to write the DMG (default: .)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     VERSION="$2";     shift 2 ;;
        --binary-path) BINARY_PATH="$2"; shift 2 ;;
        --lib-path)    LIB_PATH="$2";    shift 2 ;;
        --include-dir) INCLUDE_DIR="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
        -h|--help)     usage ;;
        *)             echo "Error: unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -z "$VERSION" || -z "$BINARY_PATH" || -z "$LIB_PATH" || -z "$INCLUDE_DIR" ]]; then
    echo "Error: --version, --binary-path, --lib-path, and --include-dir are required." >&2
    usage
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: this script only works on macOS." >&2
    exit 1
fi

DMG_NAME="Run-${VERSION}.dmg"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

VOLUME_NAME="Run ${VERSION}"
DMG_CONTENT="${STAGING_DIR}/dmg-content"

echo "==> Creating DMG staging area..."

# Create directory structure.
mkdir -p "${DMG_CONTENT}/bin"
mkdir -p "${DMG_CONTENT}/lib"
mkdir -p "${DMG_CONTENT}/include/run"

# Copy files.
cp "$BINARY_PATH" "${DMG_CONTENT}/bin/run"
chmod +x "${DMG_CONTENT}/bin/run"

cp "$LIB_PATH" "${DMG_CONTENT}/lib/librunrt.a"

for header in "${INCLUDE_DIR}"/*.h; do
    [[ -f "$header" ]] && cp "$header" "${DMG_CONTENT}/include/run/"
done

# Copy LICENSE if available in the repo root.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -f "${REPO_ROOT}/LICENSE" ]] && cp "${REPO_ROOT}/LICENSE" "${DMG_CONTENT}/"

# ---------------------------------------------------------------------------
# README.txt
# ---------------------------------------------------------------------------

cat > "${DMG_CONTENT}/README.txt" <<EOF
Run Language Compiler v${VERSION}
==================================

Run is a systems programming language with Go simplicity and low-level control.

Contents:
  bin/run            — the compiler binary
  lib/librunrt.a     — the runtime static library
  include/run/*.h    — public C headers for the runtime

Quick install:
  Run the included install.sh script, or manually copy the files:

    sudo cp bin/run /usr/local/bin/
    sudo cp lib/librunrt.a /usr/local/lib/
    sudo mkdir -p /usr/local/include/run
    sudo cp include/run/*.h /usr/local/include/run/

Prerequisites:
  - Zig >= 0.15 must be installed (the compiler shells out to 'zig cc')

More information: https://runlang.dev
Source code:       https://github.com/marsolab/runlang
EOF

# ---------------------------------------------------------------------------
# install.sh (bundled installer)
# ---------------------------------------------------------------------------

cat > "${DMG_CONTENT}/install.sh" <<'INSTALLER'
#!/bin/sh
#
# Install Run compiler to /usr/local.
# Run with: sh install.sh
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing Run compiler to /usr/local..."

sudo mkdir -p /usr/local/bin
sudo mkdir -p /usr/local/lib
sudo mkdir -p /usr/local/include/run

sudo cp "${SCRIPT_DIR}/bin/run" /usr/local/bin/run
sudo chmod +x /usr/local/bin/run

sudo cp "${SCRIPT_DIR}/lib/librunrt.a" /usr/local/lib/librunrt.a

for header in "${SCRIPT_DIR}"/include/run/*.h; do
    [ -f "$header" ] && sudo cp "$header" /usr/local/include/run/
done

echo "==> Done! Run 'run --version' to verify."
INSTALLER
chmod +x "${DMG_CONTENT}/install.sh"

# ---------------------------------------------------------------------------
# Create the DMG
# ---------------------------------------------------------------------------

echo "==> Creating DMG..."
mkdir -p "$OUTPUT_DIR"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_CONTENT" \
    -ov \
    -format UDZO \
    "${OUTPUT_DIR}/${DMG_NAME}"

echo "==> DMG created: ${OUTPUT_DIR}/${DMG_NAME}"
