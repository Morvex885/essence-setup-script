#!/usr/bin/env bats
# Tests for subscription header management and group→client inheritance

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "groups.sh"
    source_module "clients.sh"
    source_module "subscription.sh"

    # Config with group + client
    cat > "$CONFIG_JSON" <<'EOF'
{
  "nodes": [{"name":"vps-1","ip":"1.2.3.4","port":"22","user":"root","auth":"key"}],
  "groups": [
    {"name":"MOBILE","template":"default.yaml"},
    {"name":"PC","template":"default.yaml"}
  ],
  "clients": [
    {"name":"phone","group":"MOBILE"},
    {"name":"laptop","group":"PC"}
  ],
  "connections": [],
  "subscription_default_headers": []
}
EOF
}

teardown() {
    teardown_test_env
}

@test "set client header" {
    subscription_set_header "phone" "User-Agent" "clash-meta"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers[0].name'
    assert_output "User-Agent"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers[0].value'
    assert_output "clash-meta"
}

@test "del client header" {
    subscription_set_header "phone" "User-Agent" "clash-meta"
    subscription_set_header "phone" "X-Profile" "mobile"
    subscription_del_header "phone" "User-Agent"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers | length'
    assert_output "1"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers[0].name'
    assert_output "X-Profile"
}

@test "set group header" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    run jq_r '.groups[] | select(.name=="MOBILE") | .subscription_headers[0].name'
    assert_output "User-Agent"
}

@test "del group header" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    subscription_group_set_header "MOBILE" "X-Profile" "default"
    subscription_group_del_header "MOBILE" "User-Agent"
    run jq_r '.groups[] | select(.name=="MOBILE") | .subscription_headers | length'
    assert_output "1"
}

@test "inherit: client with no headers gets group headers" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    subscription_group_set_header "MOBILE" "X-Profile" "default"
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "2"
}

@test "inherit: client overrides group header by name" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    subscription_group_set_header "MOBILE" "X-Profile" "default"
    subscription_set_header "phone" "X-Profile" "mobile"

    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq -r '.[] | select(.name==\"X-Profile\") | .value'"
    assert_output "mobile"
}

@test "inherit: client adds header not in group" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    subscription_set_header "phone" "X-Custom" "value"

    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "2"
}

@test "inherit: group empty, client has headers" {
    subscription_set_header "phone" "X-Custom" "value"
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "1"
}

@test "inherit: both empty" {
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "0"
}

@test "header name validation: reject CRLF in value" {
    run subscription_set_header "phone" "X-Test" $'val\r\nue'
    assert_failure
}

@test "header name validation: reject invalid chars" {
    run subscription_set_header "phone" "X Test" "value"
    assert_failure
}

@test "set header: update existing header" {
    subscription_set_header "phone" "User-Agent" "old"
    subscription_set_header "phone" "User-Agent" "new"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers | length'
    assert_output "1"
    run jq_r '.clients[] | select(.name=="phone") | .subscription.headers[0].value'
    assert_output "new"
}

@test "header value validation: reject trailing backslash" {
    run subscription_set_header "phone" "X-Test" 'value\'
    assert_failure
}

@test "built-in default headers apply when the key is missing and do not write config" {
    jq_w 'del(.subscription_default_headers)'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
    run jq -r --argjson d "$_SUB_DEFAULT_HEADERS_JSON" '$d | length' <<< '{}'
    assert_output "2"
    run jq -r --argjson d "$_SUB_DEFAULT_HEADERS_JSON" '$d[] | select(.name=="profile-update-interval") | .value' <<< '{}'
    assert_output "24"
    run jq -r --argjson d "$_SUB_DEFAULT_HEADERS_JSON" '$d[] | select(.name=="Content-Disposition") | .value' <<< '{}'
    assert_output 'attachment; filename="config.yaml"'
    _resolve_headers phone > /dev/null
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before.json"
}

@test "explicit empty default headers override the built-in ones" {
    run _resolve_headers phone
    assert_output "[]"
}

@test "inherit: defaults included in resolved headers" {
    jq_w 'del(.subscription_default_headers)'
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "2"
}

@test "inherit: group overrides default by name" {
    jq_w 'del(.subscription_default_headers)'
    subscription_group_set_header "MOBILE" "profile-update-interval" "6"
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq -r '.[] | select(.name==\"profile-update-interval\") | .value'"
    assert_output "6"
}

@test "subscription host lookup restores the complete selected-node context" {
    NODE_ID=selected-id NODE_NAME=selected NODE_IDENTITY=selected-key NODE_TAG=DE
    SERVER_IP=192.0.2.1 SERVER_PORT=2222 SERVER_USER=admin
    SERVER_PASS=secret SERVER_AUTH=password
    _sub_save_ssh_ctx

    NODE_ID=host-id NODE_NAME=host NODE_IDENTITY=host-key NODE_TAG=US
    SERVER_IP=192.0.2.2 SERVER_PORT=22 SERVER_USER=root
    SERVER_PASS= SERVER_AUTH=key
    _sub_restore_ssh_ctx

    [[ "$NODE_ID/$NODE_NAME/$NODE_IDENTITY/$NODE_TAG" == \
       "selected-id/selected/selected-key/DE" ]]
    [[ "$SERVER_IP/$SERVER_PORT/$SERVER_USER/$SERVER_PASS/$SERVER_AUTH" == \
       "192.0.2.1/2222/admin/secret/password" ]]
}

@test "inherit: client overrides group which overrides default (chain)" {
    jq_w 'del(.subscription_default_headers)'
    subscription_group_set_header "MOBILE" "profile-update-interval" "6"
    subscription_set_header "phone" "profile-update-interval" "1"
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq -r '.[] | select(.name==\"profile-update-interval\") | .value'"
    assert_output "1"
}

@test "annotated: default source labelled" {
    jq_w 'del(.subscription_default_headers)'
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers_annotated phone | grep -c '|default$' || true"
    assert_output "2"
}
