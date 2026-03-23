#!/usr/bin/env bash
#
# codesign-macos.sh — Sign and notarize macOS binaries for distribution.
#
# This script handles three operations:
#   1. Import a Developer ID certificate into a temporary keychain
#   2. Code-sign binaries with the imported identity
#   3. Notarize a DMG with Apple's notary service and staple the ticket
#
# Usage:
#   # Import certificate (run once per CI job)
#   ./scripts/codesign-macos.sh import \
#       --certificate-base64 "$CERT_B64" \
#       --certificate-password "$CERT_PASS" \
#       --keychain-password "$KC_PASS"
#
#   # Sign a binary or set of binaries
#   ./scripts/codesign-macos.sh sign \
#       --identity "$SIGNING_IDENTITY" \
#       --file path/to/binary [--file another/binary]
#
#   # Notarize a DMG
#   ./scripts/codesign-macos.sh notarize \
#       --apple-id "$APPLE_ID" \
#       --team-id "$TEAM_ID" \
#       --password "$APP_SPECIFIC_PASSWORD" \
#       --file path/to/file.dmg
#
#   # Clean up the temporary keychain
#   ./scripts/codesign-macos.sh cleanup
#

set -euo pipefail

KEYCHAIN_NAME="run-build.keychain-db"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN_NAME}"

# ---------------------------------------------------------------------------
# import — Import a .p12 certificate into a temporary keychain.
# ---------------------------------------------------------------------------
cmd_import() {
    local cert_b64=""
    local cert_pass=""
    local kc_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --certificate-base64) cert_b64="$2"; shift 2 ;;
            --certificate-password) cert_pass="$2"; shift 2 ;;
            --keychain-password) kc_pass="$2"; shift 2 ;;
            *) echo "Error: unknown argument for import: $1" >&2; exit 1 ;;
        esac
    done

    if [[ -z "$cert_b64" || -z "$cert_pass" || -z "$kc_pass" ]]; then
        echo "Error: --certificate-base64, --certificate-password, and --keychain-password are required." >&2
        exit 1
    fi

    echo "==> Creating temporary keychain..."
    security create-keychain -p "$kc_pass" "$KEYCHAIN_NAME"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
    security unlock-keychain -p "$kc_pass" "$KEYCHAIN_PATH"

    echo "==> Importing certificate..."
    local cert_file
    cert_file="$(mktemp /tmp/cert.XXXXXX.p12)"
    echo "$cert_b64" | base64 --decode > "$cert_file"

    security import "$cert_file" \
        -k "$KEYCHAIN_PATH" \
        -P "$cert_pass" \
        -T /usr/bin/codesign \
        -T /usr/bin/productsign

    rm -f "$cert_file"

    # Allow codesign to access the keychain without prompting.
    security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
        -s -k "$kc_pass" "$KEYCHAIN_PATH"

    # Add the temporary keychain to the search list.
    local keychains
    keychains="$(security list-keychains -d user | tr -d '"')"
    security list-keychains -d user -s "$KEYCHAIN_PATH" $keychains

    echo "==> Certificate imported successfully."
}

# ---------------------------------------------------------------------------
# sign — Code-sign one or more files with the given identity.
# ---------------------------------------------------------------------------
cmd_sign() {
    local identity=""
    local files=()
    local entitlements=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --identity) identity="$2"; shift 2 ;;
            --file) files+=("$2"); shift 2 ;;
            --entitlements) entitlements="$2"; shift 2 ;;
            *) echo "Error: unknown argument for sign: $1" >&2; exit 1 ;;
        esac
    done

    if [[ -z "$identity" || ${#files[@]} -eq 0 ]]; then
        echo "Error: --identity and at least one --file are required." >&2
        exit 1
    fi

    local codesign_args=(
        --force
        --options runtime
        --timestamp
        --sign "$identity"
    )

    if [[ -n "$entitlements" ]]; then
        codesign_args+=(--entitlements "$entitlements")
    fi

    for file in "${files[@]}"; do
        echo "==> Signing: ${file}"
        codesign "${codesign_args[@]}" "$file"
        echo "    Verifying signature..."
        codesign --verify --verbose=2 "$file"
    done

    echo "==> All files signed successfully."
}

# ---------------------------------------------------------------------------
# notarize — Submit a file to Apple's notary service and staple the ticket.
# ---------------------------------------------------------------------------
cmd_notarize() {
    local apple_id=""
    local team_id=""
    local password=""
    local file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apple-id) apple_id="$2"; shift 2 ;;
            --team-id) team_id="$2"; shift 2 ;;
            --password) password="$2"; shift 2 ;;
            --file) file="$2"; shift 2 ;;
            *) echo "Error: unknown argument for notarize: $1" >&2; exit 1 ;;
        esac
    done

    if [[ -z "$apple_id" || -z "$team_id" || -z "$password" || -z "$file" ]]; then
        echo "Error: --apple-id, --team-id, --password, and --file are required." >&2
        exit 1
    fi

    echo "==> Submitting ${file} for notarization..."
    xcrun notarytool submit "$file" \
        --apple-id "$apple_id" \
        --team-id "$team_id" \
        --password "$password" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$file"

    echo "==> Notarization complete."
}

# ---------------------------------------------------------------------------
# cleanup — Remove the temporary keychain.
# ---------------------------------------------------------------------------
cmd_cleanup() {
    echo "==> Cleaning up temporary keychain..."
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    echo "==> Cleanup complete."
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 {import|sign|notarize|cleanup} [options]" >&2
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    import)    cmd_import "$@" ;;
    sign)      cmd_sign "$@" ;;
    notarize)  cmd_notarize "$@" ;;
    cleanup)   cmd_cleanup "$@" ;;
    *)         echo "Error: unknown command: $COMMAND" >&2; exit 1 ;;
esac
