#!/usr/bin/env bats
# Tests for _discover_connections() — proxy discovery via SSH mock

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/remote-control/modules/ssh.sh"
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

# ssh_probe: «echo ok» отвечает ok, остальное — обнаружение.
@test "core_conn_sync: all nodes succeed and checkpoint state" {
    _prepare_connection_sync_test
    ssh_run() {
        [[ "${*: -1}" == "echo ok" ]] && { printf 'ok\n'; return 0; }
        printf '  - name: "vless-reality"\n'
        return 0
    }

    run state_action "sync_connections" core_conn_sync
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

@test "core_conn_sync: unreachable node makes the result partial and keeps the saved part" {
    _prepare_connection_sync_test
    ssh_run() {
        if [[ "$NODE_NAME" == ru-vps ]]; then
            return 1
        fi
        [[ "${*: -1}" == "echo ok" ]] && { printf 'ok\n'; return 0; }
        printf '  - name: "vless-reality"\n'
        return 0
    }

    state_action "sync_connections" core_conn_sync > "$BATS_TEST_TMPDIR/result" 2>&1 && return 1
    [ "$RC_ERROR_CODE" = partial ]
    jq -e '[.nodes[] | .status] == ["synced","unreachable"] and .ok == 1 and .failed == 1' <<< "$CONN_SYNC_JSON"
    [[ -f "$STATE_MANIFEST" ]]
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

@test "core_conn_sync: unavailable password skips discovery while valid node proceeds" {
    _prepare_unavailable_connection_node
    local missing_before
    missing_before=$(jq -c '[.connections[] | select(.node=="ru-vps")]' "$CONFIG_JSON")
    _discover_connections() {
        printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/discovered-nodes"
        printf '%s\n' vless-reality
    }
    ssh_run() {
        if [[ "${*: -1}" == "echo ok" ]]; then
            printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/probed-nodes"
            printf 'ok\n'
            return 0
        fi
        touch "$BATS_TEST_TMPDIR/ssh-calls.log"
        return 1
    }
    run core_conn_sync
    assert_failure
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered-nodes")" == de-vps ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/probed-nodes")" == de-vps ]]
    [[ "$(jq -c '[.connections[] | select(.node=="ru-vps")]' "$CONFIG_JSON")" == "$missing_before" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
}

@test "core_conn_sync: second promotion failure stops discovery and restores SSH context" {
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
        [[ "${*: -1}" == "echo ok" ]] && { printf 'ok\n'; return 0; }
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
    state_action "sync_connections" core_conn_sync \
        > "$BATS_TEST_TMPDIR/result" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 2 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered")" == $'de-vps\nru-vps' ]]
    ! grep -q 'Синхронизировано' "$BATS_TEST_TMPDIR/completed" || return 1
    jq -e '[.nodes[] | .status] == ["synced","save_failed","skipped"] and .stopped_at == "ru-vps"' <<< "$CONN_SYNC_JSON"
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

# ─── round 2: nodes ──────────────────────────────────────────────────────────

# ssh_run выполняет удалённую команду локально, /etc/mihomo — в песочнице.
_r2_local_remote() {
    mkdir -p "$BATS_TEST_TMPDIR/etc/mihomo"
    ssh_run() {
        while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
        shift
        bash -c "${1//\/etc\/mihomo/$BATS_TEST_TMPDIR/etc/mihomo}"
    }
}

@test "R2-M6: a reachable node without client-config.txt has no connections; a read error still fails" {
    _r2_local_remote
    run _discover_connections
    assert_success
    assert_output ""
    printf '  - name: "vless-reality"\n' > "$BATS_TEST_TMPDIR/etc/mihomo/client-config.txt"
    run _discover_connections
    assert_success
    assert_output "vless-reality"
    rm "$BATS_TEST_TMPDIR/etc/mihomo/client-config.txt"
    mkdir "$BATS_TEST_TMPDIR/etc/mihomo/client-config.txt"
    run _discover_connections
    assert_failure
}

@test "R2-M6: conn sync treats a node without client-config.txt as synced, not unreachable" {
    _prepare_connection_sync_test
    _r2_local_remote
    state_action "sync_connections" core_conn_sync > "$BATS_TEST_TMPDIR/result" 2>&1
    jq -e '[.nodes[] | .status] == ["synced","synced"] and .failed == 0' <<< "$CONN_SYNC_JSON"
}

@test "R2-M7: conn set failing after a saved group answers partial with the applied groups" {
    source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
    source "$PROJECT_ROOT/remote-control/modules/cli.sh"
    source "$PROJECT_ROOT/remote-control/modules/cmd_nodes.sh"
    load '../helpers/cmd_helper'
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1 CONFIG_SOURCE=local
    load_fixture_config
    eval "$(declare -f jq_w | sed '1s/jq_w/_r2_real_jq_w/')"
    R2_WRITES=0
    jq_w() { R2_WRITES=$((R2_WRITES + 1)); (( R2_WRITES != 2 )) || return 77; _r2_real_jq_w "$@"; }
    run_cmd conn set --node de-vps --group ROUTER --group PC --proxy vless-r2
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    cmd_jq '.data == {node:"de-vps", groups:["ROUTER","PC"], proxies:["vless-r2"], applied:["ROUTER"]}' | grep -qx true
    [[ -f "$STATE_MANIFEST" ]]
    jq -e '.connections[] | select(.node=="de-vps") | .groups[] | select(.name=="ROUTER") | .proxies == ["vless-r2"]' "$CONFIG_JSON"
    R2_WRITES=1
    run_cmd conn set --node de-vps --group MOBILE --proxy vless-r2
    [ "$(cmd_jq '.error.code')" = failed ]
    [ "$(cmd_jq '.data')" = null ]
}
