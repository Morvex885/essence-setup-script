#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'nodes.sh'
    source_module 'groups.sh'
    source_module 'clients.sh'
    source_module 'connections.sh'
    source "$PROJECT_ROOT/tests/helpers/mock_ssh.bash"
    load_fixture_config
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
    SCRIPTS_READY=()
    jq_w '.subscription_host={node:"de-vps"} | .clients[0].subscription={token:"TOKEN_SENTINEL",expiry:123} | .connections[1].groups[0].proxies=["AWG"]'
    mkdir -p "$GENERATED_DIR/ROUTER/my-router" "$GENERATED_DIR/PC/my-pc"
    printf 'keep router\n' > "$GENERATED_DIR/ROUTER/my-router/config.yaml"
    printf 'keep pc\n' > "$GENERATED_DIR/PC/my-pc/config.yaml"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    toggle_select() { TOGGLE_SELECT_FLAGS=(1 1); }
    _subscription_revoke_silent() { printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/revoked"; return 0; }
}

teardown() { teardown_test_env; }

@test "client deletion refusal reviews all targets without SSH or local mutation" {
    run delete_client <<< ''
    assert_failure
    [[ "$output" != *TOKEN_SENTINEL* ]] || return 1
    for target in my-router my-pc de-vps ru-vps 1.2.3.4:22 5.6.7.8:2222; do
        [[ "$output" == *"$target"* ]] || return 1
    done
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ -f "$GENERATED_DIR/PC/my-pc/config.yaml" ]
    [ ! -f "$BATS_TEST_TMPDIR/revoked" ]
}

@test "deletion EOF has one confirmation and no SSH side effects" {
    local confirms=0 rc=0
    confirm_yn() { confirms=$((confirms + 1)); [[ "$2" == N ]] || return 2; return 1; }
    delete_client </dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$confirms" -eq 1 ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "subscription revoke failure preserves clients and prevents AWG deletion" {
    _subscription_revoke_silent() { return 1; }
    local rc=0
    delete_client <<< y || rc=$?
    [ "$rc" -eq 1 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
}

@test "AWG deletion failure after revocation preserves local clients and configs" {
    SSH_RUN_MOCK_EXIT=1
    local rc=0
    delete_client <<< y || rc=$?
    [ "$rc" -eq 1 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "$(cat "$BATS_TEST_TMPDIR/revoked")" = my-router ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 1 ]
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ -f "$GENERATED_DIR/PC/my-pc/config.yaml" ]
}

@test "listener cleanup failure reports failure after removing local clients" {
    jq_w '.connections[1].groups[0].proxies=["vless-reality"]'
    SSH_RUN_MOCK_EXIT=1
    run delete_client <<< y
    assert_failure
    [ "$(jq_r '.clients | length')" -eq 0 ]
    [ ! -d "$GENERATED_DIR/ROUTER/my-router" ]
    [ ! -d "$GENERATED_DIR/PC/my-pc" ]
}

@test "client editor follows renamed client and keeps the section active" {
    edit_client <<< $'1\nr\nrenamed-router\n1\n0\n0'
    [ "$(jq_r '.clients[0].name')" = renamed-router ]
    [ -f "$GENERATED_DIR/ROUTER/renamed-router/config.yaml" ]
    [ ! -d "$GENERATED_DIR/ROUTER/my-router" ]
    [ "$(jq_r '.clients[0].inherit_nodes_from_group')" = false ]
}

@test "connection alias changes remain local until explicit save" {
    SSH_RUN_MOCK_OUTPUT=$'--- VLESS TCP ---\nproxies:\n  - name: "vless-reality"\n---'
    run _rename_connections <<< $'1\n1\nnew-name\n0'
    assert_failure
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    _rename_connections <<< $'1\n01\n1\nnew-name\ns'
    [ "$(jq_r '.nodes[0].aliases["vless-reality"]')" = new-name ]
}

@test "empty group selection cancels without consuming the next input" {
    jq_w '.groups=[]'
    SELECTED_GROUP=stale
    local rc=0 remaining
    { select_group || rc=$?; IFS= read -r remaining; } <<< 'untouched'
    [ "$rc" -eq 1 ]
    [ -z "$SELECTED_GROUP" ]
    [ "$remaining" = untouched ]
}

@test "deletion includes client-specific AmneziaWG access even when the group has none" {
    jq_w '.connections[1].groups[0].proxies=["vless-reality"] | .clients[1].connections[0].proxies=["AWG"]'
    SSH_RUN_MOCK_EXIT=1
    local rc=0
    delete_client <<< y || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.clients | length')" -eq 2 ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 1 ]
    [ -f "$GENERATED_DIR/PC/my-pc/config.yaml" ]
}

@test "client connections stay in the selected node after an action and return to node selection" {
    jq_w '.clients[1].connections[0].proxies=["old-connection"]'
    SSH_RUN_MOCK_OUTPUT=$'proxies:\n  - name: \"vless-reality\"\n---'
    toggle_select() { TOGGLE_SELECT_FLAGS=(1); }
    local rc=0
    _configure_client_connections my-pc PC <<< $'1\n1\n2\n\n0\n0' || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.clients[1].connections[0].proxies[0]')" = vless-reality ]
    [ "$(jq_r '.clients[1].connections | length')" -eq 1 ]
}

@test "successful group connection assignment returns success and preserves other nodes" {
    groups_list
    local other_before
    other_before=$(jq_r '[.connections[] | select(.node!="de-vps")]')
    _batch_assign_connections de-vps live-tunnel
    [ "$?" -eq 0 ]
    jq -e '.connections | any(.node=="de-vps" and (.groups |
        any(.name=="ROUTER" and .proxies==["live-tunnel"]) and
        any(.name=="PC" and .proxies==["live-tunnel"])))' "$CONFIG_JSON" >/dev/null
    [ "$(jq_r '[.connections[] | select(.node!="de-vps")]')" = "$other_before" ]
}

# Reject only config promotion; fixture setup and unrelated moves remain real.
reject_config_promotion() {
    CONFIG_SOURCE=local
    MV_REAL=$(command -v mv)
    mv() {
        if [[ "$#" -eq 2 && "$1" == "$CONFIG_JSON.tmp."* && "$2" == "$CONFIG_JSON" ]]; then
            printf '77\n' >> "$BATS_TEST_TMPDIR/rejected-promotions"
            return 77
        fi
        "$MV_REAL" "$@"
    }
    success() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/mutation-success"; }
    state_checkpoint() { printf 'checkpoint\n' >> "$BATS_TEST_TMPDIR/checkpoints"; }
}

assert_rejected_config_unchanged() {
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "$(cat "$BATS_TEST_TMPDIR/rejected-promotions")" = 77 ]
    [ ! -e "$BATS_TEST_TMPDIR/mutation-success" ]
    [ ! -e "$BATS_TEST_TMPDIR/checkpoints" ]
}

prepare_empty_assigned_group() {
    jq_w '.groups += [{name:"EMPTY",template:"default.yaml"}] |
        .connections[0].groups += [{name:"EMPTY",proxies:["keep-proxy"]}]'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "rejected group creation leaves the previous config and reports failure" {
    reject_config_promotion
    run state_action add_group add_group <<< 'NEW-GROUP'
    assert_failure
    assert_rejected_config_unchanged
}

@test "rejected group deletion preserves the group and its connection assignments" {
    prepare_empty_assigned_group
    reject_config_promotion
    run state_action delete_group delete_group <<< $'4\ny'
    assert_failure
    assert_rejected_config_unchanged
}

@test "rejected client creation preserves config and reports no completed mutation" {
    reject_config_promotion
    run state_action add_client add_client <<< $'new-client\n1'
    assert_failure
    assert_rejected_config_unchanged
}

@test "rejected client group change preserves generated config and blocks dependent effects" {
    cp "$GENERATED_DIR/ROUTER/my-router/config.yaml" "$BATS_TEST_TMPDIR/before.yaml"
    _reset_node_cache() { touch "$BATS_TEST_TMPDIR/cache-reset"; }
    _prefetch_node_configs() { touch "$BATS_TEST_TMPDIR/prefetch"; }
    _generate_group() {
        mkdir -p "$GENERATED_DIR/PC/my-router"
        printf 'replacement\n' > "$GENERATED_DIR/PC/my-router/config.yaml"
    }
    _sync_listeners_on_nodes() { touch "$BATS_TEST_TMPDIR/listeners"; }
    subscription_publish() { touch "$BATS_TEST_TMPDIR/published"; }
    reject_config_promotion
    run state_action change_client_group _change_client_group my-router ROUTER <<< 1
    assert_failure
    assert_rejected_config_unchanged
    cmp -s "$GENERATED_DIR/ROUTER/my-router/config.yaml" "$BATS_TEST_TMPDIR/before.yaml"
    [ ! -e "$GENERATED_DIR/PC/my-router" ]
    [ ! -e "$BATS_TEST_TMPDIR/cache-reset" ]
    [ ! -e "$BATS_TEST_TMPDIR/prefetch" ]
    [ ! -e "$BATS_TEST_TMPDIR/listeners" ]
    [ ! -e "$BATS_TEST_TMPDIR/published" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
}

@test "groups menu keeps both add bindings available after one rejected save" {
    local binding line warnings frames
    reject_config_promotion
    for binding in a A; do
        rm -f "$BATS_TEST_TMPDIR/rejected-promotions"
        run groups_menu <<< "$(printf 'invalid\n\n%s\nNEW-GROUP\n0\n' "$binding")"
        assert_success
        assert_rejected_config_unchanged
        warnings=0 frames=0
        while IFS= read -r line; do
            [[ "$line" != *"Группы"* ]] || frames=$((frames + 1))
            [[ "$line" != *"Не удалось заменить конфиг"* ]] || warnings=$((warnings + 1))
        done <<< "$output"
        [ "$warnings" -eq 1 ]
        [ "$frames" -eq 4 ]
    done
}

@test "groups menu keeps both delete bindings available and preserves assignments on failure" {
    prepare_empty_assigned_group
    reject_config_promotion
    local binding line warnings frames
    for binding in d D; do
        rm -f "$BATS_TEST_TMPDIR/rejected-promotions"
        run groups_menu <<< "$(printf '%s\n4\ny\n0\n' "$binding")"
        assert_success
        assert_rejected_config_unchanged
        warnings=0 frames=0
        while IFS= read -r line; do
            [[ "$line" != *"Группы"* ]] || frames=$((frames + 1))
            [[ "$line" != *"Не удалось заменить конфиг"* ]] || warnings=$((warnings + 1))
        done <<< "$output"
        [ "$warnings" -eq 1 ]
        [ "$frames" -eq 2 ]
    done
}

@test "groups menu template bindings preserve assignment when promotion fails" {
    source_module 'templates.sh'
    printf 'mode: rule\n' > "$TEMPLATES_DIR/alternate.yaml"
    reject_config_promotion
    local binding line warnings
    for binding in t T; do
        rm -f "$BATS_TEST_TMPDIR/rejected-promotions"
        run groups_menu <<< "$(printf '%s\n1\n1\n0\n' "$binding")"
        assert_success
        assert_rejected_config_unchanged
        warnings=0
        while IFS= read -r line; do
            [[ "$line" != *"Не удалось заменить конфиг"* ]] || warnings=$((warnings + 1))
        done <<< "$output"
        [ "$warnings" -eq 1 ]
    done
}

@test "groups menu exits on EOF without mutating config or starting a checkpoint" {
    reject_config_promotion
    run groups_menu </dev/null
    assert_success
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ ! -e "$BATS_TEST_TMPDIR/rejected-promotions" ]
    [ ! -e "$BATS_TEST_TMPDIR/checkpoints" ]
}

@test "guarded client rename preserves config and generated directory on rejected promotion" {
    reject_config_promotion
    run state_action rename_client _rename_client my-router <<< renamed-router
    assert_failure
    assert_rejected_config_unchanged
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ ! -e "$GENERATED_DIR/ROUTER/renamed-router" ]
}

@test "guarded client connection writer preserves previous selection on rejected promotion" {
    reject_config_promotion
    run state_action set_client_connections _save_client_connections my-pc de-vps '["new-proxy"]'
    assert_failure
    assert_rejected_config_unchanged
}
