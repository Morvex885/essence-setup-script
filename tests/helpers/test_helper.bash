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
    export BATS_TEST_TMPDIR="$(mktemp -d)"
    export CONFIG_DIR="$BATS_TEST_TMPDIR"
    export CONFIG_JSON="$BATS_TEST_TMPDIR/config.json"
    export TEMPLATES_DIR="$BATS_TEST_TMPDIR/templates"
    export GENERATED_DIR="$BATS_TEST_TMPDIR/generated"
    export SCRIPT_DIR="$BATS_TEST_TMPDIR"
    mkdir -p "$TEMPLATES_DIR" "$GENERATED_DIR"

    # Write minimal valid config matching _ensure_config structure
    cat > "$CONFIG_JSON" <<'EOF'
{"nodes":[],"groups":[{"name":"ROUTER","template":"default.yaml"},{"name":"PC","template":"default.yaml"},{"name":"MOBILE","template":"default.yaml"}],"clients":[],"connections":[]}
EOF
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

# Source a remote-control module (requires common.sh already loaded)
source_module() {
    local module="$1"
    source "$PROJECT_ROOT/remote-control/modules/$module"
}

# ─── Deterministic overrides ──────────────────────────────────────────────────

# Override _pass_key to return a deterministic key for encryption tests
override_pass_key() {
    _pass_key() {
        echo "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"
    }
}

# ─── Fixture loading ──────────────────────────────────────────────────────────

FIXTURES_DIR="$TESTS_DIR/fixtures"

load_fixture_config() {
    cp "$FIXTURES_DIR/sample_config.json" "$CONFIG_JSON"
}

load_fixture_template() {
    cp "$FIXTURES_DIR/sample_template.yaml" "$TEMPLATES_DIR/default.yaml"
}

load_fixture_client_config() {
    cat "$FIXTURES_DIR/sample_client_config.txt"
}
