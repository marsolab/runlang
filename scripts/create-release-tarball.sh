#!/usr/bin/env bash
#
# create-release-tarball.sh
#
# Packages the zig-out/ build artifacts into a release tarball for the
# Run language compiler.
#
# Usage:
#   ./scripts/create-release-tarball.sh \
#       --version 0.1.0 \
#       --os linux \
#       --arch amd64 \
#       [--output-dir .]

set -euo pipefail

VERSION=""
OS=""
ARCH=""
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: $0 --version VERSION --os OS --arch ARCH [--output-dir DIR]

Arguments:
  --version VERSION   Release version (e.g. 0.1.0) [required]
  --os OS             Target OS: linux or darwin [required]
  --arch ARCH         Target arch: amd64 or arm64 [required]
  --output-dir DIR    Directory to write the tarball (default: .)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --os)
            OS="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$VERSION" || -z "$OS" || -z "$ARCH" ]]; then
    echo "Error: --version, --os, and --arch are required." >&2
    usage
fi

DIRNAME="run-${VERSION}-${OS}-${ARCH}"
TARBALL="${DIRNAME}.tar.gz"

# Clean up any previous staging directory.
rm -rf "${DIRNAME}"
mkdir -p "${DIRNAME}/bin"
mkdir -p "${DIRNAME}/lib"
mkdir -p "${DIRNAME}/include/run"

# Copy the compiler binary.
cp "zig-out/bin/run" "${DIRNAME}/bin/run"
chmod +x "${DIRNAME}/bin/run"

# Copy the runtime static library.
cp "zig-out/lib/librunrt.a" "${DIRNAME}/lib/librunrt.a"

# Copy public headers (skip the tests/ subdirectory).
for header in zig-out/include/run/*.h; do
    cp "$header" "${DIRNAME}/include/run/"
done

# Copy repo-root files.
[[ -f LICENSE ]] && cp LICENSE "${DIRNAME}/"
[[ -f README.md ]] && cp README.md "${DIRNAME}/"

# Create the tarball.
mkdir -p "${OUTPUT_DIR}"
tar czf "${OUTPUT_DIR}/${TARBALL}" "${DIRNAME}/"

# Clean up staging directory.
rm -rf "${DIRNAME}"

echo "${OUTPUT_DIR}/${TARBALL}"
