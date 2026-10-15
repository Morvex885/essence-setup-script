#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'ssh.sh'
    source_module 'telegram-proxy.sh'
    REMOTE_DIR='/root/essence-setup'
    NODE_NAME=fixture SERVER_IP=192.0.2.1 SERVER_PORT=22 SERVER_USER=root SERVER_AUTH=key SERVER_PASS=
    SETUP_DIR="$PROJECT_ROOT/setup-essence"
    COMMON_DIR="$PROJECT_ROOT/common"
    VERSION_PATH="$PROJECT_ROOT/VERSION"
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=$(cat "$VERSION_PATH"); }
    node_load() {
        NODE_NAME="node-$1" SERVER_IP="192.0.2.$1" SERVER_PORT=22 SERVER_USER=root SERVER_AUTH=key SERVER_PASS=
    }
    _telegram_proxy_external_probe() { TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=NOT_PRESENT; return 0; }
    _telegram_proxy_mtproto_probe() { return 0; }
}
teardown() { teardown_test_env; }

status_batch() {
    local component="$1" action="$2" force="$3"
    shift 3
    _telegram_proxy_remote_preflight "$@" >/dev/null || return
    telegram_proxy_remote_batch "$component" "$action" "$force"
}

@test "status protocol requires one consistent object and boolean flags" {
    local invalid
    for invalid in '' 'log {"installed":false}' '{"installed":false}{"installed":false}' \
        '{"installed":"false","web_enabled":false,"mtproto_enabled":false}' \
        '{"installed":false,"web_enabled":true,"mtproto_enabled":false}'; do
        ! _telegram_proxy_status_object "$invalid" >/dev/null 2>&1 || \
            ! _telegram_proxy_status_result "$(_telegram_proxy_status_object "$invalid")" 3
    done
    ! _telegram_proxy_status_result '{"installed":true,"web_enabled":false,"mtproto_enabled":false}' 0
    ! _telegram_proxy_status_result '{"installed":false,"web_enabled":false,"mtproto_enabled":false}' 0
    ! _telegram_proxy_status_result '{"installed":false,"web_enabled":false,"mtproto_enabled":true}' 3
}

@test "absent installation returns code three and never probes endpoints" {
    _telegram_proxy_external_probe() { printf web >> "$BATS_TEST_TMPDIR/probes"; return 1; }
    _telegram_proxy_mtproto_probe() { printf mt >> "$BATS_TEST_TMPDIR/probes"; return 1; }
    _telegram_proxy_status_result '{"installed":false,"web_enabled":false,"mtproto_enabled":false}' 3
    [[ "$TELEGRAM_PROXY_STATUS_RESULT" == 3\|* ]]
    [ ! -e "$BATS_TEST_TMPDIR/probes" ]
}

@test "inactive backend outranks successful external probe" {
    local json='{"installed":true,"web_enabled":true,"mtproto_enabled":false,"backend":"inactive","firewall":"active","timer":"active","relay":"active","health":"ok","readiness":"ok","web_hostname":"web.example.com"}'
    _telegram_proxy_mtproto_probe() { printf 'unexpected direct probe\n' > "$BATS_TEST_TMPDIR/direct-probe"; return 1; }
    _telegram_proxy_status_result "$json" 0
    [[ "$TELEGRAM_PROXY_STATUS_RESULT" == 4\|* ]]
    [ ! -e "$BATS_TEST_TMPDIR/direct-probe" ]
}

@test "missing observations stay unverified; IPv6 refusal and MTProto listener fail degrade" {
    local json='{"installed":true,"web_enabled":true,"mtproto_enabled":true,"web_hostname":"web.example.com","mtproto_ipv4":"203.0.113.4","mtproto_listener":false,"mtproto_ip_state":"changed"}'
    _telegram_proxy_external_probe() { TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=FAILED; return 1; }
    _telegram_proxy_status_result "$json" 0
    [[ "$TELEGRAM_PROXY_STATUS_RESULT" == 4\|* ]]
    _telegram_proxy_external_probe() { TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=UNVERIFIED; return 2; }
    _telegram_proxy_status_result '{"installed":true,"web_enabled":true,"mtproto_enabled":false,"web_hostname":"web.example.com"}' 0
    [[ "$TELEGRAM_PROXY_STATUS_RESULT" == 0\|* ]]
}

@test "untrusted health fields cannot become display text or commands" {
    local marker="$BATS_TEST_TMPDIR/health-injection"
    local json
    json=$(jq -nc --arg health "\$(touch '$marker')" \
        '{installed:true,web_enabled:true,mtproto_enabled:false,web_hostname:"web.example.com",backend:"active",firewall:"active",timer:"active",relay:"active",health:$health,readiness:"ok"}')
    _telegram_proxy_status_result "$json" 0
    [[ "$TELEGRAM_PROXY_STATUS_RESULT" == 0\|* ]]
    [[ "$TELEGRAM_PROXY_STATUS_SUMMARY" != *'touch'* ]]
    [ ! -e "$marker" ]
}

@test "mixed status batch prioritizes failed over degraded over absent" {
    ssh_run() {
        case "$SERVER_IP" in
            192.0.2.1) printf '%s\n' '{"installed":false,"web_enabled":false,"mtproto_enabled":false}'; return 3 ;;
            192.0.2.2) printf '%s\n' '{"installed":true,"web_enabled":false,"mtproto_enabled":true,"backend":"inactive","mtproto_ipv4":"203.0.113.4"}'; return 0 ;;
            *) printf '%s\n' 'not json'; return 0 ;;
        esac
    }
    run status_batch shared status false 1
    [ "$status" -eq 3 ]
    run status_batch shared status false 1 2
    [ "$status" -eq 4 ]
    run status_batch shared status false 1 2 3
    [ "$status" -eq 1 ]
}

@test "rc three without installed=false JSON and rc zero with invalid flags fail" {
    ssh_run() { return 3; }
    run status_batch shared status false 1
    [ "$status" -eq 1 ]
    ssh_run() { printf '%s\n' '{"installed":true,"web_enabled":"true","mtproto_enabled":false}'; }
    run status_batch shared status false 1
    [ "$status" -eq 1 ]
}

@test "missing openssl makes successful HTTPS incomplete, failed curl has priority" {
    source_module 'telegram-proxy.sh'
    curl() { return "${CURL_RC:-0}"; }
    getent() { return 1; }
    local old_path="$PATH" rc=0
    PATH="$BATS_TEST_TMPDIR"
    _telegram_proxy_external_probe example.com || rc=$?
    [ "$rc" -eq 2 ]
    CURL_RC=7
    rc=0
    _telegram_proxy_external_probe example.com || rc=$?
    [ "$rc" -eq 1 ]
    PATH="$old_path"
}
