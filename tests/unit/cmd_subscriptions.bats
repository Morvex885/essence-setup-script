#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    open_local_session
}

teardown() {
    unset -f rm sed cp nginx systemctl ssh_run scp_run openssl chown flock curl _rotation_fault mv
    teardown_test_env
}

_prepare_safety() {
    ALPHA_TOKEN=$(printf 'a1%.0s' {1..32})
    BETA_TOKEN=$(printf 'b2%.0s' {1..32})
    jq_w --arg a "$ALPHA_TOKEN" --arg b "$BETA_TOKEN" '.nodes = [{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"old",ip:"192.0.2.1",port:22,user:"root",auth:"key"},{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",name:"new",ip:"192.0.2.2",port:2222,user:"root",auth:"key"}] | .clients = [{name:"alpha",group:"MOBILE",subscription:{token:$a,expires_at:"2030-01-01T00:00:00Z",created_at:"2026-01-01",headers:[{name:"User-Agent",value:"test"}]}},{name:"beta",group:"MOBILE",subscription:{token:$b}}] | .subscription_host = {node:"old",base_url:"https://old.example",sub_dir:"/stale/cache",nginx_group:"www-data"} | .subscription_default_headers = []'
    mkdir -p "$GENERATED_DIR/MOBILE/alpha" "$GENERATED_DIR/MOBILE/beta"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/alpha/config.yaml"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/beta/config.yaml"
    SSH_RUN_MOCK_OUTPUT=$'SUB_DIR=/custom/host\nSUB_BASE_URL=https://new.example\nNGINX_GROUP=www-data'
    curl() { printf '200'; }
    # Fixture has no state manifest to checkpoint.
    state_checkpoint() { return 0; }
}

_prepare_rotation() {
    export OLD_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export NEW_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    export SUB_DIR="$BATS_TEST_TMPDIR/subscriptions"
    export SUB_SNIPPETS_DIR="$BATS_TEST_TMPDIR/snippets"
    export RUNTIME_DIR="$BATS_TEST_TMPDIR/running-routes"
    export FAIL_STAGE="" RECOVERY_FAIL="" TRANSPORT_LOSS=false
    mkdir -p "$SUB_DIR" "$SUB_SNIPPETS_DIR" "$RUNTIME_DIR" "$GENERATED_DIR/MOBILE/phone"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cp "$GENERATED_DIR/MOBILE/phone/config.yaml" "$SUB_DIR/$OLD_TOKEN.yaml"
    printf 'location = /sub/%s { alias %s/%s.yaml; }\n' "$OLD_TOKEN" "$SUB_DIR" "$OLD_TOKEN" > "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf"
    printf '%s 2000000000\ncccc 2100000000\n' "$OLD_TOKEN" > "$SUB_DIR/expiry.list"
    cp "$SUB_DIR/$OLD_TOKEN.yaml" "$BATS_TEST_TMPDIR/expected.yaml"
    cp "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/expected.expiry"
    cp "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" "$RUNTIME_DIR/"
    jq_w --arg token "$OLD_TOKEN" --arg dir "$SUB_DIR" '
        .nodes = [{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"host",ip:"192.0.2.1",port:22,user:"root",auth:"key"}] |
        .subscription_host = {node:"host",base_url:"https://example.test",sub_dir:$dir,nginx_group:"www-data"} |
        .subscription_default_headers = [] |
        .clients = [{name:"phone",group:"MOBILE",subscription:{token:$token,expires_at:"2033-05-18T03:33:20Z",created_at:"2026-01-01T00:00:00Z",headers:[{name:"profile-title",value:"phone"}]}}]'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"

    # Execute the entire generated SSH command locally. Only transport, ownership,
    # locking and the nginx service are mocked; file operations touch the sandbox.
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        [[ "${1:-}" == -- ]] && shift
        if [[ "$*" == 'test -f /etc/mihomo/subscription.conf' ]]; then return 0; fi
        if $TRANSPORT_LOSS; then
            ( eval "$*" ) >/dev/null 2>&1
            printf '%s\n' "$OLD_TOKEN $NEW_TOKEN" >&2
            return 255
        fi
        ( eval "$*" )
    }
    scp_run() {
        local source="$1" destination="$2"
        command cp "$source" "${destination#*:}"
    }
    openssl() { printf '%s\n' "$NEW_TOKEN"; }
    chown() { return 0; }
    flock() { return 0; }
    curl() { printf '200\n'; }
    _rotation_fault() {
        [[ "$FAIL_STAGE" == "$1" && ! -e "$BATS_TEST_TMPDIR/fault-used" && ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]] || return 1
        touch "$BATS_TEST_TMPDIR/fault-used" "$BATS_TEST_TMPDIR/deleted-before-$1"
        # Deliberately noisy diagnostics must not reach UI output.
        printf '%s\n' "$OLD_TOKEN $NEW_TOKEN"
        printf '%s\n' "$OLD_TOKEN $NEW_TOKEN" >&2
        return 0
    }
    rm() {
        command rm "$@" || return $?
        if [[ "${1:-}" == -f ]] && _rotation_fault rm; then return 1; fi
    }
    cp() {
        if [[ "${1:-}" == -p && "$2" == *'/.subscription-remove.'* && -e "$BATS_TEST_TMPDIR/fault-used" ]]; then
            if [[ "$RECOVERY_FAIL" == files && "$2" == */yaml ]] ||
                [[ "$RECOVERY_FAIL" == expiry && "$2" == */expiry ]]; then
                printf '%s\n' "$OLD_TOKEN $NEW_TOKEN" >&2
                return 1
            fi
        fi
        command cp "$@" || return 1
        # Сбой после записи отредактированного expiry.list (замена или удаление токена).
        if [[ "${*: -1}" == */expiry.list ]] && _rotation_fault expiry; then return 1; fi
        return 0
    }
    nginx() {
        if _rotation_fault nginx; then return 1; fi
        if [[ "$RECOVERY_FAIL" == nginx && -e "$BATS_TEST_TMPDIR/fault-used" ]]; then return 1; fi
        return 0
    }
    systemctl() {
        [[ "$*" == 'reload nginx' ]] || return 1
        if [[ "$RECOVERY_FAIL" == reload && -e "$BATS_TEST_TMPDIR/fault-used" ]]; then return 1; fi
        command rm -f "$RUNTIME_DIR"/*.conf
        local snippet
        for snippet in "$SUB_SNIPPETS_DIR"/*.conf; do
            [[ -f "$snippet" ]] || continue
            command cp "$snippet" "$RUNTIME_DIR/" || return 1
        done
        # Simulate an ambiguous reload failure after the running routes changed.
        _rotation_fault reload && return 1
        return 0
    }
    export -f ssh_run scp_run openssl chown flock curl _rotation_fault rm cp nginx systemctl
    # Wrappers save through state_action; this fixture has no state manifest.
    state_checkpoint() { return 0; }
}

@test 'host change with published tokens requires migration and preserves all state' {
    _prepare_safety
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before-host.json"
    run_cmd sub host --node new --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = conflict ]
    [[ "$(cmd_jq '.error.message')" == *'sub migrate --node new'* ]]
    cmp -s "$CONFIG_JSON" "$BATS_TEST_TMPDIR/before-host.json"
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
}

@test 'host assignment allows initial host same host and change without tokens' {
    _prepare_safety
    run_cmd sub host --node old
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.node')" = old ]
    jq_w 'del(.subscription_host)'
    run_cmd sub host --node new
    [ "$status" -eq 0 ]
    [ "$(jq_r '.subscription_host.node')" = new ]
    jq_w '.clients |= map(del(.subscription.token))'
    run_cmd sub host --node old
    [ "$status" -eq 0 ]
    [ "$(jq_r '.subscription_host.node')" = old ]
}

@test 'migration preserves old data after second upload fails and conceals tokens' {
    _prepare_safety
    local before
    before=$(jq_r '.subscription_host, .clients')
    _sub_upload_config() { [[ "$5" != beta ]]; }
    run_cmd sub migrate --node new --yes
    [ "$status" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
    local command
    # Link removal (_sub_remove_token) deletes the YAML and snippet; the expiry
    # update only cleans up its own temporary file.
    for command in "${SSH_RUN_CALLS[@]}"; do
        [[ "$command" != *'rm -f "$yaml"'* && "$command" != *'rm -f "$snippet"'* ]] || return 1
    done
    refute_output --partial "$ALPHA_TOKEN"
    refute_output --partial "$BETA_TOKEN"
    [[ "$CMD_ENVELOPE" != *"$ALPHA_TOKEN"* && "$CMD_ENVELOPE" != *"$BETA_TOKEN"* ]] || return 1
}

@test 'migration never deletes old links if local host commit fails' {
    _prepare_safety
    _sub_upload_config() { return 0; }
    jq_w() { return 1; }
    run_cmd sub migrate --node new --yes
    [ "$status" -eq 1 ]
    [ "$(jq_r '.subscription_host.node')" = old ]
    local command
    for command in "${SSH_RUN_CALLS[@]}"; do
        [[ "$command" != *'rm -f "$yaml"'* && "$command" != *'rm -f "$snippet"'* ]] || return 1
    done
}

@test 'migration preserves old data when a published config is blank' {
    _prepare_safety
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/beta/config.yaml"
    local before
    before=$(jq_r '.subscription_host, .clients')
    run_cmd sub migrate --node new --yes
    [ "$status" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test 'migration without --yes and to the current host leave files and metadata intact' {
    _prepare_safety
    local before
    before=$(jq_r '.subscription_host, .clients')
    run_cmd sub migrate --node new
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    run_cmd sub migrate --node old --yes
    [ "$status" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
}

@test 'unreachable subscription host retains host and subscription metadata' {
    _prepare_safety
    SSH_RUN_MOCK_EXIT=255
    local before rc=0
    before=$(jq_r '.subscription_host, .clients')
    _subscription_revoke_silent alpha > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
}

@test 'failed remote revocation retains token expiry and headers' {
    _prepare_safety
    _sub_load_host() { _sub_save_ssh_ctx; node_load_by_name old; SSH_RUN_MOCK_EXIT=1; }
    local before rc=0
    before=$(jq_r '.clients[0].subscription')
    _subscription_revoke_silent alpha > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.clients[0].subscription')" = "$before" ]
}

@test 'rotation without --yes does not upload delete or expose token' {
    _prepare_safety
    local before
    before=$(jq_r '.clients[0].subscription')
    run_cmd sub rotate --client alpha
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(jq_r '.clients[0].subscription')" = "$before" ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    local command
    for command in "${SSH_RUN_CALLS[@]}"; do [[ "$command" != *'rm -f'* ]]; done
    refute_output --partial "$ALPHA_TOKEN"
    [[ "$CMD_ENVELOPE" != *"$ALPHA_TOKEN"* ]] || return 1
}

@test 'revoke without --yes keeps the token and remote untouched' {
    _prepare_safety
    local before
    before=$(jq_r '.clients')
    run_cmd sub revoke --client alpha
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(jq_r '.clients')" = "$before" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test 'publishing and listing conceal tokens in the log while explicit show exposes the link' {
    _prepare_safety
    run_cmd sub list
    [ "$status" -eq 0 ]
    [[ "$output$CMD_ENVELOPE" != *"$ALPHA_TOKEN"* && "$output$CMD_ENVELOPE" != *https://* ]] || return 1
    run_cmd sub publish --client alpha
    [ "$status" -eq 0 ]
    refute_output --partial "$ALPHA_TOKEN"
    refute_output --partial '/sub/'
    run_cmd sub publish-all --yes
    [ "$status" -eq 0 ]
    refute_output --partial "$ALPHA_TOKEN"
    refute_output --partial "$BETA_TOKEN"
    refute_output --partial '/sub/'
    run_cmd sub show --client alpha
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.url')" = "https://old.example/sub/$ALPHA_TOKEN" ]
}

@test 'invalid ttl leaves metadata and remote host untouched' {
    _prepare_safety
    local before
    before=$(jq_r '.clients')
    run_cmd sub publish --client alpha --ttl 1m
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = invalid ]
    [ "$(jq_r '.clients')" = "$before" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
}

@test 'client and group header commands persist valid changes and reject invalid ones' {
    _prepare_safety
    run_cmd sub headers --client alpha --set X-Test=value
    [ "$status" -eq 0 ]
    [ "$(jq_r '.clients[0].subscription.headers | map(select(.name=="X-Test")) | length')" -eq 1 ]
    run_cmd sub headers --client alpha --unset X-Test
    [ "$(jq_r '.clients[0].subscription.headers | map(select(.name=="X-Test")) | length')" -eq 0 ]
    run_cmd sub headers --group MOBILE --set 'Invalid Header=value'
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd sub headers --group MOBILE --set X-Group=value
    [ "$status" -eq 0 ]
    [ "$(jq_r '.groups[] | select(.name=="MOBILE") | .subscription_headers[0].name')" = X-Group ]
    run_cmd sub headers --default --set X-A=b
    [ "$status" -eq 2 ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test 'default headers come from the built-in constant without writing config' {
    _prepare_safety
    jq_w 'del(.subscription_default_headers)'
    local before
    before=$(jq_r '.')
    run_cmd sub headers --default
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '[{"name":"Content-Disposition","value":"attachment; filename=\"config.yaml\""},{"name":"profile-update-interval","value":"24"}]' ]
    [ "$(jq_r '.')" = "$before" ]
    run_cmd sub headers --client alpha
    [ "$(cmd_jq '[.data[] | select(.source=="default")] | length')" -eq 2 ]
    jq_w '.subscription_default_headers = []'
    run_cmd sub headers --default
    [ "$(cmd_jq -c '.data')" = '[]' ]
}

@test 'publishing does not add default headers to config' {
    _prepare_safety
    jq_w 'del(.subscription_default_headers)'
    run_cmd sub publish --client alpha
    [ "$status" -eq 0 ]
    [ "$(jq_r 'has("subscription_default_headers")')" = false ]
}

@test 'failed uploads do not expose token-bearing remote diagnostics' {
    _prepare_safety
    SSH_RUN_MOCK_OUTPUT="nginx failed at /sub/$ALPHA_TOKEN and sub-$ALPHA_TOKEN.conf"
    SSH_RUN_MOCK_EXIT=1
    run _sub_upload_config "$GENERATED_DIR/MOBILE/alpha/config.yaml" "$ALPHA_TOKEN" /custom/host www-data alpha
    assert_failure
    refute_output --partial "$ALPHA_TOKEN"
    run _sub_upload_batch /custom/host www-data "$GENERATED_DIR/MOBILE/alpha/config.yaml" "$ALPHA_TOKEN" alpha
    assert_failure
    refute_output --partial "$ALPHA_TOKEN"
}

@test 'migration without --yes reviews every client and writes nothing' {
    _prepare_safety
    run_cmd sub migrate --node new
    [ "$status" -eq 2 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    local plan
    plan=$(cmd_jq '.error.plan | join("\n")')
    for word in alpha beta old new; do [[ "$plan" == *"$word"* ]] || return 1; done
    [[ "$plan$output" != *"$ALPHA_TOKEN"* && "$plan$output" != *"$BETA_TOKEN"* ]] || return 1
}

@test 'sub host sets the host from the node and reports unreachable hosts' {
    _prepare_safety
    jq_w '.clients |= map(del(.subscription.token))'
    run_cmd sub host --node new
    [ "$status" -eq 0 ]
    [ "$(jq_r '.subscription_host.node')" = new ]
    [ "$(cmd_jq '.data.base_url')" = https://new.example ]
    SSH_RUN_MOCK_EXIT=255
    run_cmd sub host --node old
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ "$(jq_r '.subscription_host.node')" = new ]
}

# ─── Откат ротации, миграции и отзыва подписок ───────────────────────────────


assert_old_usable() {
    cmp "$SUB_DIR/$OLD_TOKEN.yaml" "$BATS_TEST_TMPDIR/expected.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cmp "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/expected.expiry"
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
}

assert_failure_has_no_tokens() {
    assert_failure
    [[ "$output" != *"$OLD_TOKEN"* && "$CMD_ENVELOPE" != *"$OLD_TOKEN"* ]]
    [[ "$output" != *"$NEW_TOKEN"* && "$CMD_ENVELOPE" != *"$NEW_TOKEN"* ]]
}

failed_rotation() {
    run_cmd sub rotate --client phone --yes
    assert_failure_has_no_tokens
    [[ -e "$BATS_TEST_TMPDIR/deleted-before-$FAIL_STAGE" ]]
    assert_old_usable
    [[ ! -e "$SUB_DIR/$NEW_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" ]]
    [[ ! -e "$RUNTIME_DIR/sub-$NEW_TOKEN.conf" ]]
}

@test "rotation restores a partially removed old link before cleaning the replacement" {
    _prepare_rotation
    FAIL_STAGE=rm
    failed_rotation
}

@test "rotation restores expiry after an edit failed after changing the old token" {
    _prepare_rotation
    FAIL_STAGE=expiry
    failed_rotation
}

@test "rotation restores old files and running route after nginx validation fails" {
    _prepare_rotation
    FAIL_STAGE=nginx
    failed_rotation
}

_prepare_migration_mock() {
    export MIGRATION_NEW_DIR="$BATS_TEST_TMPDIR/new-host"
    mkdir -p "$MIGRATION_NEW_DIR"
    jq_w '.nodes=[{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"old",ip:"192.0.2.1",port:22,user:"root",auth:"key"},{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",name:"new",ip:"192.0.2.2",port:22,user:"root",auth:"key"}] | .subscription_host.node="old" | .subscription_host.sub_dir="/stale/cache"'
    _sub_upload_config() { command cp "$1" "$3/$2.yaml"; }
    ssh_run() {
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        [[ "${1:-}" == -- ]] && shift
        if [[ "$*" == 'cat /etc/mihomo/subscription.conf 2>/dev/null' ]]; then
            local dir="$SUB_DIR"
            [[ "$NODE_NAME" == new ]] && dir="$MIGRATION_NEW_DIR"
            printf 'SUB_DIR=%s\nSUB_BASE_URL=https://new.example\nNGINX_GROUP=www-data\n' "$dir"
            return 0
        fi
        if [[ "$NODE_NAME" == new ]]; then
            # Expiry must reach the new host before the host switch.
            [[ "$(jq_r '.subscription_host.node')" == old ]] || return 1
            ( eval "$*" )
            return
        fi
        [[ "$NODE_NAME" == old && "$(jq_r '.subscription_host.node')" == new ]] || return 1
        [[ -s "$MIGRATION_NEW_DIR/$OLD_TOKEN.yaml" ]] || return 1
        ( eval "$*" )
    }
    printf 'stale 1\n%s 1\n' "$OLD_TOKEN" > "$MIGRATION_NEW_DIR/expiry.list"
}

@test "migration removes configured old-host artifacts only after new copies and host commit" {
    _prepare_rotation
    _prepare_migration_mock
    run_cmd sub migrate --node new --yes
    [ "$status" -eq 0 ]
    [[ "$(jq_r '.subscription_host.node')" == new ]]
    [[ "$(jq_r '.clients[0].subscription.token')" == "$OLD_TOKEN" ]]
    [[ -s "$MIGRATION_NEW_DIR/$OLD_TOKEN.yaml" && ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" ]]
    printf 'stale 1\n%s 2000000000\n' "$OLD_TOKEN" > "$BATS_TEST_TMPDIR/new-host.expiry"
    cmp "$MIGRATION_NEW_DIR/expiry.list" "$BATS_TEST_TMPDIR/new-host.expiry"
    printf 'cccc 2100000000\n' > "$BATS_TEST_TMPDIR/old-host.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/old-host.expiry"
}

@test "migration of a subscription without TTL drops the stale new-host expiry entry" {
    _prepare_rotation
    _prepare_migration_mock
    jq_w '.clients[0].subscription.expires_at = null'
    run_cmd sub migrate --node new --yes
    [ "$status" -eq 0 ]
    [[ "$(jq_r '.subscription_host.node')" == new ]]
    [[ -s "$MIGRATION_NEW_DIR/$OLD_TOKEN.yaml" ]]
    printf 'stale 1\n' > "$BATS_TEST_TMPDIR/new-host.expiry"
    cmp "$MIGRATION_NEW_DIR/expiry.list" "$BATS_TEST_TMPDIR/new-host.expiry"
}

@test "failed expiry replacement keeps the new-host list and aborts before uploads" {
    _prepare_rotation
    _prepare_migration_mock
    cp "$MIGRATION_NEW_DIR/expiry.list" "$BATS_TEST_TMPDIR/new-host.before"
    # Fail only the final replacement of the new host's expiry.list.
    mv() { [[ "${*: -1}" != */expiry.list ]] || return 1; command mv "$@"; }
    export -f mv
    run_cmd sub migrate --node new --yes
    unset -f mv
    [[ "$status" -ne 0 ]]
    [[ "$(jq_r '.subscription_host.node')" == old ]]
    cmp "$MIGRATION_NEW_DIR/expiry.list" "$BATS_TEST_TMPDIR/new-host.before"
    [[ ! -e "$MIGRATION_NEW_DIR/$OLD_TOKEN.yaml" ]]
    ! compgen -G "$MIGRATION_NEW_DIR/expiry.list.migrate.*" || return 1
    [[ -s "$SUB_DIR/$OLD_TOKEN.yaml" ]]
}

@test "rotation restores the old link after a reload failed after applying new routes" {
    _prepare_rotation
    FAIL_STAGE=reload
    failed_rotation
}

@test "successful rotation removes old artifacts and retains the usable new link and expiry" {
    _prepare_rotation
    run_cmd sub rotate --client phone --yes
    assert_success
    [[ ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" ]]
    [[ ! -e "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" ]]
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
    printf '%s 2000000000\ncccc 2100000000\n' "$NEW_TOKEN" > "$BATS_TEST_TMPDIR/new.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/new.expiry"
    [[ "$(jq_r '.clients[0].subscription.token')" == "$NEW_TOKEN" ]]
    [[ "$(jq_r '.clients[0].subscription.headers[0].value')" == phone ]]
}

failed_recovery() {
    FAIL_STAGE=expiry
    run_cmd sub rotate --client phone --yes
    assert_failure_has_no_tokens
    [[ -e "$BATS_TEST_TMPDIR/deleted-before-expiry" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
    local backups=("$SUB_DIR"/.subscription-remove.*)
    [[ -d "${backups[0]}" ]]
    cmp "${backups[0]}/yaml" "$BATS_TEST_TMPDIR/expected.yaml"
    cmp "${backups[0]}/expiry" "$BATS_TEST_TMPDIR/expected.expiry"
    cmp "${backups[0]}/snippet" "$BATS_TEST_TMPDIR/expected.conf"
    local permissions
    permissions=$(stat -c '%a' "${backups[0]}" 2>/dev/null || stat -f '%Lp' "${backups[0]}")
    [[ "$permissions" == 700 ]]
}

@test "failed restoration of old files retains the replacement and private backups" {
    _prepare_rotation
    RECOVERY_FAIL=files
    failed_recovery
    [[ ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
}

@test "failed restoration of expiry retains the replacement and local old metadata" {
    _prepare_rotation
    RECOVERY_FAIL=expiry
    failed_recovery
    printf '%s 2000000000\ncccc 2100000000\n' "$NEW_TOKEN" > "$BATS_TEST_TMPDIR/new.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/new.expiry"
}

@test "failed rollback nginx validation does not clean a live replacement" {
    _prepare_rotation
    RECOVERY_FAIL=nginx
    failed_recovery
}

@test "failed rollback reload does not clean a live replacement" {
    _prepare_rotation
    RECOVERY_FAIL=reload
    failed_recovery
}

@test "uncertain SSH completion preserves the replacement and never prints diagnostics" {
    _prepare_rotation
    # Upload succeeds; lose transport only for removal to model an ambiguous result.
    _original_upload=$(declare -f _sub_upload_config)
    eval "${_original_upload/_sub_upload_config/_rotation_upload}"
    _sub_upload_config() {
        _rotation_upload "$@" || return 1
        TRANSPORT_LOSS=true
    }
    run_cmd sub rotate --client phone --yes
    assert_failure_has_no_tokens
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
}

@test "rotation never cleans the replacement when the old link was already missing" {
    _prepare_rotation
    command rm -f "$SUB_DIR/$OLD_TOKEN.yaml"
    FAIL_STAGE=expiry
    run_cmd sub rotate --client phone --yes
    assert_failure_has_no_tokens
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
}

@test "revoke preserves metadata and usable old artifacts on each post-deletion failure" {
    _prepare_rotation
    local stage
    for stage in rm expiry nginx reload; do
        FAIL_STAGE="$stage"
        command rm -f "$BATS_TEST_TMPDIR/fault-used"
        run _subscription_revoke_silent phone
        assert_failure_has_no_tokens
        [[ -e "$BATS_TEST_TMPDIR/deleted-before-$stage" ]]
        assert_old_usable
    done
}

@test "migration-style cleanup preserves both hosts' copies when old removal fails" {
    _prepare_rotation
    # Migration has already committed the new host; cleanup must not erase its copy
    # or local metadata when restoring an unsuccessful removal on the old host.
    mkdir -p "$BATS_TEST_TMPDIR/new-host"
    command cp "$SUB_DIR/$OLD_TOKEN.yaml" "$BATS_TEST_TMPDIR/new-host/$OLD_TOKEN.yaml"
    jq_w '.subscription_host.node = "new-host"'
    command cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    FAIL_STAGE=reload
    run _sub_remove_token "$OLD_TOKEN" "$SUB_DIR"
    assert_failure_has_no_tokens
    assert_old_usable
    cmp "$BATS_TEST_TMPDIR/new-host/$OLD_TOKEN.yaml" "$BATS_TEST_TMPDIR/expected.yaml"
}

@test "rollback preserves absence of expiry when a subscription had no expiry file" {
    _prepare_rotation
    command rm -f "$SUB_DIR/expiry.list"
    FAIL_STAGE=reload
    run_cmd sub rotate --client phone --yes
    assert_failure_has_no_tokens
    [[ -e "$BATS_TEST_TMPDIR/deleted-before-reload" ]]
    cmp "$SUB_DIR/$OLD_TOKEN.yaml" "$BATS_TEST_TMPDIR/expected.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cmp "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    [[ ! -e "$SUB_DIR/expiry.list" ]]
    [[ ! -e "$SUB_DIR/$NEW_TOKEN.yaml" ]]
}

@test "successful revoke removes only the old link and its expiry and retains headers" {
    _prepare_rotation
    command cp "$SUB_DIR/$OLD_TOKEN.yaml" "$SUB_DIR/$NEW_TOKEN.yaml"
    printf 'location = /sub/%s { alias %s/%s.yaml; }\n' "$NEW_TOKEN" "$SUB_DIR" "$NEW_TOKEN" > "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf"
    run _subscription_revoke_silent phone
    assert_success
    [[ ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" ]]
    [[ ! -e "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" ]]
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$BATS_TEST_TMPDIR/expected.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
    printf 'cccc 2100000000\n' > "$BATS_TEST_TMPDIR/remaining.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/remaining.expiry"
    [[ -z "$(jq_r '.clients[0].subscription.token // empty')" ]]
    [[ "$(jq_r '.clients[0].subscription.headers[0].value')" == phone ]]
}

@test "legacy revoke removes the live link without attempting default headers writes" {
    _prepare_rotation
    jq_w 'del(.subscription_default_headers)'
    jq 'del(.clients[0].subscription.token, .clients[0].subscription.expires_at, .clients[0].subscription.created_at)' "$CONFIG_JSON" > "$BATS_TEST_TMPDIR/revoked.json"
    REAL_MV=$(type -P mv)
    mv() {
        if [[ "$1" == "$CONFIG_JSON".tmp.* && "$2" == "$CONFIG_JSON" ]] &&
            jq -e 'has("subscription_default_headers")' "$1" >/dev/null; then
            touch "$BATS_TEST_TMPDIR/default-promotion"
            return 77
        fi
        "$REAL_MV" "$@"
    }
    NODE_ID=prior NODE_NAME=prior NODE_IDENTITY=identity NODE_TAG=tag
    SERVER_IP=192.0.2.99 SERVER_PORT=2222 SERVER_USER=user
    SERVER_PASS=password SERVER_AUTH=password
    local context
    context=$(declare -p NODE_ID NODE_NAME NODE_IDENTITY NODE_TAG SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH)
    run_cmd sub revoke --client phone --yes
    [ "$(declare -p NODE_ID NODE_NAME NODE_IDENTITY NODE_TAG SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH)" = "$context" ]
    [[ ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" ]]
    [[ ! -e "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" ]]
    printf 'cccc 2100000000\n' > "$BATS_TEST_TMPDIR/remaining.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/remaining.expiry"
    diff <(jq -S . "$CONFIG_JSON") <(jq -S . "$BATS_TEST_TMPDIR/revoked.json")
    [[ ! -e "$BATS_TEST_TMPDIR/default-promotion" ]]
    [ "$status" -eq 0 ]
    [[ "$output" != *"$OLD_TOKEN"* && "$output" != *"$NEW_TOKEN"* ]]
    unset -f mv
}

@test "legacy revoke restores the live link and metadata after an ambiguous reload failure" {
    _prepare_rotation
    jq_w 'del(.subscription_default_headers)'
    command cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    FAIL_STAGE=reload
    run_cmd sub revoke --client phone --yes
    assert_failure_has_no_tokens
    [[ -e "$BATS_TEST_TMPDIR/deleted-before-reload" ]]
    assert_old_usable
}

@test "sub migrate with no published subscriptions keeps host and reports no work" {
    _prepare_safety
    jq_w '.clients |= map(del(.subscription.token))'
    local before
    before=$(jq_r '.subscription_host')
    run_cmd sub migrate --node new
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.migrated')" -eq 0 ]
    [ "$(jq_r '.subscription_host')" = "$before" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [[ "$output" == *'хост не изменён'* ]]
}
