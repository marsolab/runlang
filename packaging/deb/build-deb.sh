#!/usr/bin/env bash
#
# build-deb.sh — Build a .deb package for the Run language compiler.
#
# Usage:
#   ./packaging/deb/build-deb.sh \
#       --version 0.1.0 \
#       --arch amd64 \
#       --tarball-path run-0.1.0-linux-amd64.tar.gz \
#       --output-dir dist/
#

set -euo pipefail

VERSION=""
ARCH=""
TARBALL_PATH=""
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: $0 --version VERSION --arch ARCH --tarball-path PATH [--output-dir DIR]

Arguments:
  --version VERSION      Release version (e.g. 0.1.0) [required]
  --arch ARCH            Architecture: amd64 or arm64 [required]
  --tarball-path PATH    Path to the release tarball [required]
  --output-dir DIR       Directory to write the .deb file (default: .)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION="$2";      shift 2 ;;
        --arch)         ARCH="$2";         shift 2 ;;
        --tarball-path) TARBALL_PATH="$2"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "Error: unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -z "$VERSION" || -z "$ARCH" || -z "$TARBALL_PATH" ]]; then
    echo "Error: --version, --arch, and --tarball-path are required." >&2
    usage
fi

if [[ ! -f "$TARBALL_PATH" ]]; then
    echo "Error: tarball not found: $TARBALL_PATH" >&2
    exit 1
fi

# Map architecture names for dpkg.
case "$ARCH" in
    amd64)  DEB_ARCH="amd64" ;;
    arm64)  DEB_ARCH="arm64" ;;
    *)      echo "Error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEB_NAME="run_${VERSION}_${DEB_ARCH}.deb"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Extracting tarball..."
tar xzf "$TARBALL_PATH" -C "$WORKDIR"

EXTRACTED_DIR="${WORKDIR}/run-${VERSION}-linux-${ARCH}"
if [[ ! -d "$EXTRACTED_DIR" ]]; then
    echo "Error: expected directory $EXTRACTED_DIR not found after extraction." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the deb directory structure
# ---------------------------------------------------------------------------

DEB_ROOT="${WORKDIR}/deb-root"
mkdir -p "${DEB_ROOT}/DEBIAN"
mkdir -p "${DEB_ROOT}/usr/local/bin"
mkdir -p "${DEB_ROOT}/usr/local/lib"
mkdir -p "${DEB_ROOT}/usr/local/include/run"
mkdir -p "${DEB_ROOT}/usr/share/doc/run"

echo "==> Populating package tree..."

# Binary.
cp "${EXTRACTED_DIR}/bin/run" "${DEB_ROOT}/usr/local/bin/run"
chmod 0755 "${DEB_ROOT}/usr/local/bin/run"

# Runtime library.
cp "${EXTRACTED_DIR}/lib/librunrt.a" "${DEB_ROOT}/usr/local/lib/librunrt.a"
chmod 0644 "${DEB_ROOT}/usr/local/lib/librunrt.a"

# Headers.
for header in "${EXTRACTED_DIR}"/include/run/*.h; do
    [[ -f "$header" ]] && cp "$header" "${DEB_ROOT}/usr/local/include/run/"
done
find "${DEB_ROOT}/usr/local/include" -type f -exec chmod 0644 {} +

# Documentation.
if [[ -f "${REPO_ROOT}/LICENSE" ]]; then
    cp "${REPO_ROOT}/LICENSE" "${DEB_ROOT}/usr/share/doc/run/LICENSE"
elif [[ -f "${EXTRACTED_DIR}/LICENSE" ]]; then
    cp "${EXTRACTED_DIR}/LICENSE" "${DEB_ROOT}/usr/share/doc/run/LICENSE"
fi

# ---------------------------------------------------------------------------
# Generate DEBIAN/control from template
# ---------------------------------------------------------------------------

CONTROL_TEMPLATE="${SCRIPT_DIR}/control.template"
if [[ ! -f "$CONTROL_TEMPLATE" ]]; then
    echo "Error: control template not found: $CONTROL_TEMPLATE" >&2
    exit 1
fi

echo "==> Generating DEBIAN/control..."

# Calculate installed size in KB.
INSTALLED_SIZE=$(du -sk "${DEB_ROOT}" | awk '{print $1}')

sed -e "s/{{VERSION}}/${VERSION}/g" \
    -e "s/{{ARCH}}/${DEB_ARCH}/g" \
    -e "s/{{INSTALLED_SIZE}}/${INSTALLED_SIZE}/g" \
    "$CONTROL_TEMPLATE" > "${DEB_ROOT}/DEBIAN/control"

# ---------------------------------------------------------------------------
# Build the .deb
# ---------------------------------------------------------------------------

echo "==> Building ${DEB_NAME}..."
mkdir -p "$OUTPUT_DIR"

dpkg-deb --build --root-owner-group "$DEB_ROOT" "${OUTPUT_DIR}/${DEB_NAME}"

echo "==> Package created: ${OUTPUT_DIR}/${DEB_NAME}"
