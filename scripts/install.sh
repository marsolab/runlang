#!/bin/sh
#
# install.sh — Universal installer for the Run language compiler.
#
# Usage:
#   curl -fsSL https://runlang.dev/install.sh | sh
#   wget -qO- https://runlang.dev/install.sh | sh
#
# Environment variables:
#   RUN_INSTALL_DIR   Installation directory (default: $HOME/.run)
#   RUN_VERSION       Version to install (default: latest)
#

set -eu

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

BOLD=""
RESET=""
GREEN=""
RED=""
YELLOW=""

if [ -t 1 ]; then
    BOLD="\033[1m"
    RESET="\033[0m"
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
fi

info()  { printf "${BOLD}==> %s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}==> %s${RESET}\n" "$*"; }
warn()  { printf "${YELLOW}==> WARNING: %s${RESET}\n" "$*"; }
err()   { printf "${RED}==> ERROR: %s${RESET}\n" "$*" >&2; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Detect platform
# ---------------------------------------------------------------------------

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux"  ;;
        Darwin*) echo "darwin" ;;
        *)       die "Unsupported operating system: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)          echo "amd64" ;;
        amd64)           echo "amd64" ;;
        arm64)           echo "arm64" ;;
        aarch64)         echo "arm64" ;;
        *)               die "Unsupported architecture: $(uname -m)" ;;
    esac
}

# ---------------------------------------------------------------------------
# HTTP helpers (prefer curl, fall back to wget)
# ---------------------------------------------------------------------------

has_cmd() { command -v "$1" >/dev/null 2>&1; }

http_get() {
    url="$1"
    if has_cmd curl; then
        curl -fsSL "$url"
    elif has_cmd wget; then
        wget -qO- "$url"
    else
        die "Neither curl nor wget found. Please install one of them."
    fi
}

http_download() {
    url="$1"
    dest="$2"
    if has_cmd curl; then
        curl -fsSL -o "$dest" "$url"
    elif has_cmd wget; then
        wget -q -O "$dest" "$url"
    else
        die "Neither curl nor wget found. Please install one of them."
    fi
}

# ---------------------------------------------------------------------------
# SHA-256 verification
# ---------------------------------------------------------------------------

sha256_check() {
    file="$1"
    expected="$2"

    if has_cmd sha256sum; then
        actual="$(sha256sum "$file" | cut -d ' ' -f 1)"
    elif has_cmd shasum; then
        actual="$(shasum -a 256 "$file" | cut -d ' ' -f 1)"
    else
        warn "Cannot verify checksum: neither sha256sum nor shasum found."
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        die "Checksum mismatch for $(basename "$file").\n  Expected: $expected\n  Got:      $actual"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

GITHUB_REPO="marsolab/runlang"
INSTALL_DIR="${RUN_INSTALL_DIR:-$HOME/.run}"
VERSION="${RUN_VERSION:-}"

OS="$(detect_os)"
ARCH="$(detect_arch)"

info "Detected platform: ${OS}/${ARCH}"

# Resolve version --------------------------------------------------------

if [ -z "$VERSION" ]; then
    info "Fetching latest release version..."
    VERSION="$(http_get "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
        | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$VERSION" ]; then
        die "Could not determine the latest release version."
    fi
fi

# Strip leading "v" if present.
VERSION="$(echo "$VERSION" | sed 's/^v//')"

info "Installing Run v${VERSION}"

# Download ----------------------------------------------------------------

TARBALL="run-${VERSION}-${OS}-${ARCH}.tar.gz"
CHECKSUMS="run-${VERSION}-checksums.txt"
BASE_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading ${TARBALL}..."
http_download "${BASE_URL}/${TARBALL}" "${TMPDIR}/${TARBALL}"

info "Downloading checksums..."
http_download "${BASE_URL}/${CHECKSUMS}" "${TMPDIR}/${CHECKSUMS}"

# Verify checksum ---------------------------------------------------------

info "Verifying checksum..."
EXPECTED_HASH="$(grep "${TARBALL}" "${TMPDIR}/${CHECKSUMS}" | cut -d ' ' -f 1)"
if [ -z "$EXPECTED_HASH" ]; then
    warn "Checksum for ${TARBALL} not found in checksums file. Skipping verification."
else
    sha256_check "${TMPDIR}/${TARBALL}" "$EXPECTED_HASH"
    ok "Checksum verified."
fi

# Extract -----------------------------------------------------------------

info "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

# The tarball contains run-{ver}-{os}-{arch}/ as the top-level directory.
# We strip that prefix and install directly into $INSTALL_DIR.
tar xzf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

EXTRACTED_DIR="${TMPDIR}/run-${VERSION}-${OS}-${ARCH}"

# Copy files into install directory.
mkdir -p "${INSTALL_DIR}/bin"
mkdir -p "${INSTALL_DIR}/lib"
mkdir -p "${INSTALL_DIR}/include/run"

cp "${EXTRACTED_DIR}/bin/run"        "${INSTALL_DIR}/bin/run"
chmod +x "${INSTALL_DIR}/bin/run"

cp "${EXTRACTED_DIR}/lib/librunrt.a" "${INSTALL_DIR}/lib/librunrt.a"

for header in "${EXTRACTED_DIR}"/include/run/*.h; do
    [ -f "$header" ] && cp "$header" "${INSTALL_DIR}/include/run/"
done

# Copy LICENSE if present.
[ -f "${EXTRACTED_DIR}/LICENSE" ] && cp "${EXTRACTED_DIR}/LICENSE" "${INSTALL_DIR}/"

ok "Run v${VERSION} installed successfully!"

# PATH instructions -------------------------------------------------------

BIN_DIR="${INSTALL_DIR}/bin"
case ":${PATH:-}:" in
    *":${BIN_DIR}:"*)
        ok "'${BIN_DIR}' is already in your PATH."
        ;;
    *)
        printf "\n"
        warn "'${BIN_DIR}' is not in your PATH."
        printf "\n"
        printf "  Add it by appending one of the following to your shell profile:\n\n"

        EXPORT_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
        FISH_LINE="set -gx PATH ${BIN_DIR} \$PATH"

        printf "  # bash (~/.bashrc or ~/.bash_profile)\n"
        printf "  %s\n\n" "$EXPORT_LINE"
        printf "  # zsh (~/.zshrc)\n"
        printf "  %s\n\n" "$EXPORT_LINE"
        printf "  # fish (~/.config/fish/config.fish)\n"
        printf "  %s\n\n" "$FISH_LINE"
        printf "  # POSIX sh (~/.profile)\n"
        printf "  %s\n\n" "$EXPORT_LINE"

        # Offer to add automatically.
        if [ -t 0 ]; then
            printf "Would you like to add it automatically? [y/N] "
            read -r REPLY
            case "$REPLY" in
                [yY]|[yY][eE][sS])
                    ADDED=0
                    if [ -f "$HOME/.bashrc" ]; then
                        printf '\n# Run language compiler\n%s\n' "$EXPORT_LINE" >> "$HOME/.bashrc"
                        ok "Added to ~/.bashrc"
                        ADDED=1
                    fi
                    if [ -f "$HOME/.bash_profile" ] && [ ! -f "$HOME/.bashrc" ]; then
                        printf '\n# Run language compiler\n%s\n' "$EXPORT_LINE" >> "$HOME/.bash_profile"
                        ok "Added to ~/.bash_profile"
                        ADDED=1
                    fi
                    if [ -f "$HOME/.zshrc" ]; then
                        printf '\n# Run language compiler\n%s\n' "$EXPORT_LINE" >> "$HOME/.zshrc"
                        ok "Added to ~/.zshrc"
                        ADDED=1
                    fi
                    if [ -f "$HOME/.config/fish/config.fish" ]; then
                        printf '\n# Run language compiler\n%s\n' "$FISH_LINE" >> "$HOME/.config/fish/config.fish"
                        ok "Added to ~/.config/fish/config.fish"
                        ADDED=1
                    fi
                    if [ -f "$HOME/.profile" ]; then
                        printf '\n# Run language compiler\n%s\n' "$EXPORT_LINE" >> "$HOME/.profile"
                        ok "Added to ~/.profile"
                        ADDED=1
                    fi
                    if [ "$ADDED" = "0" ]; then
                        warn "No shell profile found. Please add the PATH manually."
                    else
                        info "Restart your shell or run 'source <profile>' to apply."
                    fi
                    ;;
                *)
                    info "Skipped. Add the PATH entry manually when you're ready."
                    ;;
            esac
        fi
        ;;
esac

printf "\n"
ok "Done! Run 'run --version' to verify."
