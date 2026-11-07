#!/usr/bin/env bats
# Tests for node config cache: _reset_node_cache, _get_node_config, _prefetch_node_configs
#
# Cache tests run in isolated subshells to avoid global state leakage.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    override_pass_key
    load_fixture_config
}

teardown() {
    teardown_test_env
}

# Helper: run cache operations in a clean subprocess
run_cache_test() {
    local script="$1"
    "${BASH:-bash}" -c "
        source '$PROJECT_ROOT/common/common.sh'
        error() { echo \"\$*\" >&2; return 1; }
        export CONFIG_JSON='$CONFIG_JSON'
        export SCRIPT_DIR='$BATS_TEST_TMPDIR'
        export TEMPLATES_DIR='$TEMPLATES_DIR'
        source '$PROJECT_ROOT/remote-control/modules/nodes.sh'
        _pass_key() { echo 'aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee'; }
        SSHPASS_AVAILABLE=false
        source '$PROJECT_ROOT/remote-control/modules/templates.sh'
        source '$PROJECT_ROOT/remote-control/modules/connections.sh'
        # Mock SSH
        SSH_RUN_CALLS=()
        ssh_run() {
            SSH_RUN_CALLS+=(\"\$*\")
            if [[ -n \"\${SSH_MOCK_OUTPUT:-}\" ]]; then echo \"\$SSH_MOCK_OUTPUT\"; fi
            return \"\${SSH_MOCK_EXIT:-0}\"
        }
        scp_run() { return 0; }
        upload_scripts() { return 0; }
        source '$PROJECT_ROOT/remote-control/modules/generate.sh'

        $script
    " 2>/dev/null
}

@test "_reset_node_cache: clears cache and tracking sets" {
    run run_cache_test '
        _node_config_cache_set "test" "data"
        NODE_CONFIG_FAILED+=("bad")
        SCRIPTS_UPLOADED+=("uploaded")
        AWG_PEERS_CHECKED+=("checked")
        _reset_node_cache
        [[ ${#NODE_CONFIG_CACHE_KEYS[@]} -eq 0 ]] || { echo "FAIL: cache keys not empty"; exit 1; }
        [[ ${#NODE_CONFIG_CACHE_VALUES[@]} -eq 0 ]] || { echo "FAIL: cache values not empty"; exit 1; }
        [[ ${#NODE_CONFIG_FAILED[@]} -eq 0 ]] || { echo "FAIL: failed not empty"; exit 1; }
        [[ ${#SCRIPTS_UPLOADED[@]} -eq 0 ]] || { echo "FAIL: uploaded not empty"; exit 1; }
        [[ ${#AWG_PEERS_CHECKED[@]} -eq 0 ]] || { echo "FAIL: checked not empty"; exit 1; }
        echo "OK"
    '
    assert_success
    assert_output "OK"
}

@test "_get_node_config: returns cached config" {
    run run_cache_test '
        _node_config_cache_set "de-vps" "cached content"
        _get_node_config "de-vps"
    '
    assert_success
    assert_output "cached content"
}

@test "_get_node_config: returns 1 for failed node" {
    run run_cache_test '
        NODE_CONFIG_FAILED+=("bad")
        _get_node_config "bad"
    '
    assert_failure
}

@test "_get_node_config: returns 1 for unknown node" {
    run run_cache_test '_get_node_config "unknown"'
    assert_failure
}

@test "_prefetch: populates cache from SSH" {
    run run_cache_test '
        SSH_MOCK_OUTPUT="proxies:
  - name: \"vless-reality\""
        _prefetch_node_configs "de-vps"
        _get_node_config "de-vps"
    '
    assert_success
    assert_output --partial "vless-reality"
}

@test "_prefetch: SSH failure populates FAILED" {
    run run_cache_test '
        SSH_MOCK_EXIT=1
        _prefetch_node_configs "de-vps"
        _get_node_config "de-vps"
    '
    assert_failure
}

@test "_prefetch: skips already cached node" {
    run run_cache_test '
        _node_config_cache_set "de-vps" "already here"
        _get_node_config "de-vps"
    '
    assert_success
    assert_output "already here"
}

@test "_prefetch: skips already failed node" {
    run run_cache_test '
        NODE_CONFIG_FAILED+=("de-vps")
        _prefetch_node_configs "de-vps"
        _get_node_config "de-vps"
    '
    assert_failure
}

@test "_prefetch: unknown node name marks as failed" {
    run run_cache_test '
        _prefetch_node_configs "nonexistent-node"
        _get_node_config "nonexistent-node"
    '
    assert_failure
}

@test "_prefetch: multiple nodes cached" {
    run run_cache_test '
        SSH_MOCK_OUTPUT="test config"
        _prefetch_node_configs "de-vps" "ru-vps"
        printf '%s\n' "${NODE_CONFIG_CACHE_KEYS[@]}"
    '
    assert_success
    assert_output --partial "de-vps"
    assert_output --partial "ru-vps"
}

@test "_node_config_cache_delete: middle removal preserves alignment on append" {
    run run_cache_test '
        _node_config_cache_set "first" "one"
        _node_config_cache_set "middle" "two"
        _node_config_cache_set "last" "three"
        _node_config_cache_delete "middle"
        _node_config_cache_set "appended" "four"
        _get_node_config "first"
        _get_node_config "last"
        _get_node_config "appended"
        [[ "${NODE_CONFIG_CACHE_KEYS[0]}" == "first" ]] || exit 1
        [[ "${NODE_CONFIG_CACHE_VALUES[0]}" == "one" ]] || exit 1
        [[ "${NODE_CONFIG_CACHE_KEYS[2]}" == "last" ]] || exit 1
        [[ "${NODE_CONFIG_CACHE_VALUES[2]}" == "three" ]] || exit 1
        [[ "${NODE_CONFIG_CACHE_KEYS[3]}" == "appended" ]] || exit 1
        [[ "${NODE_CONFIG_CACHE_VALUES[3]}" == "four" ]] || exit 1
    '
    assert_success
    assert_output $'one\nthree\nfour'
}
