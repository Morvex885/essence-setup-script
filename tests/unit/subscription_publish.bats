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
  "nodes": [{"name":"vps-1","ip":"1.2.3.4","port":"22","user":"root","auth":"key"}],
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
    # Override confirm_yn for non-interactive
    confirm_yn() { return 0; }
    export -f confirm_yn

    subscription_revoke "phone"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    assert_output "empty"
}

@test "revoke preserves headers" {
    subscription_set_header "phone" "User-Agent" "clash-meta"
    subscription_publish "phone"

    confirm_yn() { return 0; }
    export -f confirm_yn

    subscription_revoke "phone"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers[0].name'
    assert_output "User-Agent"
}

@test "rotate changes token" {
    subscription_publish "phone"
    local old_token
    old_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    subscription_rotate "phone" <<< 'y'
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

    run subscription_publish "phone"
    assert_success
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
    refute_output --partial 'Опубликовано:'
}

@test "single metadata failure reports completed upload without sharing or HTTP verification" {
    setup_publication_server
    local before rc=0 real_mv
    before=$(publication_context)
    real_mv=$(type -P mv)
    mv() {
        if [[ "$1" == "$CONFIG_JSON".tmp.* && "$2" == "$CONFIG_JSON" ]]; then return 77; fi
        "$real_mv" "$@"
    }
    curl() { touch "$BATS_TEST_TMPDIR/unexpected-http"; return 1; }
    _show_share_bundle() { touch "$BATS_TEST_TMPDIR/unexpected-share"; }
    subscription_publish phone > "$BATS_TEST_TMPDIR/output" 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$(publication_context)" = "$before" ]
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-http" ]
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-share" ]
    [ "$(jq_r '.clients[0].subscription // "absent"')" = absent ]
    local files=("$BATS_TEST_TMPDIR/server/yaml/"*.yaml) token
    [ "${#files[@]}" -eq 1 ]
    [ "$(cat "${files[0]}")" = 'proxies: []' ]
    token="${files[0]##*/}"
    token="${token%.yaml}"
    run cat "$BATS_TEST_TMPDIR/output"
    assert_output --partial 'Файл загружен на сервер, но данные подписки сохранить не удалось.'
    refute_output --partial 'Ошибка загрузки файла на сервер.'
    refute_output --partial "$token"
    refute_output --partial 'Подписка опубликована:'
}
