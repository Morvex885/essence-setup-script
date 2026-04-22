#!/usr/bin/env bats
# Tests for _discover_connections() — proxy discovery via SSH mock

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/tests/helpers/mock_ssh.bash"
    source_module "nodes.sh"
    source_module "connections.sh"
}

teardown() {
    teardown_test_env
}

# Helper: mock ssh_run dispatching by command content
# Writes mock data to files, ssh_run reads based on the command
setup_ssh_dispatch() {
    local config_output="$1"
    local awg_output="${2:-}"
    echo "$config_output" > "$BATS_TEST_TMPDIR/mock_config"
    echo "$awg_output" > "$BATS_TEST_TMPDIR/mock_awg"
    ssh_run() {
        local args=()
        while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
        [[ "$1" == "--" ]] && shift
        local cmd="$*"
        if [[ "$cmd" == *"client-config"* ]]; then
            cat "$BATS_TEST_TMPDIR/mock_config"
        elif [[ "$cmd" == *"amnezia"* ]]; then
            cat "$BATS_TEST_TMPDIR/mock_awg"
        fi
        return 0
    }
}

@test "_discover_connections: finds vless and hy2 proxies" {
    setup_ssh_dispatch '  - name: "vless-reality"
    type: vless
    server: 1.2.3.4
  - name: "hy2-main"
    type: hysteria2
    server: 1.2.3.4' ""
    run _discover_connections
    assert_success
    assert_line "vless-reality"
    assert_line "hy2-main"
}

@test "_discover_connections: SSH failure returns error" {
    ssh_run() {
        local args=()
        while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
        [[ "$1" == "--" ]] && shift
        return 1
    }
    run _discover_connections
    assert_failure
}

@test "_discover_connections: empty config returns empty" {
    setup_ssh_dispatch "" ""
    run _discover_connections
    assert_success
    assert_output ""
}

@test "_discover_connections: deduplicates results" {
    setup_ssh_dispatch '  - name: "vless-reality"
    type: vless
  - name: "vless-reality"
    type: vless' ""
    run _discover_connections
    assert_success
    local count
    count=$(echo "$output" | grep -c "vless-reality" || true)
    [[ "$count" -eq 1 ]]
}

@test "_discover_connections: finds cascade proxies" {
    setup_ssh_dispatch '  - name: "vless-cascade [DE->RU]"
    type: vless' ""
    run _discover_connections
    assert_success
    assert_line "vless-cascade [DE->RU]"
}

@test "_discover_connections: detects AWG as single unified entry" {
    setup_ssh_dispatch '  - name: "vless-reality"
    type: vless
--- AmneziaWG ---
some awg details' ""
    run _discover_connections
    assert_success
    assert_line "AWG"
    assert_line "vless-reality"
    # Per-peer awg-* prefix больше не используется (AWG унифицирован)
    refute_line "awg-my-router"
}

@test "_discover_connections: no AmneziaWG marker — no AWG entry" {
    setup_ssh_dispatch '  - name: "vless-reality"
    type: vless' ""
    run _discover_connections
    assert_success
    assert_line "vless-reality"
    refute_line "AWG"
}
