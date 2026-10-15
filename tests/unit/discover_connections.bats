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

@test "_sync_all_connections: second promotion failure stops discovery and restores SSH context" {
    _prepare_connection_sync_test
    source_module "nodes.sh"
    jq_w '
        .nodes += [(.nodes[0] | .id="33333333333333333333333333333333" |
            .name="third-vps" | .ip="9.8.7.6")] |
        .connections += [{node:"third-vps",groups:[{name:"PC",
            proxies:["vless-reality","stale-proxy"]}]}]
    '
    NODE_ID=original-id NODE_IDENTITY=original-identity NODE_TAG=original-tag
    NODE_NAME=original-node SERVER_IP=original-ip SERVER_PORT=2200
    SERVER_USER=original-user SERVER_PASS=original-pass SERVER_AUTH=password
    local before_context
    before_context=$(printf '%s\n' "$NODE_ID" "$NODE_IDENTITY" "$NODE_TAG" "$NODE_NAME" \
        "$SERVER_IP" "$SERVER_PORT" "$SERVER_USER" "$SERVER_PASS" "$SERVER_AUTH")
    ssh_run() {
        printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/discovered"
        printf '  - name: "vless-reality"\n'
    }
    success() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/completed"; }
    local mv_real
    mv_real=$(command -v mv)
    printf '0\n' > "$BATS_TEST_TMPDIR/promotions"
    mv() {
        if [[ "$#" -eq 2 && "$1" == "$CONFIG_JSON.tmp."* && "$2" == "$CONFIG_JSON" ]]; then
            local count
            read -r count < "$BATS_TEST_TMPDIR/promotions"
            count=$((count + 1))
            printf '%s\n' "$count" > "$BATS_TEST_TMPDIR/promotions"
            [[ "$count" -eq 2 ]] && return 77
        fi
        "$mv_real" "$@"
    }
    local rc=0
    state_action "sync_connections" _sync_all_connections \
        > "$BATS_TEST_TMPDIR/result" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 2 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered")" == $'de-vps\nru-vps' ]]
    [[ ! -e "$BATS_TEST_TMPDIR/completed" ]]
    [[ ! -e "$STATE_MANIFEST" ]]
    [[ "$(printf '%s\n' "$NODE_ID" "$NODE_IDENTITY" "$NODE_TAG" "$NODE_NAME" \
        "$SERVER_IP" "$SERVER_PORT" "$SERVER_USER" "$SERVER_PASS" "$SERVER_AUTH")" == "$before_context" ]]
    run jq -e '
        (.connections[] | select(.node=="de-vps") |
            all(.groups[]; .proxies==["vless-reality"])) and
        (.connections[] | select(.node=="ru-vps") |
            all(.groups[]; .proxies==["vless-reality","stale-proxy"])) and
        (.connections[] | select(.node=="third-vps") |
            all(.groups[]; .proxies==["vless-reality","stale-proxy"]))
    ' "$CONFIG_JSON"
    assert_success
}
