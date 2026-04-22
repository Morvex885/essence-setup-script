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
    assert_output --partial "Host-нода не задана"
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
