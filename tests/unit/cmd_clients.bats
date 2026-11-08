#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    load_fixture_config
    open_local_session
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
    SCRIPTS_READY=()
    jq_w '.subscription_host={node:"de-vps"} | .clients[0].subscription={token:"TOKEN_SENTINEL",expiry:123} | .connections[1].groups[0].proxies=["AWG"]'
    mkdir -p "$GENERATED_DIR/ROUTER/my-router" "$GENERATED_DIR/PC/my-pc"
    printf 'keep router\n' > "$GENERATED_DIR/ROUTER/my-router/config.yaml"
    printf 'keep pc\n' > "$GENERATED_DIR/PC/my-pc/config.yaml"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    _subscription_revoke_silent() { printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/revoked"; return 0; }
}

teardown() { teardown_test_env; }

@test "client deletion without --yes reviews all targets without SSH or local mutation" {
    run_cmd client delete --name my-router --name my-pc
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ "$output" != *TOKEN_SENTINEL* && "$CMD_ENVELOPE" != *TOKEN_SENTINEL* ]] || return 1
    local plan
    plan=$(cmd_jq '.error.plan | join("\n")')
    for target in my-router my-pc de-vps ru-vps 1.2.3.4:22 5.6.7.8:2222; do
        [[ "$plan" == *"$target"* ]] || return 1
    done
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ -f "$GENERATED_DIR/PC/my-pc/config.yaml" ]
    [ ! -f "$BATS_TEST_TMPDIR/revoked" ]
}

@test "deletion confirmation request has no SSH side effects" {
    run_cmd client delete --name my-router
    [ "$status" -eq 2 ]
    [[ "$(cmd_jq '.error.plan_token')" =~ ^[0-9a-f]{16}$ ]]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "subscription revoke failure preserves clients and prevents AWG deletion" {
    _subscription_revoke_silent() { return 1; }
    run_cmd client delete --name my-router --name my-pc --yes
    [ "$status" -eq 1 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
}

@test "AWG deletion failure after revocation preserves local clients and configs" {
    SSH_RUN_MOCK_EXIT=1
    run_cmd client delete --name my-router --name my-pc --yes
    [ "$status" -eq 1 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "$(cat "$BATS_TEST_TMPDIR/revoked")" = my-router ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 1 ]
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ -f "$GENERATED_DIR/PC/my-pc/config.yaml" ]
}

@test "listener cleanup failure reports failure after removing local clients" {
    jq_w '.connections[1].groups[0].proxies=["vless-reality"]'
    SSH_RUN_MOCK_EXIT=1
    run_cmd client delete --name my-router --name my-pc --yes
    [ "$status" -ne 0 ]
    [ "$(jq_r '.clients | length')" -eq 0 ]
    [ ! -d "$GENERATED_DIR/ROUTER/my-router" ]
    [ ! -d "$GENERATED_DIR/PC/my-pc" ]
}

@test "successful client deletion returns the deleted names and removes local state" {
    jq_w '.connections[1].groups[0].proxies=["vless-reality"]'
    run_cmd client delete --name my-router --name my-pc --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data.deleted')" = '["my-router","my-pc"]' ]
    [ "$(jq_r '.clients | length')" -eq 0 ]
    [ ! -d "$GENERATED_DIR/ROUTER/my-router" ]
}

@test "client rename follows the generated directory and nodes switch to own list" {
    run_cmd client rename --name my-router --new-name renamed-router --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.name')" = renamed-router ]
    run_cmd client nodes --name renamed-router --node de-vps
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[0].name')" = renamed-router ]
    [ -f "$GENERATED_DIR/ROUTER/renamed-router/config.yaml" ]
    [ ! -d "$GENERATED_DIR/ROUTER/my-router" ]
    [ "$(jq_r '.clients[0].inherit_nodes_from_group')" = false ]
}

@test "deletion includes client-specific AmneziaWG access even when the group has none" {
    jq_w '.connections[1].groups[0].proxies=["vless-reality"] | .clients[1].connections[0].proxies=["AWG"]'
    SSH_RUN_MOCK_EXIT=1
    run_cmd client delete --name my-router --name my-pc --yes
    [ "$status" -eq 1 ]
    [ "$(jq_r '.clients | length')" -eq 2 ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 1 ]
    [ -f "$GENERATED_DIR/PC/my-pc/config.yaml" ]
}

@test "client connections command saves the selected proxies on the node" {
    jq_w '.clients[1].connections[0].proxies=["old-connection"]'
    SSH_RUN_MOCK_OUTPUT=$'proxies:\n  - name: \"vless-reality\"\n---'
    run_cmd client connections --name my-pc --node de-vps --proxy vless-reality
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"name":"my-pc","node":"de-vps","proxies":["vless-reality"]}' ]
    [ "$(jq_r '.clients[1].connections[0].proxies[0]')" = vless-reality ]
    [ "$(jq_r '.clients[1].connections | length')" -eq 1 ]
}

@test "client connections reset needs confirmation and leaves state untouched" {
    jq_w '.clients[1].connections[0].proxies=["old-connection"]'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client connections --name my-pc --node de-vps --reset
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
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
    run_cmd group add --name NEW-GROUP
    [ "$status" -ne 0 ]
    assert_rejected_config_unchanged
}

@test "rejected group deletion preserves the group and its connection assignments" {
    prepare_empty_assigned_group
    reject_config_promotion
    run_cmd group delete --name EMPTY --yes
    [ "$status" -ne 0 ]
    assert_rejected_config_unchanged
}

@test "rejected client creation preserves config and reports no completed mutation" {
    reject_config_promotion
    run_cmd client add --name new-client --group ROUTER
    [ "$status" -ne 0 ]
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
    run_cmd client set-group --name my-router --group PC --yes
    [ "$status" -ne 0 ]
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

@test "client group change without --yes reviews impact without SSH or local mutation" {
    run_cmd client set-group --name my-router --group PC
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    local plan
    plan=$(cmd_jq '.error.plan | join("\n")')
    for target in "ROUTER → PC" de-vps 1.2.3.4:22 "$GENERATED_DIR/ROUTER/my-router" "Подписка"; do
        [[ "$plan" == *"$target"* ]] || return 1
    done
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ ! -e "$GENERATED_DIR/PC/my-router" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
}

@test "client group change review lists effective subscription header changes" {
    jq_w '.subscription_default_headers = [{name:"profile-update-interval",value:"24"}]
        | (.groups[] | select(.name=="ROUTER") | .subscription_headers) = [{name:"X-Old",value:"o"}]
        | (.groups[] | select(.name=="PC") | .subscription_headers) = [{name:"profile-update-interval",value:"6"}]'
    run_cmd client set-group --name my-router --group PC
    [ "$status" -eq 2 ]
    local plan
    plan=$(cmd_jq '.error.plan | join("\n")')
    [[ "$plan" == *"Заголовки подписки изменятся:"* ]] || return 1
    [[ "$plan" == *"profile-update-interval: 24 → 6"* ]] || return 1
    [[ "$plan" == *"- X-Old: o"* ]] || return 1
}

@test "rejected group template assignment preserves the previous template" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/alternate.yaml"
    reject_config_promotion
    run_cmd group set-template --name ROUTER --template alternate
    [ "$status" -ne 0 ]
    assert_rejected_config_unchanged
}

@test "guarded client rename preserves config and generated directory on rejected promotion" {
    reject_config_promotion
    run_cmd client rename --name my-router --new-name renamed-router --yes
    [ "$status" -ne 0 ]
    assert_rejected_config_unchanged
    [ -f "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ ! -e "$GENERATED_DIR/ROUTER/renamed-router" ]
}

@test "guarded client connection writer preserves previous selection on rejected promotion" {
    reject_config_promotion
    run state_action set_client_connections _save_client_connections my-pc de-vps '["new-proxy"]'
    [ "$status" -ne 0 ]
    assert_rejected_config_unchanged
}

# ─── group / template / client add: данные и решения ──────────────────────────

@test "group add upper-cases the name and rejects missing input and duplicates" {
    run_cmd group add --name lab
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.name')" = LAB ]
    jq -e 'any(.groups[]; .name=="LAB" and .template=="default.yaml")' "$CONFIG_JSON" >/dev/null
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd group add --name LAB
    [ "$(cmd_jq '.error.code')" = conflict ]
    run_cmd group add
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "group delete is gated, refuses groups with clients and drops connection assignments" {
    prepare_empty_assigned_group
    run_cmd group delete --name EMPTY
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd group delete --name ROUTER --yes
    [ "$(cmd_jq '.error.code')" = conflict ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd group delete --name EMPTY --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.name')" = EMPTY ]
    [ "$(jq_r 'any(.groups[]; .name=="EMPTY")')" = false ]
    [ "$(jq_r '[.connections[].groups[] | select(.name=="EMPTY")] | length')" -eq 0 ]
}

@test "group set-template assigns an existing template and rejects unknown ones" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/alternate.yaml"
    run_cmd group set-template --name ROUTER --template alternate
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"name":"ROUTER","template":"alternate.yaml"}' ]
    [ "$(jq_r '.groups[] | select(.name=="ROUTER") | .template')" = alternate.yaml ]
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd group set-template --name ROUTER --template missing
    [ "$(cmd_jq '.error.code')" = not_found ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "template create copies default.yaml, assigns the group and returns data" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml"
    run_cmd template create --name lab.v2 --group PC
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"name":"lab.v2.yaml","based_on":"default.yaml","group":"PC"}' ]
    cmp -s "$TEMPLATES_DIR/lab.v2.yaml" "$TEMPLATES_DIR/default.yaml"
    [ "$(jq_r '.groups[] | select(.name=="PC") | .template')" = lab.v2.yaml ]
    [ "$(jq_r '.groups[] | select(.name=="ROUTER") | .template')" = default.yaml ]
}

@test "template create from another template without a group leaves groups alone" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/alternate.yaml"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd template create --name copy --from alternate
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"name":"copy.yaml","based_on":"alternate.yaml","group":null}' ]
    cmp -s "$TEMPLATES_DIR/copy.yaml" "$TEMPLATES_DIR/alternate.yaml"
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "template create without any base makes an empty template" {
    run_cmd template create --name blank
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.based_on')" = null ]
    [ -f "$TEMPLATES_DIR/blank.yaml" ]
    [ ! -s "$TEMPLATES_DIR/blank.yaml" ]
}

@test "template create validates name, conflict, base and group before leaving files" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml"
    run_cmd template create --name 'bad name'
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd template create --name default
    [ "$(cmd_jq '.error.code')" = conflict ]
    run_cmd template create --name new --from nope
    [ "$(cmd_jq '.error.code')" = not_found ]
    run_cmd template create --name new --group NOPE
    [ "$(cmd_jq '.error.code')" = not_found ]
    [ ! -e "$TEMPLATES_DIR/new.yaml" ]
    [ ! -e "$TEMPLATES_DIR/bad name.yaml" ]
}

@test "template create rolls the file back when group assignment is rejected" {
    reject_config_promotion
    run_cmd template create --name rolled --group PC
    [ "$status" -ne 0 ]
    [ ! -e "$TEMPLATES_DIR/rolled.yaml" ]
    assert_rejected_config_unchanged
}

@test "template show returns the file path" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml"
    run_cmd template show --name default
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.path')" = "$TEMPLATES_DIR/default.yaml" ]
    [ "$(cmd_jq '.data.content')" = 'mode: rule' ]
}

@test "client add returns data and rejects unknown groups and duplicates" {
    run_cmd client add --name new-client --group ROUTER
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"name":"new-client","group":"ROUTER"}' ]
    [ "$(jq_r '.clients[] | select(.name=="new-client") | .group')" = ROUTER ]
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client add --name new-client --group ROUTER
    [ "$status" -eq 1 ]
    run_cmd client add --name other --group NOPE
    [ "$status" -eq 1 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

# ─── client list / client show ───────────────────────────────────────────────

@test "client list returns every client with group, nodes and publication state" {
    run_cmd client list
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data | map(.name)')" = '["my-router","my-pc"]' ]
    [ "$(cmd_jq -c '.data[0] | [.group, (.nodes | type), .subscription.published]')" = '["ROUTER","array",true]' ]
    [ "$(cmd_jq -c '.data[1].subscription.published')" = false ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "client list --group filters by group and rejects an unknown group" {
    run_cmd client list --group PC
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data | map(.name)')" = '["my-pc"]' ]
    run_cmd client list --group MOBILE
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '[]' ]
    run_cmd client list --group NOPE
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = not_found ]
}

@test "client show returns credentials, connections, config path and subscription" {
    run_cmd client show --name my-router
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -r '.data.name')" = my-router ]
    [ "$(cmd_jq -r '.data.group')" = ROUTER ]
    [ "$(cmd_jq -r '.data.credentials.vless_uuid')" = aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee ]
    [ "$(cmd_jq '.data.connections | type')" = array ]
    [ "$(cmd_jq -r '.data.config.path')" = "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    [ "$(cmd_jq -c '.data.config.exists')" = true ]
    [ "$(cmd_jq '.data.subscription | type')" = object ]
    [ "$(cmd_jq -c '.data | has("subscription")')" = true ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "client show reports null subscription for an unpublished client and not_found for an unknown one" {
    run_cmd client show --name my-pc
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data.subscription')" = null ]
    run_cmd client show --name nobody
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = not_found ]
}

# ─── security round 1: clients ───────────────────────────────────────────────

@test "S-H1: group add rejects names that are not a safe directory component" {
    local name
    for name in .. ../../.. A/B ... 'A B'; do
        run_cmd group add --name "$name"
        [ "$status" -eq 1 ]
        [ "$(cmd_jq '.error.code')" = invalid ]
    done
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "S-H1: a stored group traversal cannot move, delete or expose a directory outside GENERATED_DIR" {
    # Как config.json из GitHub: группа «..» указывает каталог клиента на TEMPLATES_DIR.
    jq_w '.groups += [{name:"..",template:"default.yaml"}] | .clients += [{name:"templates",group:"..",inherit_nodes_from_group:true}]'
    printf 'precious\n' > "$TEMPLATES_DIR/precious.yaml"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client rename --name templates --new-name moved
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd client delete --name templates --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd client set-group --name templates --group PC --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd client show --name templates
    [ "$(cmd_jq '.error.code')" = invalid ]
    [ -f "$TEMPLATES_DIR/precious.yaml" ]
    [ ! -e "$BATS_TEST_TMPDIR/moved" ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test "S-H1: a client directory behind a symlinked group is neither moved nor deleted" {
    mkdir -p "$BATS_TEST_TMPDIR/outside/my-pc"
    printf 'outside\n' > "$BATS_TEST_TMPDIR/outside/my-pc/config.yaml"
    rm -rf "$GENERATED_DIR/PC"
    ln -s "$BATS_TEST_TMPDIR/outside" "$GENERATED_DIR/PC"
    run_cmd client rename --name my-pc --new-name moved-pc
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd client delete --name my-pc --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    [ -f "$BATS_TEST_TMPDIR/outside/my-pc/config.yaml" ]
    [ ! -e "$BATS_TEST_TMPDIR/outside/moved-pc" ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test "S-M4: client add keeps the generated credentials out of process argv" {
    # Не log: run_cmd объявляет свой local log, и обёртка писала бы в журнал команды.
    local argv_log="$BATS_TEST_TMPDIR/argv.log" uuid pass
    jq() { printf '%s\n' "$*" >> "$argv_log"; command jq "$@"; }
    run_cmd client add --name argvtest --group ROUTER
    unset -f jq
    [ "$status" -eq 0 ]
    uuid=$(jq -r '.clients[] | select(.name=="argvtest") | .credentials.vless_uuid' "$CONFIG_JSON")
    pass=$(jq -r '.clients[] | select(.name=="argvtest") | .credentials.hy2_password' "$CONFIG_JSON")
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
    [[ "$pass" =~ ^[0-9a-f]{32}$ ]]
    [ -s "$argv_log" ]
    [[ "$(cat "$argv_log")" != *"$uuid"* && "$(cat "$argv_log")" != *"$pass"* ]]
}

@test "S-M4: client deletion sends the remaining listener users over ssh stdin, not argv" {
    jq_w '.connections[1].groups[0].proxies=["vless-reality"]'
    local ssh_argv_file="$BATS_TEST_TMPDIR/ssh-argv" ssh_input_file="$BATS_TEST_TMPDIR/ssh-stdin"
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        shift
        printf '%s\n' "$*" >> "$ssh_argv_file"
        cat >> "$ssh_input_file"
    }
    run_cmd client delete --name my-router --yes
    [ "$status" -eq 0 ]
    [[ "$(cat "$ssh_argv_file")" != *11111111-2222-3333-4444-555555555555* ]]
    [[ "$(cat "$ssh_argv_file")" != *pc-hy2-pass-0002* ]]
    grep -qF 'uuid: 11111111-2222-3333-4444-555555555555' "$ssh_input_file"
    grep -qF 'my-pc: pc-hy2-pass-0002' "$ssh_input_file"
    [[ "$(cat "$ssh_input_file")" != *my-router* ]]
}

@test "S-M4: client show builds credentials and the token link without passing them in argv" {
    jq_w '.subscription_host.base_url="https://sub.example"'
    local argv_log="$BATS_TEST_TMPDIR/argv.log" args
    jq() { printf '%s\n' "$*" >> "$argv_log"; command jq "$@"; }
    run_cmd client show --name my-router
    unset -f jq
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -r '.data.subscription.url')" = https://sub.example/sub/TOKEN_SENTINEL ]
    [ "$(cmd_jq -r '.data.credentials.hy2_password')" = router-hy2-pass-0001 ]
    args=$(cat "$argv_log")
    [ -n "$args" ]
    [[ "$args" != *TOKEN_SENTINEL* && "$args" != *router-hy2-pass-0001* ]]
    [[ "$args" != *aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee* ]]
}

@test "S-L8: returning a client to group nodes is gated when it drops own nodes or connections" {
    run_cmd client nodes --name my-pc --inherit
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    local plan
    plan=$(cmd_jq '.error.plan | join("\n")')
    [[ "$plan" == *"Свои ноды будут сброшены:"*"de-vps"* ]]
    [[ "$plan" == *"Собственные подключения будут удалены:"* ]]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd client nodes --name my-pc --inherit --yes
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[1].inherit_nodes_from_group')" = true ]
    [ "$(jq_r '.clients[1] | has("nodes") or has("connections")')" = false ]
    # Без своих нод и подключений сбрасывать нечего — подтверждение не нужно.
    run_cmd client nodes --name my-router --inherit
    [ "$status" -eq 0 ]
}

@test "S-M8: template export treats an option-like output as a file name and gates dangling symlinks" {
    printf 'TEMPLATE\n' > "$TEMPLATES_DIR/default.yaml"
    mkdir -p "$BATS_TEST_TMPDIR/victim"
    printf 'IMPORTANT\n' > "$BATS_TEST_TMPDIR/victim/default.yaml"
    cd "$BATS_TEST_TMPDIR"
    run_cmd template export --name default --output "-t$BATS_TEST_TMPDIR/victim"
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/victim/default.yaml")" = IMPORTANT ]
    ln -s "$BATS_TEST_TMPDIR/newtarget" "$BATS_TEST_TMPDIR/link"
    run_cmd template export --name default --output "$BATS_TEST_TMPDIR/link"
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ ! -e "$BATS_TEST_TMPDIR/newtarget" ]
}
