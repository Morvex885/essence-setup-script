#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'nodes.sh'
    source_module 'ssh.sh'
    source_module 'telegram-proxy.sh'
    cat > "$CONFIG_JSON" <<'EOF'
{"nodes":[{"id":"11111111111111111111111111111111","name":"one","ip":"192.0.2.1","port":22,"user":"root","auth":"key","identity":"11111111111111111111111111111111"},{"id":"22222222222222222222222222222222","name":"two","ip":"192.0.2.2","port":22,"user":"root","auth":"key","identity":"22222222222222222222222222222222"}],"groups":[],"clients":[],"connections":[]}
EOF
    export CONFIG_SOURCE=github SSH_IDENTITIES_DIR="$BATS_TEST_TMPDIR/identities" \
        SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/known_hosts" \
        FAKE_SSH_JOURNAL="$BATS_TEST_TMPDIR/ssh-journal"
    mkdir -p "$SSH_IDENTITIES_DIR"
    : > "$SSH_KNOWN_HOSTS"
    : > "$SSH_IDENTITIES_DIR/11111111111111111111111111111111"
    : > "$SSH_IDENTITIES_DIR/22222222222222222222222222222222"
    : > "$FAKE_SSH_JOURNAL"
    _ssh_known_host_present() { return 0; }
    SETUP_DIR="$PROJECT_ROOT/setup-essence"
    COMMON_DIR="$PROJECT_ROOT/common"
    VERSION_PATH="$PROJECT_ROOT/VERSION"
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=$(cat "$VERSION_PATH"); }
    cat > "$BATS_TEST_TMPDIR/ssh" <<'EOF'
#!/bin/bash
identity='' host='' previous=''
for arg in "$@"; do
    [[ "$previous" == -i ]] && identity="$arg"
    [[ "$arg" == root@* ]] && host="${arg#root@}"
    previous="$arg"
done
printf '%s|%s\n' "$host" "$identity" >> "$FAKE_SSH_JOURNAL"
case "$host" in
    192.0.2.1) [[ "$identity" == "$SSH_IDENTITIES_DIR/11111111111111111111111111111111" ]] ;;
    192.0.2.2) [[ "$identity" == "$SSH_IDENTITIES_DIR/22222222222222222222222222222222" ]] ;;
    *) exit 1 ;;
esac
EOF
    run_with_timeout() { shift; "$@"; }
    chmod +x "$BATS_TEST_TMPDIR/ssh"
    export PATH="$BATS_TEST_TMPDIR:$PATH"
}
teardown() { teardown_test_env; }

identity_batch() {
    local component="$1" action="$2" force="$3"
    shift 3
    _telegram_proxy_remote_preflight "$@" >/dev/null || return
    telegram_proxy_remote_batch "$component" "$action" "$force"
}

@test "each GitHub worker uses its own managed identity" {
    run identity_batch web restart false 1 2
    assert_success
    [[ "$(cat "$FAKE_SSH_JOURNAL")" == *'192.0.2.1|'*'11111111111111111111111111111111'* ]]
    [[ "$(cat "$FAKE_SSH_JOURNAL")" == *'192.0.2.2|'*'22222222222222222222222222222222'* ]]
    [ "$(wc -l < "$FAKE_SSH_JOURNAL")" -eq 2 ]
}

@test "one portability issue does not leak into another worker" {
    export STATE_MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$STATE_MANIFEST" <<'EOF'
{"portability":{"issues":[{"node_id":"11111111111111111111111111111111","reason":"missing_host_key"}]}}
EOF
    run identity_batch web restart false 1 2
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$FAKE_SSH_JOURNAL")" -eq 1 ]
    [[ "$(cat "$FAKE_SSH_JOURNAL")" == 192.0.2.2* ]]
}

@test "failed node_load cannot inherit previous node identity" {
    node_load() {
        if [[ "$1" == 2 ]]; then return 1; fi
        NODE_NAME=one NODE_ID=11111111111111111111111111111111
        NODE_IDENTITY=11111111111111111111111111111111
        SERVER_IP=192.0.2.1 SERVER_PORT=22 SERVER_USER=root SERVER_AUTH=key SERVER_PASS=
    }
    run identity_batch web restart false 1 2
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$FAKE_SSH_JOURNAL")" -eq 1 ]
}

@test "malformed private credentials never reach SSH and publish completion" {
    local creds="$BATS_TEST_TMPDIR/credentials" result="$BATS_TEST_TMPDIR/result" output="$BATS_TEST_TMPDIR/output"
    printf 'not-base64\n' > "$creds"
    run _telegram_proxy_fifo_dispatch_job 0 0 web restart false "$result" "$output" "$creds" false fingerprint version
    assert_failure
    [ "$(cat "$result")" -eq 1 ]
    [ -e "$result.done" ]
    [ ! -s "$FAKE_SSH_JOURNAL" ]
}

@test "frozen password preserves trailing newlines through FIFO and real askpass cleanup" {
    export CONFIG_SOURCE=local EXPECTED_PASSWORD="$BATS_TEST_TMPDIR/expected-password"
    printf '%s' $' spaces \tand\nnewlines\n\n' > "$EXPECTED_PASSWORD"
    node_load() {
        NODE_NAME=password-node SERVER_IP=192.0.2.1 SERVER_PORT=2201 SERVER_USER=root
        SERVER_AUTH=password SERVER_PASS=$' spaces \tand\nnewlines\n\n'
        NODE_TAG=tag NODE_ID=node-id NODE_IDENTITY=system
    }
    cat > "$BATS_TEST_TMPDIR/ssh" <<'EOF'
#!/bin/bash
[[ "$SSH_ASKPASS_REQUIRE" == force && -f "$SSH_ASKPASS" ]] || exit 1
received=$(mktemp) || exit 1
"$SSH_ASKPASS" > "$received" || exit 1
cmp "$received" "$EXPECTED_PASSWORD"
rc=$?
rm -f "$received"
printf '%s\n' "$SSH_ASKPASS" >> "$FAKE_SSH_JOURNAL"
exit "$rc"
EOF
    chmod +x "$BATS_TEST_TMPDIR/ssh"
    _telegram_proxy_remote_preflight 1 >/dev/null
    node_load() { return 1; }
    SERVER_AUTH=key SERVER_PASS=wrong
    telegram_proxy_remote_batch web restart false >/dev/null
    [ "$?" -eq 0 ]
    [ "$(wc -l < "$FAKE_SSH_JOURNAL")" -eq 1 ]
    [ ! -e "$(cat "$FAKE_SSH_JOURNAL")" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    [ -z "$TELEGRAM_PROXY_BATCH_DIR" ]
}
