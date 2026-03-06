#!/bin/bash
# build-geist.sh — Build geist.com from NullClaw + Cosmopolitan
#
# Usage:
#   ./build-geist.sh              # Full build (requires zig + cosmocc)
#   ./build-geist.sh --prebuilt   # Use pre-built NullClaw binaries (skip zig)
#   ./build-geist.sh --clean      # Clean build (remove nullclaw clone and dist)
#   ./build-geist.sh --skip-clone # Skip git clone/pull (for CI with pre-fetched source)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Configuration ---
NULLCLAW_REPO="https://github.com/nullclaw/nullclaw.git"
NULLCLAW_RELEASE="https://github.com/nullclaw/nullclaw/releases/latest/download"
NULLCLAW_DIR="${SCRIPT_DIR}/nullclaw"
ZIG_REQUIRED="0.15.2"
ZIG_BIN="${ZIG_BIN:-zig}"
COSMOCC_DIR="${COSMOCC_DIR:-}"
DIST_DIR="${SCRIPT_DIR}/dist"
PATCHES_DIR="${SCRIPT_DIR}/patches"
MKAPE="${SCRIPT_DIR}/mkape.py"

# --- Colors (respects NO_COLOR) ---
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

info()  { printf "${BLUE}[info]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${RESET}  %s\n" "$*"; }
error() { printf "${RED}[error]${RESET} %s\n" "$*" >&2; }
die()   { error "$*"; exit 1; }

# --- Parse flags ---
CLEAN=false
SKIP_CLONE=false
PREBUILT=false
for arg in "$@"; do
    case "$arg" in
        --clean)      CLEAN=true ;;
        --skip-clone) SKIP_CLONE=true ;;
        --prebuilt)   PREBUILT=true ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--skip-clone] [--prebuilt]"
            echo "  --clean       Remove nullclaw/ and dist/ before building"
            echo "  --skip-clone  Skip git clone/pull (use existing nullclaw/)"
            echo "  --prebuilt    Download pre-built NullClaw binaries (skip zig build)"
            exit 0
            ;;
        *) die "Unknown flag: $arg" ;;
    esac
done

# --- Clean ---
if [ "$CLEAN" = true ]; then
    info "Cleaning previous build..."
    rm -rf "${NULLCLAW_DIR}" "${DIST_DIR}"
    mkdir -p "${DIST_DIR}"
    touch "${DIST_DIR}/.gitkeep"
fi

# --- Step 1: Check prerequisites ---
info "Checking prerequisites..."
mkdir -p "${DIST_DIR}"
PATCH_COUNT=0

if [ "$PREBUILT" = true ]; then
    # --prebuilt mode: download pre-built binaries, skip zig entirely
    info "Using pre-built NullClaw binaries..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        die "Neither curl nor wget found. Install one and try again."
    fi

    fetch_file() {
        local url="$1" dest="$2"
        if command -v curl &>/dev/null; then
            curl -fsSL -o "$dest" "$url"
        else
            wget -q -O "$dest" "$url"
        fi
    }

    for arch in x86_64 aarch64; do
        local_file="${DIST_DIR}/geist-linux-${arch}"
        if [ -f "$local_file" ]; then
            info "Using existing ${local_file}"
        else
            info "Downloading nullclaw-linux-${arch}.bin..."
            fetch_file "${NULLCLAW_RELEASE}/nullclaw-linux-${arch}.bin" "$local_file"
        fi
        chmod +x "$local_file"
    done
    ok "Pre-built binaries ready"
else
    # Full build mode: requires zig + source
    if ! command -v "$ZIG_BIN" &>/dev/null; then
        die "Zig not found. Install Zig ${ZIG_REQUIRED} and ensure it's on PATH, or set ZIG_BIN."
    fi

    ZIG_VERSION=$("$ZIG_BIN" version 2>&1)
    if [ "$ZIG_VERSION" != "$ZIG_REQUIRED" ]; then
        die "Zig version mismatch: got '${ZIG_VERSION}', need exactly '${ZIG_REQUIRED}'."
    fi
    ok "Zig ${ZIG_REQUIRED}"

    # --- Get NullClaw source ---
    if [ "$SKIP_CLONE" = false ]; then
        if [ -d "${NULLCLAW_DIR}/.git" ]; then
            info "Updating NullClaw..."
            git -C "${NULLCLAW_DIR}" pull --ff-only
        else
            info "Cloning NullClaw..."
            git clone "${NULLCLAW_REPO}" "${NULLCLAW_DIR}"
        fi
        ok "NullClaw source at ${NULLCLAW_DIR}"
    else
        [ -d "${NULLCLAW_DIR}" ] || die "NullClaw directory not found at ${NULLCLAW_DIR} (--skip-clone requires it to exist)"
        info "Skipping clone (--skip-clone)"
    fi

    # --- Apply patches ---
    if [ -d "${PATCHES_DIR}" ]; then
        for patch in "${PATCHES_DIR}"/*.patch; do
            [ -f "$patch" ] || continue
            info "Applying patch: $(basename "$patch")"
            git -C "${NULLCLAW_DIR}" apply "$patch"
            PATCH_COUNT=$((PATCH_COUNT + 1))
        done
    fi
    if [ "$PATCH_COUNT" -gt 0 ]; then
        ok "Applied ${PATCH_COUNT} patch(es)"
    else
        info "No patches to apply"
    fi

    # --- Build x86_64 ---
    info "Building x86_64..."
    cd "${NULLCLAW_DIR}"
    "$ZIG_BIN" build -Doptimize=ReleaseSmall -Dengines=base,sqlite -Dtarget=x86_64-linux
    cp zig-out/bin/nullclaw "${DIST_DIR}/geist-linux-x86_64"
    ok "x86_64 binary: $(du -h "${DIST_DIR}/geist-linux-x86_64" | cut -f1)"

    # --- Build aarch64 ---
    info "Building aarch64..."
    "$ZIG_BIN" build -Doptimize=ReleaseSmall -Dengines=base,sqlite -Dtarget=aarch64-linux
    cp zig-out/bin/nullclaw "${DIST_DIR}/geist-linux-aarch64"
    ok "aarch64 binary: $(du -h "${DIST_DIR}/geist-linux-aarch64" | cut -f1)"
    cd "${SCRIPT_DIR}"
fi

# --- Link fat APE binary ---
# Try apelink first, fall back to mkape.py
find_cosmo_tool() {
    local tool="$1"
    if [ -n "$COSMOCC_DIR" ] && [ -x "${COSMOCC_DIR}/bin/${tool}" ]; then
        echo "${COSMOCC_DIR}/bin/${tool}"
        return
    fi
    if command -v "$tool" &>/dev/null; then
        command -v "$tool"
        return
    fi
    return 1
}

USE_MKAPE=false
if APELINK=$(find_cosmo_tool apelink 2>/dev/null); then
    COSMO_BIN_DIR="$(dirname "$APELINK")"
    APE_X86_64="${COSMO_BIN_DIR}/ape-x86_64.elf"
    APE_AARCH64="${COSMO_BIN_DIR}/ape-aarch64.elf"
    APE_M1_C="${COSMO_BIN_DIR}/ape-m1.c"

    if [ -f "$APE_X86_64" ] && [ -f "$APE_AARCH64" ] && [ -f "$APE_M1_C" ]; then
        info "Linking fat APE binary with apelink..."
        if "$APELINK" \
            -l "$APE_X86_64" \
            -l "$APE_AARCH64" \
            -M "$APE_M1_C" \
            -o "${DIST_DIR}/geist.com" \
            "${DIST_DIR}/geist-linux-x86_64" \
            "${DIST_DIR}/geist-linux-aarch64" 2>/dev/null; then
            ok "Fat APE (apelink): $(du -h "${DIST_DIR}/geist.com" | cut -f1)"
        else
            warn "apelink failed (exit $?), falling back to mkape.py"
            rm -f "${DIST_DIR}/geist.com"
            USE_MKAPE=true
        fi
    else
        USE_MKAPE=true
    fi
else
    USE_MKAPE=true
fi

if [ "$USE_MKAPE" = true ]; then
    if [ -f "$MKAPE" ] && command -v python3 &>/dev/null; then
        info "apelink not available, using mkape.py fallback..."
        python3 "$MKAPE" \
            -o "${DIST_DIR}/geist.com" \
            --x86_64 "${DIST_DIR}/geist-linux-x86_64" \
            --aarch64 "${DIST_DIR}/geist-linux-aarch64"
        ok "Fat APE (mkape.py): $(du -h "${DIST_DIR}/geist.com" | cut -f1)"
    else
        die "Neither apelink nor mkape.py+python3 available. Install cosmocc or ensure python3 is on PATH."
    fi
fi

# --- Step 7: Checksums ---
info "Generating checksums..."
cd "${DIST_DIR}"
sha256sum geist.com geist-linux-x86_64 geist-linux-aarch64 > checksums.txt
cd "${SCRIPT_DIR}"
ok "Checksums written to dist/checksums.txt"

# --- Step 8: Smoke test ---
info "Running smoke test..."
if "${DIST_DIR}/geist.com" version &>/dev/null; then
    ok "geist.com version — passed"
else
    warn "geist.com version — failed (binary may not run on this platform)"
fi

# --- Report ---
echo ""
echo "========================================="
echo "  Geist Build Complete"
echo "========================================="
echo ""
printf "  %-25s %s\n" "geist.com (fat APE):" "$(du -h "${DIST_DIR}/geist.com" | cut -f1)"
printf "  %-25s %s\n" "geist-linux-x86_64:" "$(du -h "${DIST_DIR}/geist-linux-x86_64" | cut -f1)"
printf "  %-25s %s\n" "geist-linux-aarch64:" "$(du -h "${DIST_DIR}/geist-linux-aarch64" | cut -f1)"
printf "  %-25s %s\n" "Patches applied:" "${PATCH_COUNT}"
echo ""
echo "  Artifacts in: ${DIST_DIR}/"
echo ""
