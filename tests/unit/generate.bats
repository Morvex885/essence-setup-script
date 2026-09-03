#!/usr/bin/env bats
# Tests for portable client config generation and atomic preservation.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    source_module "groups.sh"
    source_module "templates.sh"
    source_module "connections.sh"
    source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
    source "$PROJECT_ROOT/remote-control/modules/generate.sh"

    load_fixture_config
    load_fixture_template
    jq_w '.nodes[0].tag = "🇩🇪"'

    _reset_node_cache
    _node_config_cache_set "de-vps" "$(load_fixture_client_config)"
    _ensure_all_awg_peers() { :; }
}

teardown() {
    teardown_test_env
}

@test "generate_group: portable proxy insertion survives GNU-only command failures" {
    local shim_dir real_awk real_grep
    shim_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$shim_dir"
    real_awk=$(command -v awk)
    real_grep=$(command -v grep)

    cat > "$shim_dir/awk" <<EOF
#!/bin/bash
previous=""
for arg in "\$@"; do
    if [[ "\$previous" == "-v" && "\$arg" == *\$'\\n'* ]]; then
        echo "awk: multiline -v rejected" >&2
        exit 2
    fi
    previous="\$arg"
done
exec "$real_awk" "\$@"
EOF
    cat > "$shim_dir/grep" <<EOF
#!/bin/bash
if [[ " \$* " == *" -oP "* ]]; then
    echo "grep: invalid option -- P" >&2
    exit 2
fi
exec "$real_grep" "\$@"
EOF
    chmod +x "$shim_dir/awk" "$shim_dir/grep"

    run_generation_with_wrappers() {
        PATH="$1:$PATH" _generate_group PC
    }

    run run_generation_with_wrappers "$shim_dir"
    assert_success
    refute_output --partial "grep:"
    refute_output --partial "awk:"

    local config_file="$GENERATED_DIR/PC/my-pc/config.yaml"
    run grep -q '[^[:space:]]' "$config_file"
    assert_success
    run grep -qF 'name: "🇩🇪 vless-reality"' "$config_file"
    assert_success
    run grep -qF 'type: vless' "$config_file"
    assert_success
    run grep -qF 'server: 1.2.3.4' "$config_file"
    assert_success
    run grep -qF 'port: 443' "$config_file"
    assert_success
    run grep -qF 'uuid: 11111111-2222-3333-4444-555555555555' "$config_file"
    assert_success

    local proxy_line groups_line
    proxy_line=$(grep -nF 'name: "🇩🇪 vless-reality"' "$config_file" | cut -d: -f1)
    groups_line=$(grep -n '^proxy-groups:' "$config_file" | cut -d: -f1)
    [ "$proxy_line" -lt "$groups_line" ]
}

@test "generate_group: render failure preserves an existing config" {
    local config_file="$GENERATED_DIR/PC/my-pc/config.yaml"
    mkdir -p "$(dirname "$config_file")"
    printf 'existing config\n' > "$config_file"

    _render_client_config() {
        return 1
    }

    run _generate_group PC
    assert_success
    assert_output --partial "my-pc — config.yaml не сгенерирован"
    refute_output --partial "my-pc — сгенерирован"
    run cmp -s "$config_file" <(printf 'existing config\n')
    assert_success
}
