#!/usr/bin/env bats
# Tests for _fetch_proxies_for_client() — proxy extraction with cache + connection priority
#
# These tests run in isolated subshells to avoid global state leakage.
# Uses grep instead of glob patterns to avoid CRLF issues.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    # Must override AFTER sourcing nodes.sh
    _pass_key() { echo "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"; }
    load_fixture_config

    # Re-encode password with deterministic key
    local encoded
    encoded=$(node_pass_encode "testpass123")
    jq_w --arg p "$encoded" '.nodes[1].pass = $p'
}

teardown() {
    teardown_test_env
}

# Helper: runs _fetch_proxies_for_client in a clean subprocess
fetch_proxies_isolated() {
    local client="$1" group="$2" nodes="$3"
    local cache_nodes="${4:-}"
    local stderr_file="$BATS_TEST_TMPDIR/fetch_stderr"

    bash -c "
        source '$PROJECT_ROOT/common/common.sh'
        error() { echo \"\$*\" >&2; return 1; }
        export CONFIG_JSON='$CONFIG_JSON'
        export SCRIPT_DIR='$BATS_TEST_TMPDIR'
        export TEMPLATES_DIR='$TEMPLATES_DIR'
        source '$PROJECT_ROOT/remote-control/modules/nodes.sh'
        _pass_key() { echo 'aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee'; }
        ssh_run() { return 1; }
        scp_run() { return 0; }
        upload_scripts() { return 0; }
        SSHPASS_AVAILABLE=false
        source '$PROJECT_ROOT/remote-control/modules/templates.sh'
        source '$PROJECT_ROOT/remote-control/modules/connections.sh'
        source '$PROJECT_ROOT/remote-control/modules/generate.sh'

        _reset_node_cache
        IFS=',' read -ra _cache_arr <<< '$cache_nodes'
        for n in \"\${_cache_arr[@]}\"; do
            [[ -n \"\$n\" ]] && NODE_CONFIG_CACHE[\"\$n\"]=\"\$(cat '$FIXTURES_DIR/sample_client_config.txt')\"
        done

        _fetch_proxies_for_client '$client' '$group' '$nodes'
    " 2>"$stderr_file" | tr -d '\r'
    local exit_code=${PIPESTATUS[0]}

    # Fail if stderr contains unexpected errors (syntax errors, source failures)
    if [[ -s "$stderr_file" ]]; then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        # Filter out expected warnings (info/warn messages from the code)
        local unexpected
        unexpected=$(echo "$stderr_content" | grep -v '\[!\]\|\[\*\]\|✗\|✓' || true)
        if [[ -n "$unexpected" ]]; then
            echo "UNEXPECTED STDERR: $unexpected" >&2
            return 1
        fi
    fi
    return "$exit_code"
}

@test "fetch_proxies: group connections — returns allowed proxies" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps" "de-vps")
    echo "$result" | grep -q 'name: "vless-reality"'
    echo "$result" | grep -q 'name: "hy2-main"'
}

@test "fetch_proxies: client connections take priority over group" {
    local result
    result=$(fetch_proxies_isolated "my-pc" "PC" "de-vps" "de-vps")
    echo "$result" | grep -q 'name: "vless-reality"'
    ! echo "$result" | grep -q 'name: "hy2-main"'
}

@test "fetch_proxies: node in FAILED — returns empty" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps" "") || true
    [[ -z "$result" ]]
}

@test "fetch_proxies: alias replacement applied" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "ru-vps" "ru-vps")
    echo "$result" | grep -q 'RU-VLESS'
    ! echo "$result" | grep -q 'name: "vless-reality"'
}

@test "fetch_proxies: multiple nodes — proxies from all" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps,ru-vps" "de-vps,ru-vps")
    echo "$result" | grep -q 'name: "vless-reality"'
    echo "$result" | grep -q 'name: "hy2-main"'
    echo "$result" | grep -q 'RU-VLESS'
}

@test "fetch_proxies: proxy block contains full proxy data" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps" "de-vps")
    echo "$result" | grep -q 'type: vless'
    echo "$result" | grep -q 'server: 1.2.3.4'
}

@test "fetch_proxies: nonexistent node — skipped" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "nonexistent" "") || true
    [[ -z "$result" ]]
}

@test "fetch_proxies: per-client VLESS uuid substituted" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps" "de-vps")
    # my-router has vless_uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    echo "$result" | grep -q 'uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    # Original uuid from client-config.txt should NOT be present
    ! echo "$result" | grep -q 'uuid: "test-uuid-1234"'
}

@test "fetch_proxies: per-client HY2 password substituted" {
    local result
    result=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps" "de-vps")
    # my-router has hy2_password: router-hy2-pass-0001
    echo "$result" | grep -q 'password: router-hy2-pass-0001'
    # Original password from client-config.txt should NOT be present
    ! echo "$result" | grep -q 'password: "testpass"'
}

@test "fetch_proxies: different clients get different credentials" {
    local result_router result_pc
    result_router=$(fetch_proxies_isolated "my-router" "ROUTER" "de-vps" "de-vps")
    result_pc=$(fetch_proxies_isolated "my-pc" "PC" "de-vps" "de-vps")
    # my-router gets its uuid
    echo "$result_router" | grep -q 'uuid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    # my-pc gets its uuid
    echo "$result_pc" | grep -q 'uuid: 11111111-2222-3333-4444-555555555555'
}
