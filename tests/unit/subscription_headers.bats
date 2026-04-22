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
  "connections": []
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
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "2"
}

@test "inherit: client overrides group header by name" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    subscription_group_set_header "MOBILE" "X-Profile" "default"
    subscription_set_header "phone" "X-Profile" "mobile"

    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq -r '.[] | select(.name==\"X-Profile\") | .value'"
    assert_output "mobile"
}

@test "inherit: client adds header not in group" {
    subscription_group_set_header "MOBILE" "User-Agent" "clash-meta"
    subscription_set_header "phone" "X-Custom" "value"

    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "2"
}

@test "inherit: group empty, client has headers" {
    subscription_set_header "phone" "X-Custom" "value"
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "1"
}

@test "inherit: both empty" {
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
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

@test "_ensure_default_headers writes defaults if missing" {
    _ensure_default_headers
    run jq_r '.subscription_default_headers | length'
    assert_output "2"
    run jq_r '.subscription_default_headers[] | select(.name=="profile-update-interval") | .value'
    assert_output "24"
    run jq_r '.subscription_default_headers[] | select(.name=="Content-Disposition") | .value'
    assert_output 'attachment; filename="config.yaml"'
}

@test "_ensure_default_headers is idempotent" {
    _ensure_default_headers
    jq_w '.subscription_default_headers[0].value = "modified"'
    _ensure_default_headers
    # Не перезаписывает если уже есть
    run jq_r '.subscription_default_headers[0].value'
    assert_output "modified"
}

@test "inherit: defaults included in resolved headers" {
    _ensure_default_headers
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq length"
    assert_output "2"
}

@test "inherit: group overrides default by name" {
    _ensure_default_headers
    subscription_group_set_header "MOBILE" "profile-update-interval" "6"
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq -r '.[] | select(.name==\"profile-update-interval\") | .value'"
    assert_output "6"
}

@test "inherit: client overrides group which overrides default (chain)" {
    _ensure_default_headers
    subscription_group_set_header "MOBILE" "profile-update-interval" "6"
    subscription_set_header "phone" "profile-update-interval" "1"
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers phone | jq -r '.[] | select(.name==\"profile-update-interval\") | .value'"
    assert_output "1"
}

@test "annotated: default source labelled" {
    _ensure_default_headers
    run bash -c "source '$PROJECT_ROOT/common/common.sh'; error() { return 1; }; export CONFIG_JSON='$CONFIG_JSON'; source '$PROJECT_ROOT/remote-control/modules/subscription.sh'; _resolve_headers_annotated phone | grep -c '|default$' || true"
    assert_output "2"
}
