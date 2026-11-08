#!/usr/bin/env bats
# Tests for client name validation regex: ^[a-zA-Z0-9._-]+$

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "clients.sh"
}

teardown() {
    teardown_test_env
}

# Use the real validation function from clients.sh
matches() {
    _validate_client_name "$1"
}

@test "client name: simple alpha" {
    run matches "client"
    assert_success
}

@test "client name: alphanumeric" {
    run matches "client123"
    assert_success
}

@test "client name: with dots" {
    run matches "my.client"
    assert_success
}

@test "client name: with hyphens" {
    run matches "my-client"
    assert_success
}

@test "client name: with underscores" {
    run matches "my_client"
    assert_success
}

@test "client name: mixed valid chars" {
    run matches "a1._-b"
    assert_success
}

@test "client name: single char" {
    run matches "a"
    assert_success
}

@test "client name: single dot rejected" {
    run matches "."
    assert_failure
}

@test "client name: single hyphen" {
    run matches "-"
    assert_success
}

@test "client name: long valid name" {
    local name
    name=$(printf 'a%.0s' {1..200})
    run matches "$name"
    assert_success
}

# --- Invalid names ---

@test "client name: empty string rejected" {
    run matches ""
    assert_failure
}

@test "client name: space inside rejected" {
    run matches "my client"
    assert_failure
}

@test "client name: leading space rejected" {
    run matches " client"
    assert_failure
}

@test "client name: Unicode rejected" {
    run matches "клиент"
    assert_failure
}

@test "client name: semicolon rejected" {
    run matches "cli;ent"
    assert_failure
}

@test "client name: dollar sign rejected" {
    run matches 'cli$ent'
    assert_failure
}

@test "client name: backtick rejected" {
    run matches 'cli`ent'
    assert_failure
}

@test "client name: slash rejected" {
    run matches "cli/ent"
    assert_failure
}

@test "client name: path traversal rejected" {
    run matches "../etc/passwd"
    assert_failure
}

@test "client name: pipe rejected" {
    run matches "a|b"
    assert_failure
}

@test "client name: shell injection rejected" {
    run matches 'cli;rm -rf /'
    assert_failure
}

@test "client name: newline rejected" {
    run matches $'cli\nent'
    assert_failure
}

# ─── security round 1: clients ───────────────────────────────────────────────

@test "S-M1: stored vless uuid must be a canonical uuid" {
    source_module "generate.sh"
    _client_vless_uuid_valid "$(uuidgen | tr '[:upper:]' '[:lower:]')"
    _client_vless_uuid_valid aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    local bad
    for bad in '' old 'x\nid >pwned/e;#' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/e' $'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' \
        aaaaaaaabbbbccccddddeeeeeeeeeeee----; do
        run _client_vless_uuid_valid "$bad"
        assert_failure
    done
}

@test "S-M1: stored hy2 password excludes sed, shell and YAML metacharacters" {
    source_module "generate.sh"
    _client_hy2_password_valid "$(openssl rand -hex 16)"
    _client_hy2_password_valid router-hy2-pass-0001
    local bad
    for bad in '' 'a b' 'a/b' 'a&b' 'a:b' "a'b" 'a\b' $'a\nb' "$(printf 'x%.0s' {1..129})"; do
        run _client_hy2_password_valid "$bad"
        assert_failure
    done
}

@test "S-M1: subscription token must be 64 lowercase hex characters" {
    source_module "subscription.sh"
    _sub_token_valid "$(openssl rand -hex 32)"
    local bad
    for bad in '' secret-alpha "$(printf 'A%.0s' {1..64})" "$(printf 'a%.0s' {1..63})" \
        "$(printf 'a%.0s' {1..64}) " "x\" ; touch pwned #"; do
        run _sub_token_valid "$bad"
        assert_failure
    done
}

@test "S-H1: generated paths must stay physically inside GENERATED_DIR" {
    source_module "generate.sh"
    mkdir -p "$GENERATED_DIR/PC/c" "$BATS_TEST_TMPDIR/outside/c"
    ln -s "$BATS_TEST_TMPDIR/outside" "$GENERATED_DIR/LINK"
    _generated_path_safe "$GENERATED_DIR/PC/c"
    _generated_path_safe "$GENERATED_DIR/PC/new"
    local bad
    for bad in "$GENERATED_DIR" "$GENERATED_DIR/" "$GENERATED_DIR/../x" "$GENERATED_DIR/PC/../../x" \
        "$GENERATED_DIR/./PC/c" "$GENERATED_DIR//PC/c" "$GENERATED_DIR/LINK/c" "$BATS_TEST_TMPDIR/outside/c"; do
        run _generated_path_safe "$bad"
        assert_failure
    done
    run _generated_name_valid ..
    assert_failure
    _generated_name_valid ROUTER
}

# Ядро команд с моками SSH (как в cmd_*.bats) для проверок генерации.
_sec_core() {
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    open_local_session
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
}

@test "S-H1: generation refuses stored group and client names that leave GENERATED_DIR" {
    _sec_core
    printf 'proxies:\nproxy-groups: []\n' > "$TEMPLATES_DIR/default.yaml"
    jq_w '.groups=[{name:"PC",template:"default.yaml"},{name:"..",template:"default.yaml"}] | .clients=[{name:"good",group:"PC"},{name:"../up",group:"PC"},{name:"escape",group:".."}]'
    run_cmd generate --all
    [ "$status" -eq 1 ]
    [ "$(cmd_jq -c '.data.failed')" = '["../up","escape"]' ]
    [ ! -e "$GENERATED_DIR/up" ]
    [ ! -e "$BATS_TEST_TMPDIR/escape" ]
    [ -f "$GENERATED_DIR/PC/good/config.yaml" ]
}

@test "S-M1: a config-borne credential is rejected instead of reaching sed (no command execution)" {
    _sec_core
    load_fixture_config
    cd "$BATS_TEST_TMPDIR"
    jq_w --arg u 'x\nid >pwned/e;#' '(.clients[] | select(.name=="my-router")) |= (.credentials.vless_uuid=$u | .inherit_nodes_from_group=false | .nodes=["de-vps"] | .connections=[{node:"de-vps",proxies:["V"]}])'
    _get_node_config() { printf 'proxies:\n  - name: "V"\n    type: vless\n    uuid: old\n'; }
    run _fetch_proxies_for_client my-router ROUTER de-vps
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    jq_w '(.clients[] | select(.name=="my-router")).credentials = {vless_uuid:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", hy2_password:"bad pass: x"}'
    run _fetch_proxies_for_client my-router ROUTER de-vps
    [ "$status" -ne 0 ]
    # Синхронизация пользователей listener'ов тоже не отправляет недопустимые данные.
    _reset_node_cache
    _generate_reset_results
    _node_config_cache_set de-vps $'--- VLESS TCP ---\n--- Hysteria2 ---'
    _sync_listeners_on_nodes de-vps || true
    [ "${GENERATE_NODE_FAILED[*]}" = de-vps ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test "S-M4: credential substitution in proxy blocks puts no secret into process argv" {
    _sec_core
    load_fixture_config
    _reset_node_cache
    _node_config_cache_set de-vps "$(load_fixture_client_config)"
    local log="$BATS_TEST_TMPDIR/argv.log" out
    sed() { printf 'sed %s\n' "$*" >> "$log"; command sed "$@"; }
    awk() { printf 'awk %s\n' "$*" >> "$log"; command awk "$@"; }
    grep() { printf 'grep %s\n' "$*" >> "$log"; command grep "$@"; }
    out=$(_fetch_proxies_for_client my-router ROUTER de-vps)
    unset -f sed awk grep
    [[ "$out" == *"    uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
    [[ "$out" == *"    password: router-hy2-pass-0001"* ]]
    [[ "$out" != *test-uuid-1234* && "$out" != *testpass* ]]
    [[ "$(cat "$log")" != *aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee* ]]
    [[ "$(cat "$log")" != *router-hy2-pass-0001* ]]
}

@test "S-M4: listener synchronization sends client credentials over ssh stdin only" {
    _sec_core
    load_fixture_config
    _reset_node_cache
    _generate_reset_results
    _node_config_cache_set de-vps $'--- VLESS TCP ---\n--- Hysteria2 ---'
    local ssh_argv_file="$BATS_TEST_TMPDIR/ssh-argv" ssh_input_file="$BATS_TEST_TMPDIR/ssh-stdin"
    ssh_run() {
        [[ "$1" == -- ]] && shift
        printf '%s\n' "$*" >> "$ssh_argv_file"
        cat >> "$ssh_input_file"
    }
    _sync_listeners_on_nodes de-vps
    [ "${GENERATE_NODE_OK[*]}" = de-vps ]
    local secret
    for secret in aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee router-hy2-pass-0001 \
        11111111-2222-3333-4444-555555555555 pc-hy2-pass-0002; do
        [[ "$(cat "$ssh_argv_file")" != *"$secret"* ]] || return 1
        grep -qF -- "$secret" "$ssh_input_file"
    done
    grep -qx 'vless-tcp 6' "$ssh_input_file"
    grep -qx 'hy2 2' "$ssh_input_file"
}

# ─── round 2: clients ────────────────────────────────────────────────────────

# Ядро команд с моками SSH, клиенты фикстуры и их каталоги конфигов.
_r2_clients() {
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    load_fixture_config
    open_local_session
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
    SCRIPTS_READY=()
    state_checkpoint() { echo checkpoint >> "$BATS_TEST_TMPDIR/persist.log"; }
    mkdir -p "$GENERATED_DIR/ROUTER/my-router" "$GENERATED_DIR/PC/my-pc"
    printf 'keep router\n' > "$GENERATED_DIR/ROUTER/my-router/config.yaml"
    printf 'keep pc\n' > "$GENERATED_DIR/PC/my-pc/config.yaml"
}

@test "R2-M8: client rename is gated only when an old-name AmneziaWG client is removed on servers" {
    _r2_clients
    jq_w '.connections[1].groups[0].proxies=["AWG"]'    # ROUTER: AmneziaWG на ru-vps (5.6.7.8)
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client rename --name my-router --new-name r2
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    local plan
    plan=$(cmd_jq '.error.plan | join("\n")')
    [[ "$plan" == *"Клиент AmneziaWG 'my-router' будет удалён на нодах:"*"ru-vps  5.6.7.8:2222"* ]]
    [[ "$plan" != *de-vps* ]]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "$(cat "$GENERATED_DIR/ROUTER/my-router/config.yaml")" = 'keep router' ]
    [ ! -e "$GENERATED_DIR/ROUTER/r2" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
    # Без AmneziaWG у клиента серверных действий нет — переименование без подтверждения.
    jq_w '.connections[1].groups[0].proxies=["vless-reality"]'
    run_cmd client rename --name my-router --new-name r2
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[0].name')" = r2 ]
    [ -f "$GENERATED_DIR/ROUTER/r2/config.yaml" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test "R2-M8: AWG clients are removed by name on every AWG node; rename and set-group drop the old peers" {
    _r2_clients
    jq_w '.connections[1].groups[0].proxies=["AWG"]'    # ROUTER: AmneziaWG на ru-vps (5.6.7.8)
    local awg_log="$BATS_TEST_TMPDIR/awg.log"
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        shift
        [[ "$*" == *remove_awg_peer_by_name* ]] || return 0
        [[ "$*" == '[ -f /etc/amnezia/amneziawg/awg0.conf ] || exit 0;'* ]] || return 1
        printf '%s:%s\n' "$SERVER_IP" "$(grep -o 'remove_awg_peer_by_name [^ ;]*' <<< "$*" | cut -d' ' -f2 | tr '\n' ' ')" >> "$awg_log"
    }
    run_cmd client rename --name my-router --new-name r2 --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$awg_log")" = '5.6.7.8:my-router ' ]
    rm -f "$awg_log"
    _prefetch_node_configs() { :; }
    _generate_group() { mkdir -p "$GENERATED_DIR/$1/r2"; printf 'new\n' > "$GENERATED_DIR/$1/r2/config.yaml"; }
    _sync_listeners_on_nodes() { return 0; }
    run_cmd client set-group --name r2 --group PC
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ "$(cmd_jq '.error.plan | join("\n")')" == *"Клиент AmneziaWG 'r2' будет удалён на нодах: ru-vps"* ]]
    [ ! -e "$awg_log" ]
    run_cmd client set-group --name r2 --group PC --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$awg_log")" = '5.6.7.8:r2 ' ]
    rm -f "$awg_log"
    # В PC у клиента нет AmneziaWG, но на ru-vps он есть в подключениях — удаляется и там.
    run_cmd client delete --name r2 --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$awg_log")" = '5.6.7.8:r2 ' ]
}

@test "R2-M9: rename refuses an existing target directory and restores the directory on a failed write" {
    _r2_clients
    mkdir -p "$GENERATED_DIR/ROUTER/r2"
    printf 'stale\n' > "$GENERATED_DIR/ROUTER/r2/config.yaml"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client rename --name my-router --new-name r2
    [ "$(cmd_jq '.error.code')" = conflict ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "$(cat "$GENERATED_DIR/ROUTER/r2/config.yaml")" = stale ]
    [ ! -e "$GENERATED_DIR/ROUTER/r2/my-router" ]
    rm -rf "$GENERATED_DIR/ROUTER/r2"
    mv() { [[ "$*" == *"/ROUTER/my-router"* ]] && return 1; command mv "$@"; }
    run_cmd client rename --name my-router --new-name r2
    [ "$(cmd_jq '.error.code')" = failed ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    # Сбой записи конфигурации после переноса каталога: каталог возвращается.
    mv() {
        [[ "$#" -eq 2 && "$1" == "$CONFIG_JSON.tmp."* && "$2" == "$CONFIG_JSON" ]] && return 77
        command mv "$@"
    }
    run_cmd client rename --name my-router --new-name r2
    [ "$status" -ne 0 ]
    unset -f mv
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "$(cat "$GENERATED_DIR/ROUTER/my-router/config.yaml")" = 'keep router' ]
    [ ! -e "$GENERATED_DIR/ROUTER/r2" ]
}

@test "R2-H3: client delete after a committed revoke or AWG removal reports partial with what was done" {
    _r2_clients
    local ta tb
    ta=$(printf 'a%.0s' {1..64})
    tb=$(printf 'b%.0s' {1..64})
    jq_w --arg a "$ta" --arg b "$tb" '.subscription_host={node:"de-vps",sub_dir:"/srv/sub"} |
        .clients[0].subscription={token:$a} | .clients[1].subscription={token:$b}'
    _sub_load_host() { _sub_save_ssh_ctx; return 0; }
    _sub_remove_token() { [[ "$1" == "$ta" ]]; }
    run_cmd client delete --name my-router --name my-pc --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq -c '.data')" = '{"deleted":[],"revoked":["my-router"],"awg_nodes":[]}' ]
    [ "$(jq_r '.clients[0].subscription.token // "none"')" = none ]
    [ "$(jq_r '.clients[1].subscription.token')" = "$tb" ]
    [ "$(cat "$BATS_TEST_TMPDIR/persist.log")" = checkpoint ]
    rm -f "$BATS_TEST_TMPDIR/persist.log"
    jq_w 'del(.subscription_host) | .clients |= map(del(.subscription)) |
        .connections[0].groups[0].proxies=["AWG"] | .connections[1].groups[0].proxies=["AWG"]'
    ssh_run() { [[ "$SERVER_IP" != 5.6.7.8 ]]; }
    run_cmd client delete --name my-router --yes
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq -c '.data')" = '{"deleted":[],"revoked":[],"awg_nodes":["de-vps"]}' ]
    [ "$(jq_r '.clients[0].name')" = my-router ]
    [ "$(cat "$BATS_TEST_TMPDIR/persist.log")" = checkpoint ]
    # Ничего не выполнено — прежний код без записи.
    rm -f "$BATS_TEST_TMPDIR/persist.log"
    ssh_run() { return 1; }
    run_cmd client delete --name my-router --yes
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ ! -e "$BATS_TEST_TMPDIR/persist.log" ]
}

@test "R2-L6: client delete re-checks remote scripts after an earlier command in the same process" {
    _r2_clients
    jq_w '.connections[1].groups[0].proxies=["vless-reality"]'
    SCRIPTS_READY=(de-vps ru-vps)
    run_cmd client delete --name my-router --yes
    [ "$status" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 2 ]
}

@test "R2-L7: client connections --reset validates the client and node before asking for confirmation" {
    _r2_clients
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client connections --name my-router --node de-vps --reset
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd client connections --name my-pc --node ru-vps --reset
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd client connections --name my-pc --node de-vps --reset
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "R2-M10: node aliases from CRLF jq output do not inject CR into proxy names" {
    _r2_clients
    NODE_CONFIG_CACHE_KEYS=(ru-vps)
    NODE_CONFIG_CACHE_VALUES=($'proxies:\n  - name: vless-reality\n    type: vless\n    uuid: x')
    local out
    jq() { command jq "$@" | sed 's/$/\r/'; }
    out=$(_fetch_proxies_for_client my-router ROUTER ru-vps | grep 'name:')
    unset -f jq
    [[ "$out" == *'"RU-VLESS"'* && "$out" != *$'\r'* ]]
}
