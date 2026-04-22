#!/bin/bash
# ─── Test runner for essence-setup ─────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS="$SCRIPT_DIR/lib/bats-core/bin/bats"

# Check BATS is available
if [[ ! -x "$BATS" ]]; then
    echo "ERROR: BATS not found. Run: git submodule update --init --recursive"
    exit 1
fi

# Check dependencies
for cmd in jq openssl bash; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required tool '$cmd' not found."
        exit 1
    fi
done

MODE="${1:---all}"

case "$MODE" in
    --unit)
        echo "Running unit tests..."
        "$BATS" "$SCRIPT_DIR/unit/" --recursive
        ;;
    --fuzz)
        echo "Running fuzz tests (FUZZ_ITERATIONS=${FUZZ_ITERATIONS:-100})..."
        "$BATS" "$SCRIPT_DIR/fuzz/" --recursive
        ;;
    --all)
        echo "Running unit tests..."
        "$BATS" "$SCRIPT_DIR/unit/" --recursive
        echo ""
        echo "Running fuzz tests (FUZZ_ITERATIONS=${FUZZ_ITERATIONS:-100})..."
        "$BATS" "$SCRIPT_DIR/fuzz/" --recursive
        ;;
    --ci)
        echo "Running unit tests (TAP output)..."
        "$BATS" "$SCRIPT_DIR/unit/" --recursive --tap
        echo ""
        echo "Running fuzz tests (FUZZ_ITERATIONS=100)..."
        FUZZ_ITERATIONS=100 "$BATS" "$SCRIPT_DIR/fuzz/" --recursive --tap
        ;;
    *)
        echo "Usage: $0 [--unit|--fuzz|--all|--ci]"
        exit 1
        ;;
esac
