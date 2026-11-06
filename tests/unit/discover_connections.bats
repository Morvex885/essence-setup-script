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

_prepare_connection_sync_test() {
    CONFIG_SOURCE=local
    source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
    load_fixture_config
    jq_w '.connections |= map(.groups |= map(.proxies = ["vless-reality", "stale-proxy"]))'
    NODE_NAME=initial
    SERVER_IP=127.0.0.1
    SERVER_PORT=22
    SERVER_USER=test
    SERVER_PASS=
    SERVER_AUTH=key
    node_load_by_name() {
        NODE_NAME="$1"
        return 0
    }
}

@test "_sync_all_connections: all nodes succeed and checkpoint state" {
    _prepare_connection_sync_test
    ssh_run() {
        printf '  - name: "vless-reality"\n'
        return 0
    }

    run state_action "sync_connections" _sync_all_connections
    assert_success
    [[ -f "$STATE_MANIFEST" ]]
    run jq -e '
        (.connections[] | select(.node == "de-vps") | .groups[].proxies) |
        (index("vless-reality") != null and index("stale-proxy") == null)
    ' "$CONFIG_JSON"
    assert_success
    run jq -e '
        (.connections[] | select(.node == "ru-vps") | .groups[].proxies) |
        (index("vless-reality") != null and index("stale-proxy") == null)
    ' "$CONFIG_JSON"
    assert_success
}

@test "_sync_all_connections: partial failure returns error without checkpoint" {
    _prepare_connection_sync_test
    ssh_run() {
        if [[ "$NODE_NAME" == ru-vps ]]; then
            return 1
        fi
        printf '  - name: "vless-reality"\n'
        return 0
    }

    run state_action "sync_connections" _sync_all_connections
    assert_failure
    [[ ! -e "$STATE_MANIFEST" ]]
    run jq -e '
        (.connections[] | select(.node == "de-vps") | .groups[].proxies) |
        (index("vless-reality") != null and index("stale-proxy") == null)
    ' "$CONFIG_JSON"
    assert_success
    run jq -e '
        (.connections[] | select(.node == "ru-vps") | .groups[].proxies) |
        (index("vless-reality") != null and index("stale-proxy") != null)
    ' "$CONFIG_JSON"
    assert_success
}

_prepare_unavailable_connection_node() {
    override_pass_key
    load_fixture_config
    node_load 1
    node_secret_delete "$(jq_r '.nodes[1].id')"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    _discover_connections() {
        touch "$BATS_TEST_TMPDIR/discovery"
        printf '%s\n' vless-reality
    }
    ssh_run() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
}

@test "_configure_node_connections: unavailable password never discovers or mutates previous node" {
    _prepare_unavailable_connection_node
    local previous="$NODE_NAME" rc=0
    _configure_node_connections 2 || rc=$?
    [[ "$rc" == 1 ]]
    [[ "$NODE_NAME" == "$previous" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/discovery" && ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
}

@test "_rename_connections: unavailable password never discovers or mutates previous node" {
    _prepare_unavailable_connection_node
    local previous="$NODE_NAME" rc=0
    _rename_connections <<< "2" || rc=$?
    [[ "$rc" == 1 ]]
    [[ "$NODE_NAME" == "$previous" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/discovery" && ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
}

@test "_sync_all_connections: unavailable password skips discovery while valid node proceeds" {
    _prepare_unavailable_connection_node
    local missing_before
    missing_before=$(jq -c '[.connections[] | select(.node=="ru-vps")]' "$CONFIG_JSON")
    _discover_connections() {
        printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/discovered-nodes"
        printf '%s\n' vless-reality
    }
    run _sync_all_connections
    assert_failure
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered-nodes")" == de-vps ]]
    [[ "$(jq -c '[.connections[] | select(.node=="ru-vps")]' "$CONFIG_JSON")" == "$missing_before" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
}
