#!/bin/bash
# ─── BATS Test Helper ──────────────────────────────────────────────────────────
# Shared setup for all test files. Source this via: load '../helpers/test_helper'

# Resolve project root (two levels up from tests/helpers/)
TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$TEST_HELPERS_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Load BATS libraries
load "$TESTS_DIR/lib/bats-support/load"
load "$TESTS_DIR/lib/bats-assert/load"

# ─── Setup temp environment ───────────────────────────────────────────────────

setup_test_env() {
    BATS_TEST_TMPDIR="$(mktemp -d)"
    export BATS_TEST_TMPDIR
}

# The executor (node-agent/) is Bash 4+ with a GNU userland on Debian/Ubuntu:
# its tests skip elsewhere instead of failing on `mapfile`/`local -A`.
require_executor_env() {
    [[ "$(uname -s)" == Linux ]] || skip "Исполнитель node-agent проверяется только на Linux"
    local major
    major=$(bash -c 'echo "${BASH_VERSINFO[0]}"')
    (( major >= 4 )) || skip "Исполнитель node-agent требует Bash 4+ (bash в PATH — версия ${major})"
}

teardown_test_env() {
    [[ -d "${BATS_TEST_TMPDIR:-}" ]] && rm -rf "$BATS_TEST_TMPDIR"
}

# ─── Source project modules safely ─────────────────────────────────────────────

# Source common.sh with error() override to prevent exit
source_common() {
    source "$PROJECT_ROOT/common/common.sh"
    # Override error() to not exit the test runner
    error() { echo -e "  ${RED}[✗]${NC} $*" >&2; return 1; }
}
