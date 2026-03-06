#!/bin/sh
# install.sh — Install Geist (single-file autonomous AI agent)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/PerceptLabs/geist/main/install.sh | sh
#
# Environment variables:
#   GEIST_VERSION   Version to install (default: latest)
#   INSTALL_DIR     Where to place the binary (auto-detected)
set -eu

GEIST_VERSION="${GEIST_VERSION:-latest}"
GITHUB_REPO="PerceptLabs/geist"
BINARY_NAME="geist"

# --- Helpers ---
info()  { printf '[geist] %s\n' "$*"; }
error() { printf '[geist] ERROR: %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# --- Platform detection ---
detect_platform() {
    ARCH=$(uname -m)
    OS=$(uname -s)

    case "$ARCH" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)   ARCH="aarch64" ;;
        *)               die "Unsupported architecture: ${ARCH}. Geist requires x86_64 or aarch64." ;;
    esac

    case "$OS" in
        Linux|Darwin|FreeBSD|OpenBSD|NetBSD)
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS="Windows"
            ;;
        *)
            die "Unsupported OS: ${OS}. Geist supports Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD."
            ;;
    esac

    info "Detected platform: ${OS} ${ARCH}"
}

# --- Install directory ---
detect_install_dir() {
    if [ -n "${INSTALL_DIR:-}" ]; then
        return
    fi

    if [ "$(id -u)" = "0" ]; then
        INSTALL_DIR="/usr/local/bin"
    else
        INSTALL_DIR="${HOME}/.local/bin"
    fi

    # Create if needed
    if [ ! -d "$INSTALL_DIR" ]; then
        info "Creating ${INSTALL_DIR}..."
        mkdir -p "$INSTALL_DIR"
    fi

    # Warn if not on PATH
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            info "WARNING: ${INSTALL_DIR} is not on your PATH."
            info "Add it with: export PATH=\"${INSTALL_DIR}:\$PATH\""
            ;;
    esac
}

# --- Download tool ---
fetch() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    else
        die "Neither curl nor wget found. Install one and try again."
    fi
}

# --- Resolve version ---
resolve_version() {
    if [ "$GEIST_VERSION" = "latest" ]; then
        info "Fetching latest version..."
        local release_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        local tmpfile
        tmpfile=$(mktemp)
        fetch "$release_url" "$tmpfile"

        # Extract tag_name from JSON (basic parsing without jq)
        GEIST_VERSION=$(grep '"tag_name"' "$tmpfile" | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        rm -f "$tmpfile"

        if [ -z "$GEIST_VERSION" ]; then
            die "Could not determine latest version. Set GEIST_VERSION manually."
        fi
    fi

    info "Version: ${GEIST_VERSION}"
}

# --- Download and verify ---
download_and_verify() {
    local base_url="https://github.com/${GITHUB_REPO}/releases/download/${GEIST_VERSION}"
    local tmpdir
    tmpdir=$(mktemp -d)

    # geist.com is a fat APE binary — same file for all platforms
    info "Downloading geist.com..."
    fetch "${base_url}/geist.com" "${tmpdir}/geist.com"

    info "Downloading checksums..."
    fetch "${base_url}/checksums.txt" "${tmpdir}/checksums.txt"

    # Verify checksum
    info "Verifying checksum..."
    local expected
    expected=$(grep "geist.com" "${tmpdir}/checksums.txt" | head -1 | awk '{print $1}')

    if [ -z "$expected" ]; then
        die "Could not find checksum for geist.com in checksums.txt"
    fi

    local actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${tmpdir}/geist.com" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "${tmpdir}/geist.com" | awk '{print $1}')
    else
        info "WARNING: No sha256sum or shasum found. Skipping checksum verification."
        actual="$expected"
    fi

    if [ "$actual" != "$expected" ]; then
        die "Checksum mismatch! Expected: ${expected}, Got: ${actual}"
    fi

    info "Checksum verified."

    DOWNLOADED_FILE="${tmpdir}/geist.com"
}

# --- Install ---
do_install() {
    local dest="${INSTALL_DIR}/${BINARY_NAME}"

    info "Installing to ${dest}..."
    cp "$DOWNLOADED_FILE" "$dest"
    chmod +x "$dest"

    # Clean up temp files
    rm -rf "$(dirname "$DOWNLOADED_FILE")"

    # Verify
    if "$dest" version >/dev/null 2>&1; then
        info "Installed successfully!"
        "$dest" version
    else
        info "Installed to ${dest} (could not verify — try running 'geist version')"
    fi
}

# --- Main ---
main() {
    info "Installing Geist..."
    echo ""

    detect_platform
    detect_install_dir
    resolve_version
    download_and_verify
    do_install

    echo ""
    info "Next step: run 'geist onboard' to configure your AI provider."
}

main
