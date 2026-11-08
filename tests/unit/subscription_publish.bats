#!/usr/bin/env bats
# Tests for subscription publish/revoke/rotate

setup() {
    load '../helpers/test_helper'
    load '../helpers/mock_ssh'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "groups.sh"
    source_module "clients.sh"
    source_module "subscription.sh"

    # Config with node + client + subscription host (with cached sub_dir/nginx_group)
    cat > "$CONFIG_JSON" <<'EOF'
{
  "schema_version": 2,
  "nodes": [{"id":"11111111111111111111111111111111","name":"vps-1","ip":"1.2.3.4","port":22,"user":"root","auth":"key","identity":"system","secret_id":null,"aliases":{}}],
  "subscription_host": {"node":"vps-1","base_url":"https://sub.example.com:2096","sub_dir":"/var/lib/essence-sub","nginx_group":"www-data"},
  "groups": [{"name":"MOBILE","template":"default.yaml"}],
  "clients": [{"name":"phone","group":"MOBILE"}],
  "connections": [{"node":"vps-1","groups":[{"name":"MOBILE","proxies":["VLESS TCP"]}]}]
}
EOF

    # Create a dummy generated config
    mkdir -p "$GENERATED_DIR/MOBILE/phone"
    echo "proxies: []" > "$GENERATED_DIR/MOBILE/phone/config.yaml"

    reset_ssh_mocks
    curl() { echo "200"; return 0; }
    export -f curl
    # Wrappers save through state_action; this fixture has no state manifest.
    state_checkpoint() { return 0; }
}

teardown() {
    teardown_test_env
}

@test "publish creates token in config.json" {
    # Mock openssl for deterministic token
    openssl() { echo "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"; }
    export -f openssl

    subscription_publish "phone"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token'
    assert_output "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"
}

@test "publish sets created_at" {
    subscription_publish "phone"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.created_at'
    refute_output "null"
    refute_output ""
}

@test "publish: expires_at is null without --ttl" {
    subscription_publish "phone"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.expires_at'
    assert_output "null"
}

@test "revoke removes token" {
    subscription_publish "phone"
    core_sub_revoke "phone"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    assert_output "empty"
}

@test "revoke preserves headers" {
    subscription_set_header "phone" "User-Agent" "clash-meta"
    subscription_publish "phone"

    core_sub_revoke "phone"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers[0].name'
    assert_output "User-Agent"
}

@test "rotate changes token" {
    subscription_publish "phone"
    local old_token
    old_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    core_sub_rotate "phone"
    local new_token
    new_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    [ "$old_token" != "$new_token" ]
}


@test "publish reuses existing token" {
    subscription_publish "phone"
    local first_token
    first_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    subscription_publish "phone"
    local second_token
    second_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    [ "$first_token" = "$second_token" ]
}

@test "publish_all assigns tokens to new clients" {
    # Add second client without token
    jq_w '.clients += [{"name":"tablet","group":"MOBILE"}]'
    mkdir -p "$GENERATED_DIR/MOBILE/tablet"
    echo "proxies: []" > "$GENERATED_DIR/MOBILE/tablet/config.yaml"

    subscription_publish_all

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    refute_output "empty"

    run jq_r '.clients[] | select(.name=="tablet") | .subscription.token // "empty"'
    refute_output "empty"
}

@test "publish_all skips clients without generated config" {
    jq_w '.clients += [{"name":"tablet","group":"MOBILE"}]'
    # No config for tablet

    subscription_publish_all

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    refute_output "empty"

    run jq_r '.clients[] | select(.name=="tablet") | .subscription.token // "empty"'
    assert_output "empty"
}

@test "publish_all preserves existing tokens" {
    subscription_publish "phone"
    local original_token
    original_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    subscription_publish_all

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token'
    assert_output "$original_token"
}

@test "_sub_get_dir reads from cache" {
    run _sub_get_dir
    assert_output "/var/lib/essence-sub"
}

@test "_sub_get_nginx_group reads from cache" {
    run _sub_get_nginx_group
    assert_output "www-data"
}

@test "_sub_get_dir falls back to SSH when cache empty" {
    jq_w '.subscription_host.sub_dir = ""'
    SSH_RUN_MOCK_OUTPUT="SUB_DIR=/custom/path"

    run _sub_get_dir
    assert_output "/custom/path"
}

@test "publish rejects a whitespace-only config without token or SCP" {
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/phone/config.yaml"
    scp_run() {
        touch "$BATS_TEST_TMPDIR/unexpected-scp"
        return 1
    }

    local rc=0
    subscription_publish "phone" > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$RC_ERROR_CODE" = not_ready ]
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-scp" ]

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    assert_output "empty"
}

@test "publish_all skips whitespace-only clients and publishes valid clients" {
    jq_w '.clients += [{"name":"tablet","group":"MOBILE"}]'
    mkdir -p "$GENERATED_DIR/MOBILE/tablet"
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/tablet/config.yaml"

    run subscription_publish_all
    assert_success

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    refute_output "empty"
    run jq_r '.clients[] | select(.name=="tablet") | .subscription.token // "empty"'
    assert_output "empty"
}


@test "low-level batch upload rejects a whitespace-only source before SCP" {
    local blank_config="$BATS_TEST_TMPDIR/blank.yaml"
    printf ' \n\t\n' > "$blank_config"
    scp_run() {
        touch "$BATS_TEST_TMPDIR/unexpected-scp"
        return 1
    }

    run _sub_upload_batch "/var/lib/essence-sub" "www-data" \
        "$blank_config" "token-1" "phone"
    assert_failure
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-scp" ]
}

# Execute the real upload scripts against sandbox paths, replacing only transport
# and server-only commands. Config promotion still uses the real jq_w/mv path.
setup_publication_server() {
    local server="$BATS_TEST_TMPDIR/server"
    mkdir -p "$server/yaml" "$server/snippets"
    jq_w --arg dir "$server/yaml" \
        '.subscription_host.sub_dir = $dir | .subscription_default_headers = []'
    SUB_SNIPPETS_DIR="$server/snippets"
    scp_run() {
        printf 'scp\n' >> "$BATS_TEST_TMPDIR/scp-count"
        local args=("$@") last=$(($# - 1)) dest
        dest="${args[$last]#*:}"
        unset 'args[last]'
        cp "${args[@]}" "$dest"
    }
    ssh_run() {
        local command="$2"
        case "$command" in
            'test -f /etc/mihomo/subscription.conf') return 0 ;;
            *'KNOWN='*) touch "$BATS_TEST_TMPDIR/unexpected-sweep"; return 1 ;;
        esac
        printf 'apply\n' >> "$BATS_TEST_TMPDIR/apply-count"
        (
            chown() { return 0; }
            nginx() { return 0; }
            systemctl() { return 0; }
            eval "$command"
        )
    }
    NODE_ID=prior-id NODE_NAME=prior-name NODE_IDENTITY=prior-identity NODE_TAG=prior-tag
    SERVER_IP=192.0.2.55 SERVER_PORT=2223 SERVER_USER=prior-user
    SERVER_PASS=prior-password SERVER_AUTH=password
}

publication_context() {
    printf '%s\n' "$NODE_ID" "$NODE_NAME" "$NODE_IDENTITY" "$NODE_TAG" \
        "$SERVER_IP" "$SERVER_PORT" "$SERVER_USER" "$SERVER_PASS" "$SERVER_AUTH"
}

@test "batch metadata failure retains all uploads and first token but stops later saves and sweep" {
    jq_w '.clients += [{name:"tablet",group:"MOBILE"},{name:"laptop",group:"MOBILE"}]'
    local client
    for client in tablet laptop; do
        mkdir -p "$GENERATED_DIR/MOBILE/$client"
        printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/$client/config.yaml"
    done
    setup_publication_server
    local before rc=0 real_mv
    before=$(publication_context)
    real_mv=$(type -P mv)
    mv() {
        if [[ "$1" == "$CONFIG_JSON".tmp.* && "$2" == "$CONFIG_JSON" ]]; then
            printf 'promotion\n' >> "$BATS_TEST_TMPDIR/promotions"
            if jq -e '.clients[] | select(.name=="tablet") | .subscription.token' "$1" >/dev/null; then
                return 77
            fi
        fi
        "$real_mv" "$@"
    }
    state_action subscription_publish_all subscription_publish_all > "$BATS_TEST_TMPDIR/output" 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$(publication_context)" = "$before" ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/promotions" | tr -d ' ')" -eq 2 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/scp-count" | tr -d ' ')" -eq 2 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/apply-count" | tr -d ' ')" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-sweep" ]
    local token
    token=$(jq_r '.clients[0].subscription.token')
    [ -s "$BATS_TEST_TMPDIR/server/yaml/$token.yaml" ]
    run jq -e '.clients[0].subscription.token != null and all(.clients[1:][]; .subscription == null)' "$CONFIG_JSON"
    assert_success
    local files=("$BATS_TEST_TMPDIR/server/yaml/"*.yaml)
    [ "${#files[@]}" -eq 3 ]
    for client in "${files[@]}"; do
        [ "$(cat "$client")" = 'proxies: []' ]
        token="${client##*/}"
        token="${token%.yaml}"
        [ -s "$SUB_SNIPPETS_DIR/sub-$token.conf" ]
        run cat "$BATS_TEST_TMPDIR/output"
        refute_output --partial "$token"
    done
}

@test "single metadata failure reports completed upload without HTTP verification" {
    setup_publication_server
    local before rc=0 real_mv
    before=$(publication_context)
    real_mv=$(type -P mv)
    mv() {
        if [[ "$1" == "$CONFIG_JSON".tmp.* && "$2" == "$CONFIG_JSON" ]]; then return 77; fi
        "$real_mv" "$@"
    }
    curl() { touch "$BATS_TEST_TMPDIR/unexpected-http"; return 1; }
    subscription_publish phone > "$BATS_TEST_TMPDIR/output" 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$(publication_context)" = "$before" ]
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-http" ]
    [ "$(jq_r '.clients[0].subscription // "absent"')" = absent ]
    local files=("$BATS_TEST_TMPDIR/server/yaml/"*.yaml) token
    [ "${#files[@]}" -eq 1 ]
    [ "$(cat "${files[0]}")" = 'proxies: []' ]
    token="${files[0]##*/}"
    token="${token%.yaml}"
    run cat "$BATS_TEST_TMPDIR/output"
    assert_output --partial 'Файл загружен на сервер, но данные подписки сохранить не удалось.'
    refute_output --partial "$token"
}

# ─── security round 1: clients ───────────────────────────────────────────────

# Ядро команд с моками SSH и двумя опубликованными клиентами (как cmd_subscriptions.bats).
_sec_safety() {
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    printf '%s\n' '{"schema_version":2,"nodes":[],"groups":[{"name":"MOBILE","template":"default.yaml"}],"clients":[],"connections":[]}' > "$CONFIG_JSON"
    open_local_session
    ALPHA_TOKEN=$(printf 'a1%.0s' {1..32})
    BETA_TOKEN=$(printf 'b2%.0s' {1..32})
    jq_w --arg a "$ALPHA_TOKEN" --arg b "$BETA_TOKEN" '.nodes = [{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"old",ip:"192.0.2.1",port:22,user:"root",auth:"key"},{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",name:"new",ip:"192.0.2.2",port:2222,user:"root",auth:"key"}] | .clients = [{name:"alpha",group:"MOBILE",subscription:{token:$a,expires_at:"2030-01-01T00:00:00Z",created_at:"2026-01-01",headers:[{name:"User-Agent",value:"test"}]}},{name:"beta",group:"MOBILE",subscription:{token:$b}}] | .subscription_host = {node:"old",base_url:"https://old.example",sub_dir:"/stale/cache",nginx_group:"www-data"} | .subscription_default_headers = []'
    mkdir -p "$GENERATED_DIR/MOBILE/alpha" "$GENERATED_DIR/MOBILE/beta"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/alpha/config.yaml"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/beta/config.yaml"
    SSH_RUN_MOCK_OUTPUT=$'SUB_DIR=/custom/host\nSUB_BASE_URL=https://new.example\nNGINX_GROUP=www-data'
    curl() { printf '200'; }
    state_checkpoint() { return 0; }
}

# Хост подписок для publish-all: листинг каталога отдаёт HOST_LISTING, каждый
# вызов пишется в ssh.log (argv), stdin очистки — в sweep-stdin, остальной — в ssh-stdin.
_publish_all_host() {
    export HOST_LISTING="$1"
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        shift
        printf '%s\n===\n' "$1" >> "$BATS_TEST_TMPDIR/ssh.log"
        case "$1" in
            'test -f /etc/mihomo/subscription.conf') return 0 ;;
            'cd -- '*) printf '%s\n' "$HOST_LISTING"; return 0 ;;
            *'removed=0'*) cat >> "$BATS_TEST_TMPDIR/sweep-stdin"; printf '1\n'; return 0 ;;
        esac
        cat >> "$BATS_TEST_TMPDIR/ssh-stdin"
    }
}

@test "S-M7: publish-all reviews targets and orphaned host subscriptions before any write and prunes only them" {
    _sec_safety
    local orphan token plan
    orphan=$(printf 'c3%.0s' {1..32})
    _publish_all_host "$ALPHA_TOKEN"$'\n'"$orphan"$'\nnot-a-token'
    run_cmd sub publish-all
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    plan=$(cmd_jq '.error.plan | join("\n")')
    [[ "$plan" == *alpha* && "$plan" == *beta* && "$plan" == *"${orphan:0:8}…"* ]]
    [[ "$plan" != *"$orphan"* && "$plan" != *not-a-token* ]]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/ssh-stdin" ]
    [ ! -e "$BATS_TEST_TMPDIR/sweep-stdin" ]
    token=$(cmd_jq '.error.plan_token')
    run_cmd sub publish-all --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.removed')" = 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/sweep-stdin")" = "$orphan" ]
    local argv
    argv=$(cat "$BATS_TEST_TMPDIR/ssh.log")
    [[ "$argv" != *"$orphan"* && "$argv" != *"$ALPHA_TOKEN"* && "$argv" != *"$BETA_TOKEN"* ]]
    [[ "${SCP_RUN_CALLS[*]}" != *"$ALPHA_TOKEN"* && "${SCP_RUN_CALLS[*]}" != *"$BETA_TOKEN"* ]]
}

@test "S-M7: publish-all aborts without remote deletion when no local token is known but the host has subscriptions" {
    _sec_safety
    jq_w '.clients |= map(del(.subscription))'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    _publish_all_host "$(printf 'c3%.0s' {1..32})"
    run_cmd sub publish-all --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = failed ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/ssh-stdin" ]
    [ ! -e "$BATS_TEST_TMPDIR/sweep-stdin" ]
}

@test "S-M1: a corrupted stored token is rejected before any remote command" {
    _sec_safety
    jq_w '.clients[0].subscription.token = "x\" ; touch pwned #"'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd sub rotate --client alpha --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd sub revoke --client alpha --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd sub publish --client alpha
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd sub publish-all --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd sub migrate --node new --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    run _sub_remove_token 'x" ; touch pwned #' /srv/sub
    assert_failure
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "S-M2: header names allow only letters, digits and dashes; stored headers are re-validated before publishing" {
    _sec_safety
    local name
    run_cmd sub headers --client alpha --set "'a=' always; } location /leak { alias /etc/; } location = /dummy { add_header Q x"
    [ "$(cmd_jq '.error.code')" = invalid ]
    for name in X_Test X.Test "X'Q" 'X|Y' 'X$Y'; do
        run_cmd sub headers --group MOBILE --set "$name=v"
        [ "$(cmd_jq '.error.code')" = invalid ] || return 1
    done
    [ "$(jq_r '[.groups[] | select(.name=="MOBILE") | .subscription_headers // [] | .[]] | length')" -eq 0 ]
    # Заголовок из синхронизированной конфигурации, минуя проверку записи.
    jq_w '.clients[0].subscription.headers += [{name:"X'"'"'a", value:"v"}]'
    run_cmd sub publish --client alpha
    [ "$(cmd_jq '.error.code')" = invalid ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    run _render_subscription_snippet alpha "$ALPHA_TOKEN" /srv/sub
    assert_failure
    refute_output --partial 'location'
    jq_w '.clients[0].subscription.headers = [{name:"X-Ok", value:"a\nb"}]'
    run _render_subscription_snippet alpha "$ALPHA_TOKEN" /srv/sub
    assert_failure
    refute_output --partial 'location'
}

@test "S-M4: publishing passes tokens to scp, ssh, curl and jq only through files or stdin" {
    _sec_safety
    jq_w '.clients[1].subscription = null'
    # Не log: run_cmd объявляет свой local log, и обёртки писали бы в журнал команды.
    local argv_log="$BATS_TEST_TMPDIR/argv.log" beta
    jq() { printf 'jq %s\n' "$*" >> "$argv_log"; command jq "$@"; }
    curl() { printf 'curl %s\n' "$*" >> "$argv_log"; cat >> "$BATS_TEST_TMPDIR/curl-stdin"; printf '200'; }
    run_cmd sub publish --client alpha --ttl 30d
    [ "$status" -eq 0 ]
    run_cmd sub publish-all --yes
    [ "$status" -eq 0 ]
    run_cmd sub show --client alpha
    [ "$status" -eq 0 ]
    unset -f jq curl
    beta=$(jq_r '.clients[1].subscription.token')
    [[ "$beta" =~ ^[0-9a-f]{64}$ ]]
    [ "$(cmd_jq '.data.url')" = "https://old.example/sub/$ALPHA_TOKEN" ]
    grep -qxF "url = \"https://old.example/sub/$ALPHA_TOKEN\"" "$BATS_TEST_TMPDIR/curl-stdin"
    local argv
    [ -s "$argv_log" ]
    argv="$(cat "$argv_log")${SSH_RUN_CALLS[*]}${SCP_RUN_CALLS[*]}"
    [[ "$argv" != *"$ALPHA_TOKEN"* && "$argv" != *"$beta"* ]]
}

@test "S-M4: rotation hands tokens to the host only through stdin and edits expiry without sed" {
    _sec_safety
    local t_new_token sub="$BATS_TEST_TMPDIR/sub"
    t_new_token=$(printf 'd4%.0s' {1..32})
    openssl() { printf '%s\n' "$t_new_token"; }
    run_cmd sub rotate --client alpha --yes
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[0].subscription.token')" = "$t_new_token" ]
    [[ "${SSH_RUN_CALLS[*]}${SCP_RUN_CALLS[*]}" != *"$ALPHA_TOKEN"* ]]
    [[ "${SSH_RUN_CALLS[*]}${SCP_RUN_CALLS[*]}" != *"$t_new_token"* ]]
    # Удалённый скрипт правит expiry.list точным сравнением первого поля, без sed.
    SUB_SNIPPETS_DIR="$BATS_TEST_TMPDIR/snippets"
    mkdir -p "$sub" "$SUB_SNIPPETS_DIR"
    printf 'proxies: []\n' > "$sub/$ALPHA_TOKEN.yaml"
    printf '%s 100\n%s9 200\ncccc 300\n' "$ALPHA_TOKEN" "${ALPHA_TOKEN:0:63}" > "$sub/expiry.list"
    nginx() { :; }
    systemctl() { :; }
    flock() { :; }
    sed() { touch "$BATS_TEST_TMPDIR/sed-used"; command sed "$@"; }
    export -f nginx systemctl flock sed
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        shift
        printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/remote-argv"
        ( eval "$1" )
    }
    _sub_remove_token "$ALPHA_TOKEN" "$sub" "$t_new_token"
    printf '%s 100\n%s9 200\ncccc 300\n' "$t_new_token" "${ALPHA_TOKEN:0:63}" > "$BATS_TEST_TMPDIR/expected.expiry"
    cmp "$sub/expiry.list" "$BATS_TEST_TMPDIR/expected.expiry"
    [ ! -e "$sub/$ALPHA_TOKEN.yaml" ]
    [ ! -e "$BATS_TEST_TMPDIR/sed-used" ]
    [[ "$(cat "$BATS_TEST_TMPDIR/remote-argv")" != *"$ALPHA_TOKEN"* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/remote-argv")" != *"$t_new_token"* ]]
    unset -f nginx systemctl flock sed
}

# ─── round 2: clients ────────────────────────────────────────────────────────

# Хост подписок в песочнице: удалённые команды выполняются локально над каталогами
# теста (как в cmd_subscriptions.bats). У phone опубликована подписка со сроком:
# expiry.list хоста — «OLD_TOKEN 2000000000»; новый токен — NEW_TOKEN.
_r2_sub_host() {
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    open_local_session
    OLD_TOKEN=$(printf 'a%.0s' {1..64})
    NEW_TOKEN=$(printf 'b%.0s' {1..64})
    export OLD_TOKEN NEW_TOKEN
    export SUB_DIR="$BATS_TEST_TMPDIR/subscriptions"
    export SUB_SNIPPETS_DIR="$BATS_TEST_TMPDIR/snippets"
    mkdir -p "$SUB_DIR" "$SUB_SNIPPETS_DIR"
    cp "$GENERATED_DIR/MOBILE/phone/config.yaml" "$SUB_DIR/$OLD_TOKEN.yaml"
    printf 'location = /sub/x {}\n' > "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf"
    printf '%s 2000000000\n' "$OLD_TOKEN" > "$SUB_DIR/expiry.list"
    jq_w --arg token "$OLD_TOKEN" --arg dir "$SUB_DIR" '
        .subscription_host = {node:"vps-1",base_url:"https://example.test",sub_dir:$dir,nginx_group:"www-data"} |
        .subscription_default_headers = [] |
        .clients = [{name:"phone",group:"MOBILE",subscription:{token:$token,expires_at:"2033-05-18T03:33:20Z",created_at:"2026-01-01T00:00:00Z"}}]'
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        [[ "${1:-}" == -- ]] && shift
        SSH_RUN_CALLS+=("$*")
        [[ "$*" == 'test -f /etc/mihomo/subscription.conf' ]] && return 0
        ( eval "$*" )
    }
    scp_run() { command cp "$1" "${2#*:}"; }
    openssl() { if [[ "$1" == rand ]]; then printf '%s\n' "$NEW_TOKEN"; else command openssl "$@"; fi; }
    chown() { return 0; }
    flock() { return 0; }
    nginx() { return 0; }
    systemctl() { return 0; }
    curl() { printf '200'; }
    export -f ssh_run scp_run openssl chown flock curl nginx systemctl
    state_checkpoint() { echo checkpoint >> "$BATS_TEST_TMPDIR/persist.log"; }
}

@test "R2-H2: re-publish keeps the TTL without --ttl and replaces the host expiry entry with --ttl" {
    _r2_sub_host
    run_cmd sub publish --client phone
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[0].subscription.expires_at')" = 2033-05-18T03:33:20Z ]
    [ "$(cmd_jq '.data.expires_at')" = 2033-05-18T03:33:20Z ]
    [ "$(cat "$SUB_DIR/expiry.list")" = "$OLD_TOKEN 2000000000" ]
    printf 'cccc 2100000000\n' >> "$SUB_DIR/expiry.list"
    run_cmd sub publish --client phone --ttl 520w
    [ "$status" -eq 0 ]
    local ts
    ts=$(_sub_iso_to_epoch "$(jq_r '.clients[0].subscription.expires_at')")
    [ "$ts" -gt 2000000000 ]
    [ "$(grep -c "^$OLD_TOKEN " "$SUB_DIR/expiry.list")" -eq 1 ]
    grep -qx "$OLD_TOKEN $ts" "$SUB_DIR/expiry.list"
    grep -qx 'cccc 2100000000' "$SUB_DIR/expiry.list"
}

@test "R2-H2: client set-group republishes without dropping the subscription TTL" {
    _r2_sub_host
    jq_w '.groups += [{name:"PC",template:"default.yaml"}]'
    _prefetch_node_configs() { :; }
    _generate_group() { mkdir -p "$GENERATED_DIR/$1/phone"; printf 'proxies: []\n' > "$GENERATED_DIR/$1/phone/config.yaml"; }
    _sync_listeners_on_nodes() { return 0; }
    run_cmd client set-group --name phone --group PC --yes
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[0].group')" = PC ]
    [ "$(jq_r '.clients[0].subscription.expires_at')" = 2033-05-18T03:33:20Z ]
    [ "$(cat "$SUB_DIR/expiry.list")" = "$OLD_TOKEN 2000000000" ]
}

@test "R2-H3: a failed HTTP check after the rotate commit is partial with the new link and is persisted" {
    _r2_sub_host
    curl() { printf '502'; }
    export -f curl
    run_cmd sub rotate --client phone --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq '.data.url')" = "https://example.test/sub/$NEW_TOKEN" ]
    [ "$(jq_r '.clients[0].subscription.token')" = "$NEW_TOKEN" ]
    [ "$(cat "$BATS_TEST_TMPDIR/persist.log")" = checkpoint ]
    # GitHub: partial тоже попадает в снимок и отправляется.
    rm -f "$BATS_TEST_TMPDIR/persist.log"
    NEW_TOKEN=$(printf 'c%.0s' {1..64})
    CONFIG_SOURCE=github
    state_validate() { return 0; }
    config_persist_candidate() { mv "$1" "$CONFIG_JSON"; }
    github_config_checkpoint() { echo gh_checkpoint >> "$BATS_TEST_TMPDIR/persist.log"; }
    github_sync_flush() { echo gh_flush >> "$BATS_TEST_TMPDIR/persist.log"; }
    run_cmd sub rotate --client phone --yes
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(jq_r '.clients[0].subscription.token')" = "$NEW_TOKEN" ]
    [ "$(tr '\n' ' ' < "$BATS_TEST_TMPDIR/persist.log")" = 'checkpoint gh_checkpoint gh_flush ' ]
}

@test "R2-H3: a failed HTTP check after publishing a new token is partial with the link and is persisted" {
    _r2_sub_host
    jq_w '.clients[0].subscription = {}'
    curl() { printf '000'; }
    export -f curl
    run_cmd sub publish --client phone
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq '.data.url')" = "https://example.test/sub/$NEW_TOKEN" ]
    [ "$(jq_r '.clients[0].subscription.token')" = "$NEW_TOKEN" ]
    [ "$(cat "$BATS_TEST_TMPDIR/persist.log")" = checkpoint ]
}

@test "R2-H3: publish-all reports clients with saved tokens as published when a later token save fails" {
    _r2_sub_host
    local c
    for c in tab pad; do
        mkdir -p "$GENERATED_DIR/MOBILE/$c"
        printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/$c/config.yaml"
    done
    jq_w '.clients += [{name:"tab",group:"MOBILE"},{name:"pad",group:"MOBILE"}]'
    openssl() {
        if [[ "$1" == rand ]]; then
            local n
            n=$(( $(cat "$BATS_TEST_TMPDIR/rand" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$BATS_TEST_TMPDIR/rand"
            printf '%064d\n' "$n"
        else command openssl "$@"; fi
    }
    run_cmd sub publish-all
    local token saves=0
    token=$(cmd_jq '.error.plan_token')
    eval "$(declare -f _sub_jq_w_token | sed '1s/_sub_jq_w_token/_r2_real_jq_w_token/')"
    _sub_jq_w_token() { saves=$((saves + 1)); (( saves == 1 )) && _r2_real_jq_w_token "$@"; }
    run_cmd sub publish-all --yes --plan-token "$token"
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq -c '.data.published')" = '["phone","tab"]' ]
    [ "$(cmd_jq -c '.data.failed')" = '["pad"]' ]
    [[ "$(jq_r '.clients[1].subscription.token')" =~ ^[0-9]{64}$ ]]
    [ "$(jq_r '.clients[2].subscription.token // "none"')" = none ]
    [ "$(cat "$BATS_TEST_TMPDIR/persist.log")" = checkpoint ]
}

@test "R2-L4: publish-all reports partial when the planned orphan sweep fails" {
    _r2_sub_host
    local orphan token
    orphan=$(printf 'c%.0s' {1..64})
    printf 'x\n' > "$SUB_DIR/$orphan.yaml"
    run_cmd sub publish-all
    token=$(cmd_jq '.error.plan_token')
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        [[ "${1:-}" == -- ]] && shift
        [[ "$*" == *'removed=0'* ]] && return 255
        [[ "$*" == 'test -f /etc/mihomo/subscription.conf' ]] && return 0
        ( eval "$*" )
    }
    export -f ssh_run
    run_cmd sub publish-all --yes --plan-token "$token"
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq -c '.data.published')" = '["phone"]' ]
    [ "$(cmd_jq '.data.removed')" = 0 ]
    [ -e "$SUB_DIR/$orphan.yaml" ]
}

@test "R2-L5: sub headers checks every --set and --unset before one atomic write" {
    _r2_sub_host
    jq_w '.clients[0].subscription.headers = [{name:"X-Old",value:"o"}]'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd sub headers --client phone --set X-A=1 --set 'bad name=2'
    [ "$(cmd_jq '.error.code')" = invalid ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run_cmd sub headers --client phone --set X-A=1 --unset X-Old --set X-B=
    [ "$(cmd_jq '.error.code')" = usage ]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    [ ! -e "$BATS_TEST_TMPDIR/persist.log" ]
    run_cmd sub headers --client phone --set X-A=1 --set X-B=2 --unset X-Old
    [ "$status" -eq 0 ]
    [ "$(jq_r -c '.clients[0].subscription.headers')" = '[{"name":"X-A","value":"1"},{"name":"X-B","value":"2"}]' ]
    [ "$(cat "$BATS_TEST_TMPDIR/persist.log")" = checkpoint ]
    run_cmd sub headers --group MOBILE --set X-G=1 --unset X-None
    [ "$status" -eq 0 ]
    [ "$(jq_r -c '.groups[0].subscription_headers')" = '[{"name":"X-G","value":"1"}]' ]
}

@test "R2-L8: an expiry write failure after upload removes a new subscription and keeps an existing one" {
    _r2_sub_host
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/published.json"
    jq_w '.clients[0].subscription = {}'
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        [[ "${1:-}" == -- ]] && shift
        [[ "$*" == *'list.migrate.'* ]] && return 1
        [[ "$*" == 'test -f /etc/mihomo/subscription.conf' ]] && return 0
        ( eval "$*" )
    }
    export -f ssh_run
    run_cmd sub publish --client phone --ttl 1d
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [[ "$(cmd_jq '.error.message')" == *'Срок подписки не записан'*'загруженная подписка удалена'* ]]
    [ ! -e "$SUB_DIR/$NEW_TOKEN.yaml" ]
    [ ! -e "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" ]
    [ "$(jq_r '.clients[0].subscription.token // "none"')" = none ]
    cp "$BATS_TEST_TMPDIR/published.json" "$CONFIG_JSON"
    run_cmd sub publish --client phone --ttl 1d
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [[ "$(cmd_jq '.error.message')" == *'действует прежний срок'* ]]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/published.json"
    [ -s "$SUB_DIR/$OLD_TOKEN.yaml" ]
    [ "$(cat "$SUB_DIR/expiry.list")" = "$OLD_TOKEN 2000000000" ]
}

@test "R2-M10: CRLF output of jq breaks neither the subscription state nor snippet headers" {
    _r2_sub_host
    jq_w '.subscription_default_headers = [{name:"profile-update-interval",value:"24"}] |
        .clients[0].subscription.expires_at = "2030-01-01T00:00:00Z"'
    local out
    jq() { command jq "$@" | sed 's/$/\r/'; }
    run_cmd sub list
    out=$(_render_subscription_snippet phone "$OLD_TOKEN" /srv/sub)
    unset -f jq
    [ "$(cmd_jq '.data[0].state')" = active ]
    [[ "$out" == *"add_header profile-update-interval '24' always;"* ]]
    [[ "$out" != *$'\r'* ]]
}
