#!/usr/bin/env bats
# Tests for node config cache: _reset_node_cache, _get_node_config, _prefetch_node_configs
#
# Cache tests run in isolated subshells to avoid declare -A global leakage.

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
    bash -c "
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

@test "_reset_node_cache: clears both arrays" {
    run run_cache_test '
        NODE_CONFIG_CACHE["test"]="data"
        NODE_CONFIG_FAILED["bad"]=1
        _reset_node_cache
        [[ ${#NODE_CONFIG_CACHE[@]} -eq 0 ]] || { echo "FAIL: cache not empty"; exit 1; }
        [[ ${#NODE_CONFIG_FAILED[@]} -eq 0 ]] || { echo "FAIL: failed not empty"; exit 1; }
        echo "OK"
    '
    assert_success
    assert_output "OK"
}

@test "_get_node_config: returns cached config" {
    run run_cache_test '
        NODE_CONFIG_CACHE["de-vps"]="cached content"
        _get_node_config "de-vps"
    '
    assert_success
    assert_output "cached content"
}

@test "_get_node_config: returns 1 for failed node" {
    run run_cache_test '
        NODE_CONFIG_FAILED["bad"]=1
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
        NODE_CONFIG_CACHE["de-vps"]="already here"
        _prefetch_node_configs "de-vps"
        _get_node_config "de-vps"
    '
    assert_success
    assert_output "already here"
}

@test "_prefetch: skips already failed node" {
    run run_cache_test '
        NODE_CONFIG_FAILED["de-vps"]=1
        SSH_MOCK_OUTPUT="should not see this"
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
        echo "$(echo "${!NODE_CONFIG_CACHE[*]}" | tr " " "\n" | sort | tr "\n" " ")"
    '
    assert_success
    assert_output --partial "de-vps"
    assert_output --partial "ru-vps"
}
