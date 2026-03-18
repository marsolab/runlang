#!/usr/bin/env bash
#
# build-rpm.sh — Build an .rpm package for the Run language compiler.
#
# Usage:
#   ./packaging/rpm/build-rpm.sh \
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
  --output-dir DIR       Directory to write the .rpm file (default: .)
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

# Map architecture names for RPM.
case "$ARCH" in
    amd64)  RPM_ARCH="x86_64"  ; RUN_ARCH="amd64" ;;
    arm64)  RPM_ARCH="aarch64" ; RUN_ARCH="arm64"  ;;
    *)      echo "Error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/run.spec"

if [[ ! -f "$SPEC_FILE" ]]; then
    echo "Error: spec file not found: $SPEC_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Set up rpmbuild tree
# ---------------------------------------------------------------------------

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RPMBUILD_DIR="${WORKDIR}/rpmbuild"
mkdir -p "${RPMBUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

echo "==> Copying tarball to SOURCES..."
cp "$TARBALL_PATH" "${RPMBUILD_DIR}/SOURCES/"

echo "==> Copying spec file..."
cp "$SPEC_FILE" "${RPMBUILD_DIR}/SPECS/run.spec"

# ---------------------------------------------------------------------------
# Build the RPM
# ---------------------------------------------------------------------------

echo "==> Building RPM for ${RPM_ARCH}..."
rpmbuild \
    --define "_topdir ${RPMBUILD_DIR}" \
    --define "version ${VERSION}" \
    --define "_run_arch ${RUN_ARCH}" \
    --target "${RPM_ARCH}" \
    -bb "${RPMBUILD_DIR}/SPECS/run.spec"

# ---------------------------------------------------------------------------
# Copy output
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR"

RPM_FILE="$(find "${RPMBUILD_DIR}/RPMS" -name "*.rpm" -type f | head -1)"
if [[ -z "$RPM_FILE" ]]; then
    echo "Error: no RPM file found after build." >&2
    exit 1
fi

cp "$RPM_FILE" "$OUTPUT_DIR/"
RPM_BASENAME="$(basename "$RPM_FILE")"

echo "==> Package created: ${OUTPUT_DIR}/${RPM_BASENAME}"
