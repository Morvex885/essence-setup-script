#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/mock_ssh'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "clients.sh"
    source_module "subscription.sh"
    reset_ssh_mocks

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
        .nodes = [{name:"host",ip:"192.0.2.1",port:"22",user:"root",auth:"key"}] |
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
    sed() {
        if [[ "${1:-}" == -i ]]; then
            # Linux sed -i semantics, also runnable on the macOS development host.
            command sed "$2" "$3" > "$3.edit" || return 1
            command mv "$3.edit" "$3" || return 1
            _rotation_fault expiry && return 1
            return 0
        fi
        command sed "$@"
    }
    cp() {
        if [[ "${1:-}" == -p && "$2" == *'/.subscription-remove.'* && -e "$BATS_TEST_TMPDIR/fault-used" ]]; then
            if [[ "$RECOVERY_FAIL" == files && "$2" == */yaml ]] ||
                [[ "$RECOVERY_FAIL" == expiry && "$2" == */expiry ]]; then
                printf '%s\n' "$OLD_TOKEN $NEW_TOKEN" >&2
                return 1
            fi
        fi
        command cp "$@"
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
    export -f ssh_run scp_run openssl chown flock curl _rotation_fault rm sed cp nginx systemctl
}

teardown() {
    unset -f rm sed cp nginx systemctl ssh_run scp_run openssl chown flock curl _rotation_fault
    teardown_test_env
}

assert_old_usable() {
    cmp "$SUB_DIR/$OLD_TOKEN.yaml" "$BATS_TEST_TMPDIR/expected.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cmp "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" "$BATS_TEST_TMPDIR/expected.conf"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/expected.expiry"
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
}

assert_failure_has_no_tokens() {
    assert_failure
    [[ "$output" != *"$OLD_TOKEN"* ]]
    [[ "$output" != *"$NEW_TOKEN"* ]]
}

failed_rotation() {
    run subscription_rotate phone <<< 'y'
    assert_failure_has_no_tokens
    [[ -e "$BATS_TEST_TMPDIR/deleted-before-$FAIL_STAGE" ]]
    assert_old_usable
    [[ ! -e "$SUB_DIR/$NEW_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" ]]
    [[ ! -e "$RUNTIME_DIR/sub-$NEW_TOKEN.conf" ]]
}

@test "rotation restores a partially removed old link before cleaning the replacement" {
    FAIL_STAGE=rm
    failed_rotation
}

@test "rotation restores expiry after an edit failed after changing the old token" {
    FAIL_STAGE=expiry
    failed_rotation
}

@test "rotation restores old files and running route after nginx validation fails" {
    FAIL_STAGE=nginx
    failed_rotation
}

@test "migration removes configured old-host artifacts only after new copies and host commit" {
    export MIGRATION_NEW_DIR="$BATS_TEST_TMPDIR/new-host"
    mkdir -p "$MIGRATION_NEW_DIR"
    jq_w '.nodes=[{name:"old",ip:"192.0.2.1",port:"22",user:"root",auth:"key"},{name:"new",ip:"192.0.2.2",port:"22",user:"root",auth:"key"}] | .subscription_host.node="old" | .subscription_host.sub_dir="/stale/cache"'
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
        [[ "$NODE_NAME" == old && "$(jq_r '.subscription_host.node')" == new ]] || return 1
        [[ -s "$MIGRATION_NEW_DIR/$OLD_TOKEN.yaml" ]] || return 1
        ( eval "$*" )
    }
    subscription_migrate <<< $'2\ny' > "$BATS_TEST_TMPDIR/migration.output"
    [[ "$(jq_r '.subscription_host.node')" == new ]]
    [[ "$(jq_r '.clients[0].subscription.token')" == "$OLD_TOKEN" ]]
    [[ -s "$MIGRATION_NEW_DIR/$OLD_TOKEN.yaml" && ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" ]]
}

@test "rotation restores the old link after a reload failed after applying new routes" {
    FAIL_STAGE=reload
    failed_rotation
}

@test "successful rotation removes old artifacts and retains the usable new link and expiry" {
    run subscription_rotate phone <<< 'y'
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
    run subscription_rotate phone <<< 'y'
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
    RECOVERY_FAIL=files
    failed_recovery
    [[ ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
}

@test "failed restoration of expiry retains the replacement and local old metadata" {
    RECOVERY_FAIL=expiry
    failed_recovery
    printf '%s 2000000000\ncccc 2100000000\n' "$NEW_TOKEN" > "$BATS_TEST_TMPDIR/new.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/new.expiry"
}

@test "failed rollback nginx validation does not clean a live replacement" {
    RECOVERY_FAIL=nginx
    failed_recovery
}

@test "failed rollback reload does not clean a live replacement" {
    RECOVERY_FAIL=reload
    failed_recovery
}

@test "uncertain SSH completion preserves the replacement and never prints diagnostics" {
    # Upload succeeds; lose transport only for removal to model an ambiguous result.
    _original_upload=$(declare -f _sub_upload_config)
    eval "${_original_upload/_sub_upload_config/_rotation_upload}"
    _sub_upload_config() {
        _rotation_upload "$@" || return 1
        TRANSPORT_LOSS=true
    }
    run subscription_rotate phone <<< 'y'
    assert_failure_has_no_tokens
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
}

@test "rotation never cleans the replacement when the old link was already missing" {
    command rm -f "$SUB_DIR/$OLD_TOKEN.yaml"
    FAIL_STAGE=expiry
    run subscription_rotate phone <<< 'y'
    assert_failure_has_no_tokens
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    cmp "$SUB_DIR/$NEW_TOKEN.yaml" "$GENERATED_DIR/MOBILE/phone/config.yaml"
    cmp "$SUB_SNIPPETS_DIR/sub-$NEW_TOKEN.conf" "$RUNTIME_DIR/sub-$NEW_TOKEN.conf"
}

@test "revoke preserves metadata and usable old artifacts on each post-deletion failure" {
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
    command rm -f "$SUB_DIR/expiry.list"
    FAIL_STAGE=reload
    run subscription_rotate phone <<< 'y'
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
    subscription_revoke phone <<< 'y' > "$BATS_TEST_TMPDIR/revoke.output" 2>&1
    [ "$(declare -p NODE_ID NODE_NAME NODE_IDENTITY NODE_TAG SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH)" = "$context" ]
    [[ ! -e "$SUB_DIR/$OLD_TOKEN.yaml" ]]
    [[ ! -e "$SUB_SNIPPETS_DIR/sub-$OLD_TOKEN.conf" ]]
    [[ ! -e "$RUNTIME_DIR/sub-$OLD_TOKEN.conf" ]]
    printf 'cccc 2100000000\n' > "$BATS_TEST_TMPDIR/remaining.expiry"
    cmp "$SUB_DIR/expiry.list" "$BATS_TEST_TMPDIR/remaining.expiry"
    diff <(jq -S . "$CONFIG_JSON") <(jq -S . "$BATS_TEST_TMPDIR/revoked.json")
    [[ ! -e "$BATS_TEST_TMPDIR/default-promotion" ]]
    run cat "$BATS_TEST_TMPDIR/revoke.output"
    assert_success
    [[ "$output" != *"$OLD_TOKEN"* && "$output" != *"$NEW_TOKEN"* ]]
    unset -f mv
}

@test "legacy revoke restores the live link and metadata after an ambiguous reload failure" {
    jq_w 'del(.subscription_default_headers)'
    command cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/expected.json"
    FAIL_STAGE=reload
    run subscription_revoke phone <<< 'y'
    assert_failure_has_no_tokens
    [[ -e "$BATS_TEST_TMPDIR/deleted-before-reload" ]]
    assert_old_usable
}
