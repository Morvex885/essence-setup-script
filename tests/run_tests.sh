#!/bin/bash
# ─── Test runner for essence-setup ─────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 3 || ( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf '  [✗] Требуется Bash 3.2 или новее.\n' >&2
    exit 1
fi

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
        "${BASH:-bash}" "$BATS" "$SCRIPT_DIR/unit/" --recursive
        ;;
    --fuzz)
        "${BASH:-bash}" "$BATS" "$SCRIPT_DIR/fuzz/" --recursive
        ;;
    --all)
        "${BASH:-bash}" "$BATS" "$SCRIPT_DIR/unit/" --recursive
        echo ""
        "${BASH:-bash}" "$BATS" "$SCRIPT_DIR/fuzz/" --recursive
        ;;
    --ci)
        "${BASH:-bash}" "$BATS" "$SCRIPT_DIR/unit/" --recursive --tap
        echo ""
        FUZZ_ITERATIONS=100 "${BASH:-bash}" "$BATS" "$SCRIPT_DIR/fuzz/" --recursive --tap
        ;;
    *)
        echo "Usage: $0 [--unit|--fuzz|--all|--ci]"
        exit 1
        ;;
esac
