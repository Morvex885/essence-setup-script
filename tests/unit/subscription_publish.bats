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

    # Mock ssh_run, scp_run, curl
    ssh_run() { return 0; }
    scp_run() { return 0; }
    curl() { echo "200"; return 0; }
    export -f ssh_run scp_run curl
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

    subscription_rotate "phone"
    local new_token
    new_token=$(jq_r '.clients[] | select(.name=="phone") | .subscription.token')

    [ "$old_token" != "$new_token" ]
}

@test "publish warns without host node" {
    jq_w 'del(.subscription_host)'
    run subscription_publish "phone"
    assert_output --partial "Хост-нода подписок не задана"
}

@test "publish warns without generated config" {
    rm -f "$GENERATED_DIR/MOBILE/phone/config.yaml"
    run subscription_publish "phone"
    assert_output --partial "не найден"
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
    ssh_run() { echo "SUB_DIR=/custom/path"; return 0; }
    export -f ssh_run

    run _sub_get_dir
    assert_output "/custom/path"
}

@test "publish rejects a whitespace-only config without token or SCP" {
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/phone/config.yaml"
    scp_run() {
        echo "unexpected scp" >&2
        return 1
    }

    run subscription_publish "phone"
    assert_success
    assert_output --partial "Конфиг для 'phone' не найден или пуст. Сначала сгенерируйте конфиги."
    refute_output --partial "unexpected scp"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    assert_output "empty"
}

@test "publish_all skips whitespace-only clients and publishes valid clients" {
    jq_w '.clients += [{"name":"tablet","group":"MOBILE"}]'
    mkdir -p "$GENERATED_DIR/MOBILE/tablet"
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/tablet/config.yaml"

    run subscription_publish_all
    assert_success
    assert_output --partial "Пропущено (конфиг отсутствует или пуст): 1"

    run jq_r '.clients[] | select(.name=="phone") | .subscription.token // "empty"'
    refute_output "empty"
    run jq_r '.clients[] | select(.name=="tablet") | .subscription.token // "empty"'
    assert_output "empty"
}

@test "auto-refresh does not prompt when all generated configs are blank" {
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/phone/config.yaml"
    confirm_yn() {
        echo "unexpected prompt" >&2
        return 1
    }

    run _subscription_prompt_refresh
    assert_success
    refute_output --partial "unexpected prompt"
}

@test "low-level batch upload rejects a whitespace-only source before SCP" {
    local blank_config="$BATS_TEST_TMPDIR/blank.yaml"
    printf ' \n\t\n' > "$blank_config"
    scp_run() {
        echo "unexpected scp" >&2
        return 1
    }

    run _sub_upload_batch "/var/lib/essence-sub" "www-data" \
        "$blank_config" "token-1" "phone"
    assert_failure
    assert_output --partial "YAML-конфигурация отсутствует или пуста — загрузка отменена."
    refute_output --partial "unexpected scp"
}
