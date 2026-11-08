#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "connections.sh"
    source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
    source "$PROJECT_ROOT/remote-control/modules/ssh.sh"
    source "$PROJECT_ROOT/remote-control/modules/awg_peers.sh"
    source "$PROJECT_ROOT/remote-control/modules/telegram-proxy.sh"
    source "$PROJECT_ROOT/remote-control/modules/cli.sh"
    source "$PROJECT_ROOT/remote-control/modules/cmd_nodes.sh"
    load '../helpers/cmd_helper'
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1
    CONFIG_SOURCE=local
    load_fixture_config
    jq_w '
        .nodes += [(.nodes[0] | .id="33333333333333333333333333333333" |
            .name="third-vps" | .ip="9.8.7.6")] |
        .connections = [.nodes[] | {node:.name,groups:[
            {name:"ROUTER",proxies:["vless-reality","stale-proxy"]},
            {name:"PC",proxies:["stale-proxy"]},
            {name:"MOBILE",proxies:["stale-proxy"]}]}]
    '
    NODE_ID=original-id NODE_IDENTITY=original-identity NODE_TAG=original-tag
    NODE_NAME=original-node SERVER_IP=original-ip SERVER_PORT=2200
    SERVER_USER=original-user SERVER_PASS=original-pass SERVER_AUTH=password
}

teardown() {
    teardown_test_env
}

_fail_second_promotion() {
    MV_REAL=$(command -v mv)
    printf '0\n' > "$BATS_TEST_TMPDIR/promotions"
    mv() {
        if [[ "$#" -eq 2 && "$1" == "$CONFIG_JSON.tmp."* && "$2" == "$CONFIG_JSON" ]]; then
            local count
            read -r count < "$BATS_TEST_TMPDIR/promotions"
            count=$((count + 1))
            printf '%s\n' "$count" > "$BATS_TEST_TMPDIR/promotions"
            [[ "$count" -eq 2 ]] && return 77
        fi
        "$MV_REAL" "$@"
    }
}

_menu_discovery() {
    ssh_run() {
        [[ "${*: -1}" == "echo ok" ]] && { printf 'ok\n'; return 0; }
        printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/discovered"
        printf '  - name: "vless-reality"\n'
    }
}

@test "conn set to several groups retains first group and stops after second promotion failure" {
    _fail_second_promotion
    run_cmd conn set --node de-vps --group ROUTER --group PC --group MOBILE --proxy vless-reality
    [[ "$status" -ne 0 ]]
    [ "$(cmd_jq '.error.code')" = partial ]
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 2 ]]
    [[ -e "$STATE_MANIFEST" ]]
    run jq -e '
        (.connections[] | select(.node=="de-vps") | .groups) as $groups |
        ($groups[] | select(.name=="ROUTER") | .proxies==["vless-reality"]) and
        ($groups[] | select(.name=="PC") | .proxies==["stale-proxy"]) and
        ($groups[] | select(.name=="MOBILE") | .proxies==["stale-proxy"])
    ' "$CONFIG_JSON"
    assert_success
}

@test "conn sync stops at the first save failure and reports partial with per-node data" {
    _menu_discovery
    _fail_second_promotion
    run_cmd conn sync
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 2 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered")" == $'de-vps\nru-vps' ]]
    [ "$(cmd_jq '[.data.nodes[] | .status] | join(",")')" = synced,save_failed,skipped ]
    cmd_jq '.data | .ok == 1 and .failed == 1 and .total == 3 and .stopped_at == "ru-vps"' | grep -qx true
    [ "$(cmd_jq '.data.nodes[0].removed | join(",")')" = stale-proxy ]
    [ "$(cmd_jq '.data.nodes[0].discovered | join(",")')" = vless-reality ]
    [ "$(cmd_jq '.data.nodes[2].discovered')" = null ]
    # partial: сохранённая часть фиксируется точкой восстановления.
    [[ -f "$STATE_MANIFEST" ]]
    [[ "$NODE_NAME" == original-node && "$SERVER_PASS" == original-pass ]]
    run jq -e '
        (.connections[] | select(.node=="de-vps") | .groups |
            all(.[]; .name=="ROUTER" and .proxies==["vless-reality"])) and
        (.connections[] | select(.node=="third-vps") | .groups |
            any(.[]; .name=="PC" and .proxies==["stale-proxy"]))
    ' "$CONFIG_JSON"
    assert_success
}

@test "conn sync can be retried after a failed attempt" {
    _menu_discovery
    _fail_second_promotion
    run_cmd conn sync
    run_cmd conn sync
    [ "$status" -eq 0 ]
    assert_success
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 5 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered")" == $'de-vps\nru-vps\nde-vps\nru-vps\nthird-vps' ]]
    [[ -f "$STATE_MANIFEST" ]]
    run jq -e 'all(.connections[]; .groups==[{name:"ROUTER",proxies:["vless-reality"]}])' "$CONFIG_JSON"
    assert_success
}

@test "conn sync skips unreachable nodes and separates SSH failure from an empty result" {
    ssh_run() {
        [[ "$NODE_NAME" == ru-vps ]] && return 255
        [[ "${*: -1}" == "echo ok" ]] && { printf 'ok\n'; return 0; }
        [[ "$NODE_NAME" == third-vps ]] && return 0
        printf '  - name: "vless-reality"\n'
    }
    run_cmd conn sync
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq '[.data.nodes[] | .status] | join(",")')" = synced,unreachable,synced ]
    # Пустой результат третьей ноды — валидный: устаревшие назначения сняты.
    [ "$(cmd_jq '.data.nodes[2].discovered | length')" = 0 ]
    [ "$(jq_r '[.connections[] | select(.node=="third-vps")] | length')" = 0 ]
    [ "$(jq_r '[.connections[] | select(.node=="ru-vps") | .groups[].proxies[]] | length')" = 4 ]
    run_cmd conn sync --node missing
    [ "$(cmd_jq '.error.code')" = not_found ]
}

@test "conn list --discover probes SSH before discovery" {
    ssh_run() { printf 'Connection refused\n'; return 255; }
    run_cmd conn list --node de-vps --discover
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ "$(cmd_jq '.error.reason')" = "Connection refused" ]
    _menu_discovery
    run_cmd conn list --node de-vps --discover
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data[0].discovered | join(",")')" = vless-reality ]
}

# ─── AmneziaWG ───────────────────────────────────────────────────────────────

_awg_node() {
    _awg_expected_peers() { printf 'alpha\nbeta\n'; }
    ensure_remote_scripts_current() { printf 'upload\n' >> "$BATS_TEST_TMPDIR/awg.calls"; }
    ssh_run() {
        local cmd="${*: -1}"
        printf '%s\n' "$cmd" >> "$BATS_TEST_TMPDIR/awg.calls"
        case "$cmd" in
            'echo ok') [[ "${AWG_SSH_DOWN:-0}" == 1 ]] && return 255; printf 'ok\n' ;;
            *NO_AWG*) printf 'AWG_OK\nalpha\norphan1\n' ;;
        esac
    }
}

@test "awg status probes SSH and classifies peers" {
    _awg_node
    run_cmd awg status --node de-vps
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '[.data.peers[] | "\(.name):\(.status)"] | join(",")')" = alpha:used,orphan1:orphan,beta:missing ]
    AWG_SSH_DOWN=1 run_cmd awg status --node de-vps
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ "$(grep -c NO_AWG "$BATS_TEST_TMPDIR/awg.calls")" = 1 ]
}

@test "awg remove needs --yes and re-reads state; awg sync creates the missing peers" {
    _awg_node
    run_cmd awg remove --node de-vps --orphans
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    ! grep -q remove_awg_peer_by_name "$BATS_TEST_TMPDIR/awg.calls" || return 1
    run_cmd awg remove --node de-vps --orphans --yes
    [ "$status" -eq 0 ]
    grep -q 'remove_awg_peer_by_name orphan1' "$BATS_TEST_TMPDIR/awg.calls"
    run_cmd awg sync --node de-vps
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.created | join(",")')" = beta ]
    grep -q 'add_awg_peer_auto beta' "$BATS_TEST_TMPDIR/awg.calls"
}

# ─── Telegram ────────────────────────────────────────────────────────────────

@test "telegram menu needs a terminal and confirms a script upload" {
    _rc_tty_available() { return 1; }
    run_cmd telegram menu --node de-vps
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = tty_required ]
    _rc_tty_available() { return 0; }
    _telegram_proxy_remote_preflight() {
        _telegram_proxy_remote_clear_plan
        TELEGRAM_PROXY_PLAN_INDEX=(1) TELEGRAM_PROXY_PLAN_NAME=(de-vps)
        TELEGRAM_PROXY_PLAN_IP=(1.2.3.4) TELEGRAM_PROXY_PLAN_PORT=(22)
        TELEGRAM_PROXY_PLAN_STATE=(upload) TELEGRAM_PROXY_PLAN_REASON=("")
        TELEGRAM_PROXY_PLAN_FINGERPRINT=fp TELEGRAM_PROXY_PLAN_VERSION=1.2.3
    }
    _telegram_proxy_remote_execute_prepared() { touch "$BATS_TEST_TMPDIR/executed"; }
    run_cmd telegram menu --node de-vps
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmd_jq '.error.plan | any(test("будут загружены скрипты v1.2.3"))' | grep -qx true
    [ ! -e "$BATS_TEST_TMPDIR/executed" ]
    run_cmd telegram menu --node missing
    [ "$(cmd_jq '.error.code')" = not_found ]
}
