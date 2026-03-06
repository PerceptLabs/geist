#!/bin/bash
# test-geist.sh — Test the built geist.com binary and run NullClaw's test suite
#
# Usage:
#   ./test-geist.sh              # Run all tests
#   ./test-geist.sh --verbose    # Show full output for each test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GEIST_BIN="${GEIST_BIN:-${SCRIPT_DIR}/dist/geist.com}"
NULLCLAW_DIR="${SCRIPT_DIR}/nullclaw"
ZIG_BIN="${ZIG_BIN:-zig}"

VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $0 [--verbose]"
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# --- Colors ---
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    RESET='\033[0m'
else
    RED='' GREEN='' RESET=''
fi

PASS=0
FAIL=0

run_test() {
    local name="$1"
    shift
    local output
    local exit_code=0

    output=$("$@" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        printf "${GREEN}PASS${RESET}  %s\n" "$name"
        PASS=$((PASS + 1))
        if [ "$VERBOSE" = true ]; then
            echo "$output" | sed 's/^/      /'
        fi
    else
        printf "${RED}FAIL${RESET}  %s (exit code %d)\n" "$name" "$exit_code"
        FAIL=$((FAIL + 1))
        echo "$output" | sed 's/^/      /' | head -20
    fi
}

# --- Binary existence check ---
echo "Testing: ${GEIST_BIN}"
echo ""

if [ ! -f "$GEIST_BIN" ]; then
    echo "Binary not found: ${GEIST_BIN}"
    echo "Run ./build-geist.sh first."
    exit 1
fi

if [ ! -x "$GEIST_BIN" ]; then
    chmod +x "$GEIST_BIN"
fi

# --- CLI smoke tests ---
echo "=== CLI Smoke Tests ==="
echo ""

run_test "version"  "$GEIST_BIN" version
run_test "--help"   "$GEIST_BIN" --help
run_test "status"   "$GEIST_BIN" status
run_test "doctor"   "$GEIST_BIN" doctor

echo ""

# --- Zig test suite ---
echo "=== Zig Test Suite ==="
echo ""

if [ -d "${NULLCLAW_DIR}" ]; then
    run_test "zig-build-test" "$ZIG_BIN" build test --summary all -p "${NULLCLAW_DIR}/zig-out" --build-file "${NULLCLAW_DIR}/build.zig" --cache-dir "${NULLCLAW_DIR}/.zig-cache"
else
    printf "${RED}SKIP${RESET}  zig-build-test (nullclaw/ directory not found)\n"
fi

echo ""

# --- Summary ---
TOTAL=$((PASS + FAIL))
echo "========================================="
echo "  Results: ${PASS}/${TOTAL} passed"
if [ "$FAIL" -gt 0 ]; then
    printf "  ${RED}${FAIL} test(s) failed${RESET}\n"
fi
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
