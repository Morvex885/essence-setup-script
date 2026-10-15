#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "connections.sh"
    source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
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
        printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/discovered"
        printf '  - name: "vless-reality"\n'
    }
}

@test "batch assignment retains first group and stops after second promotion failure" {
    GRP_LIST=(ROUTER PC MOBILE)
    toggle_select() {
        local i
        for i in "${!TOGGLE_SELECT_FLAGS[@]}"; do
            TOGGLE_SELECT_FLAGS[$i]=1
        done
    }
    _fail_second_promotion
    local rc=0
    state_action "assign_connections" _batch_assign_connections de-vps vless-reality \
        > "$BATS_TEST_TMPDIR/result" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 2 ]]
    [[ ${#TOGGLE_SELECT_ITEMS[@]} -eq 0 ]]
    [[ ${#TOGGLE_SELECT_FLAGS[@]} -eq 0 ]]
    [[ ! -e "$STATE_MANIFEST" ]]
    run jq -e '
        (.connections[] | select(.node=="de-vps") | .groups) as $groups |
        ($groups[] | select(.name=="ROUTER") | .proxies==["vless-reality"]) and
        ($groups[] | select(.name=="PC") | .proxies==["stale-proxy"]) and
        ($groups[] | select(.name=="MOBILE") | .proxies==["stale-proxy"])
    ' "$CONFIG_JSON"
    assert_success
}

@test "connections menu stays available without repeating failed automatic synchronization" {
    _menu_discovery
    _fail_second_promotion
    run connections_menu <<< $'x\n\n0'
    assert_success
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 2 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered")" == $'de-vps\nru-vps' ]]
    [[ ! -e "$STATE_MANIFEST" ]]
    run jq -e '
        (.connections[] | select(.node=="de-vps") | .groups |
            all(.[]; .name=="ROUTER" and .proxies==["vless-reality"])) and
        (.connections[] | select(.node=="third-vps") | .groups |
            any(.[]; .name=="PC" and .proxies==["stale-proxy"]))
    ' "$CONFIG_JSON"
    assert_success
}

@test "connections menu permits explicit synchronization retry after failed automatic attempt" {
    _menu_discovery
    _fail_second_promotion
    run connections_menu <<< $'x\n\ns\n0'
    assert_success
    [[ "$(cat "$BATS_TEST_TMPDIR/promotions")" == 5 ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/discovered")" == $'de-vps\nru-vps\nde-vps\nru-vps\nthird-vps' ]]
    [[ -f "$STATE_MANIFEST" ]]
    run jq -e 'all(.connections[]; .groups==[{name:"ROUTER",proxies:["vless-reality"]}])' "$CONFIG_JSON"
    assert_success
}
