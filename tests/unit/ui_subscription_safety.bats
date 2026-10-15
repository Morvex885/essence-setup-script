#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/mock_ssh'
    setup_test_env
    source_common
    source_module 'nodes.sh'
    source_module 'clients.sh'
    source_module 'subscription.sh'
    reset_ssh_mocks
    jq_w '.nodes = [{name:"old",ip:"192.0.2.1",port:"22",user:"root",auth:"key"},{name:"new",ip:"192.0.2.2",port:"2222",user:"root",auth:"key"}] | .clients = [{name:"alpha",group:"MOBILE",subscription:{token:"secret-alpha",expires_at:"2030-01-01T00:00:00Z",created_at:"2026-01-01",headers:[{name:"User-Agent",value:"test"}]}},{name:"beta",group:"MOBILE",subscription:{token:"secret-beta"}}] | .subscription_host = {node:"old",base_url:"https://old.example",sub_dir:"/stale/cache",nginx_group:"www-data"} | .subscription_default_headers = []'
    mkdir -p "$GENERATED_DIR/MOBILE/alpha" "$GENERATED_DIR/MOBILE/beta"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/alpha/config.yaml"
    printf 'proxies: []\n' > "$GENERATED_DIR/MOBILE/beta/config.yaml"
    SSH_RUN_MOCK_OUTPUT=$'SUB_DIR=/custom/host\nSUB_BASE_URL=https://new.example\nNGINX_GROUP=www-data'
    curl() { printf '200'; }
}

teardown() { teardown_test_env; }

@test 'migration rejects malformed indexes and preserves old data after second upload fails' {
    local before
    before=$(jq_r '.subscription_host, .clients')
    _sub_upload_config() { [[ "$5" != beta ]]; }
    local rc=0
    subscription_migrate <<< $'01\n9\n1+1\n2\ny' > "$BATS_TEST_TMPDIR/output" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
    local command
    for command in "${SSH_RUN_CALLS[@]}"; do [[ "$command" != *'rm -f'* ]]; done
    run cat "$BATS_TEST_TMPDIR/output"
    refute_output --partial 'secret-alpha'
    refute_output --partial 'secret-beta'
}

@test 'migration never deletes old links if local host commit fails' {
    _sub_upload_config() { return 0; }
    jq_w() { return 1; }
    local rc=0
    subscription_migrate <<< $'2\ny' > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.subscription_host.node')" = old ]
    local command
    for command in "${SSH_RUN_CALLS[@]}"; do [[ "$command" != *'rm -f'* ]]; done
}


@test 'migration preserves old data when a published config is blank' {
    printf ' \n\t\n' > "$GENERATED_DIR/MOBILE/beta/config.yaml"
    local before rc=0
    before=$(jq_r '.subscription_host, .clients')
    subscription_migrate <<< $'2\ny' > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test 'migration refusal and selecting current host leave files and metadata intact' {
    local before
    before=$(jq_r '.subscription_host, .clients')
    subscription_migrate <<< $'2\n' > /dev/null
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    local rc=0
    subscription_migrate <<< '1' > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
}

@test 'unreachable subscription host retains host and subscription metadata' {
    SSH_RUN_MOCK_EXIT=255
    local before rc=0
    before=$(jq_r '.subscription_host, .clients')
    _subscription_revoke_silent alpha > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.subscription_host, .clients')" = "$before" ]
}

@test 'failed remote revocation retains token expiry and headers' {
    _sub_load_host() { _sub_save_ssh_ctx; node_load_by_name old; SSH_RUN_MOCK_EXIT=1; }
    local before rc=0
    before=$(jq_r '.clients[0].subscription')
    _subscription_revoke_silent alpha > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.clients[0].subscription')" = "$before" ]
}

@test 'refusing token rotation does not upload delete or expose token' {
    local before rc=0
    before=$(jq_r '.clients[0].subscription')
    subscription_rotate alpha <<< '' > "$BATS_TEST_TMPDIR/output" || rc=$?
    [ "$rc" -eq 0 ]
    [ "$(jq_r '.clients[0].subscription')" = "$before" ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    local command
    for command in "${SSH_RUN_CALLS[@]}"; do [[ "$command" != *'rm -f'* ]]; done
    run cat "$BATS_TEST_TMPDIR/output"
    refute_output --partial secret-alpha
}


@test 'status publishing and batch listing conceal tokens while explicit show exposes link' {
    run subscription_list
    assert_success
    refute_output --partial secret-alpha
    refute_output --partial secret-beta
    refute_output --partial https://
    run subscription_publish alpha '' status
    assert_success
    refute_output --partial secret-alpha
    refute_output --partial '/sub/'
    run subscription_publish_all
    assert_success
    refute_output --partial secret-alpha
    refute_output --partial secret-beta
    refute_output --partial '/sub/'
    run subscription_show alpha
    assert_success
    assert_output --partial 'https://old.example/sub/secret-alpha'
}

@test 'invalid publishing mode leaves metadata and remote host untouched' {
    local before rc=0
    before=$(jq_r '.clients')
    subscription_publish alpha '' invalid > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(jq_r '.clients')" = "$before" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
}

@test 'client and group header menus persist after mutation cancellation and errors' {
    state_action() { shift; "$@"; }
    subscription_client_headers_menu <<< $'1\n0\n1\n1\nX-Test\nvalue\n2\n1\nX-Test\n0' > /dev/null
    [ "$(jq_r '.clients[0].subscription.headers | map(select(.name=="X-Test")) | length')" -eq 0 ]
    subscription_group_headers_menu <<< $'1\n1\nInvalid Header\nvalue\n1\n1\nX-Group\nvalue\n0' > /dev/null
    [ "$(jq_r '.groups[0].subscription_headers[0].name')" = X-Group ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test 'subscription selectors clear stale results on cancellation and validate canonical indexes' {
    SUBSCRIPTION_SELECT_RESULT=stale
    local rc=0
    _select_client 'Select' <<< '0' > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$SUBSCRIPTION_SELECT_RESULT" ]
    _select_client_with_sub 'Select' <<< $'01\n1+1\n2\r' > /dev/null
    [ "$SUBSCRIPTION_SELECT_RESULT" = beta ]
    _select_group 'Select' </dev/null > /dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$SUBSCRIPTION_SELECT_RESULT" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}


@test 'failed uploads do not expose token-bearing remote diagnostics' {
    SSH_RUN_MOCK_OUTPUT='nginx failed at /sub/secret-alpha and sub-secret-alpha.conf'
    SSH_RUN_MOCK_EXIT=1
    run _sub_upload_config "$GENERATED_DIR/MOBILE/alpha/config.yaml" secret-alpha /custom/host www-data alpha
    assert_failure
    refute_output --partial secret-alpha
    run _sub_upload_batch /custom/host www-data "$GENERATED_DIR/MOBILE/alpha/config.yaml" secret-alpha alpha
    assert_failure
    refute_output --partial secret-alpha
}

@test 'migration reviews every client and asks once before writes' {
    confirm_yn() { printf 'confirm\n' >> "$BATS_TEST_TMPDIR/confirm"; return 1; }
    subscription_migrate <<< '2' > "$BATS_TEST_TMPDIR/output"
    [ "$(wc -l < "$BATS_TEST_TMPDIR/confirm" | tr -d ' ')" -eq 1 ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    run cat "$BATS_TEST_TMPDIR/output"
    assert_output --partial alpha
    assert_output --partial beta
    assert_output --partial old
    assert_output --partial new
    refute_output --partial secret-alpha
    refute_output --partial secret-beta
}
