#!/usr/bin/env bats
# Tests for _render_subscription_snippet (per-token nginx location block)

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "groups.sh"
    source_module "clients.sh"
    source_module "subscription.sh"

    cat > "$CONFIG_JSON" <<'EOF'
{
  "nodes": [{"name":"vps-1","ip":"1.2.3.4","port":"22","user":"root","auth":"key"}],
  "groups": [
    {"name":"MOBILE","template":"default.yaml"}
  ],
  "clients": [
    {"name":"phone","group":"MOBILE"}
  ],
  "connections": [{"node":"vps-1","groups":[{"name":"MOBILE","proxies":["VLESS TCP"]}]}],
  "subscription_default_headers": [
    {"name":"Content-Disposition","value":"attachment; filename=\"config.yaml\""},
    {"name":"profile-update-interval","value":"24"}
  ]
}
EOF
}

teardown() {
    teardown_test_env
}

TOKEN="aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"

@test "snippet: starts with location = /sub/<token>" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_line --index 0 "location = /sub/${TOKEN} {"
}

@test "snippet: contains alias to yaml file" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial "alias /var/lib/essence-sub/${TOKEN}.yaml;"
}

@test "snippet: hardcoded Cache-Control invariant present" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial 'add_header Cache-Control "no-store" always;'
}

@test "snippet: hardcoded X-Content-Type-Options invariant present" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial 'add_header X-Content-Type-Options nosniff always;'
}

@test "snippet: limit_req present" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial "limit_req zone=sub burst=5 nodelay;"
}

@test "snippet: ends with closing brace" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_line --index -1 "}"
}

@test "snippet: defaults rendered as add_header lines" {
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    # Content-Disposition: содержит ", но не ' → wrap в одинарные кавычки (литерально)
    assert_output --partial $'add_header Content-Disposition \'attachment; filename="config.yaml"\' always;'
    # profile-update-interval — без спецсимволов → одинарные кавычки
    assert_output --partial "add_header profile-update-interval '24' always;"
}

@test "snippet: group header overrides default" {
    subscription_group_set_header "MOBILE" "profile-update-interval" "6"
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial "add_header profile-update-interval '6' always;"
    refute_output --partial "'24'"
}

@test "snippet: client header overrides group" {
    subscription_group_set_header "MOBILE" "profile-update-interval" "6"
    subscription_set_header "phone" "profile-update-interval" "1"
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial "add_header profile-update-interval '1' always;"
    refute_output --partial "'6'"
}

@test "snippet: quoting — value with spaces and colons in single quotes" {
    subscription_set_header "phone" "flclashx-view" "type:list; sort:delay"
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial "add_header flclashx-view 'type:list; sort:delay' always;"
}

@test "snippet: quoting — value with single-quote falls back to double-quoted" {
    subscription_set_header "phone" "X-Test" "it's-here"
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial 'add_header X-Test "it'"'"'s-here" always;'
}

@test "snippet: quoting — backslash inside double-quoted gets escaped" {
    subscription_set_header "phone" "X-Test" "a'b\\c"
    run _render_subscription_snippet "phone" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial 'add_header X-Test "a'"'"'b\\c" always;'
}

@test "snippet: client without group still gets defaults" {
    jq_w '.clients += [{"name":"orphan"}]'
    run _render_subscription_snippet "orphan" "$TOKEN" "/var/lib/essence-sub"
    assert_output --partial "profile-update-interval"
    assert_output --partial "Content-Disposition"
}
