#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'nodes.sh'
    source_module 'groups.sh'
    source_module 'templates.sh'
    source_module 'generate.sh'
    source "$PROJECT_ROOT/tests/helpers/mock_ssh.bash"
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
    printf 'proxies:\nproxy-groups: []\n' > "$TEMPLATES_DIR/default.yaml"
    jq_w '.groups=[{name:"PC",template:"default.yaml"},{name:"MOBILE",template:"missing.yaml"}] | .clients=[{name:"bad",group:"PC"},{name:"good",group:"PC"},{name:"skipped",group:"MOBILE"}]'
}

teardown() { teardown_test_env; }

@test "generation continues after write failures and reports each actual client outcome" {
    mkdir -p "$GENERATED_DIR/PC"
    printf 'blocked\n' > "$GENERATED_DIR/PC/bad"
    local rc=0
    generate_all </dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "${GENERATE_CLIENT_FAILED[*]}" = bad ]
    [ "${GENERATE_CLIENT_OK[*]}" = good ]
    [ "${GENERATE_CLIENT_SKIPPED[*]}" = skipped ]
    cmp -s "$GENERATED_DIR/PC/good/config.yaml" "$TEMPLATES_DIR/default.yaml"
    [ ! -f "$GENERATED_DIR/MOBILE/skipped/config.yaml" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
}

@test "a new generation resets old failures while missing templates remain nonfatal skips" {
    GENERATE_CLIENT_FAILED=(old-client)
    GENERATE_NODE_FAILED=(old-node)
    generate_all </dev/null
    [ "${#GENERATE_CLIENT_FAILED[@]}" -eq 0 ]
    [ "${#GENERATE_NODE_FAILED[@]}" -eq 0 ]
    [ "${GENERATE_CLIENT_OK[*]}" = 'bad good' ]
    [ "${GENERATE_CLIENT_SKIPPED[*]}" = skipped ]
}

@test "listener synchronization records every failed node and does not stop at the first" {
    load_fixture_config
    _reset_node_cache
    _generate_reset_results
    _node_config_cache_set de-vps "$(load_fixture_client_config)"
    _node_config_cache_set ru-vps "$(load_fixture_client_config)"
    SSH_RUN_MOCK_EXIT=1
    local rc=0
    _sync_listeners_on_nodes de-vps ru-vps || rc=$?
    [ "$rc" -eq 1 ]
    [ "${GENERATE_NODE_FAILED[*]}" = 'de-vps ru-vps' ]
    [ "${#GENERATE_NODE_OK[@]}" -eq 0 ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 2 ]
    _generate_reset_results
    SSH_RUN_MOCK_EXIT=0
    _sync_listeners_on_nodes de-vps ru-vps
    [ "${GENERATE_NODE_OK[*]}" = 'de-vps ru-vps' ]
    [ "${#GENERATE_NODE_FAILED[@]}" -eq 0 ]
}

@test "render failure records failed client and preserves its previous configuration" {
    mkdir -p "$GENERATED_DIR/PC/bad"
    printf 'previous\n' > "$GENERATED_DIR/PC/bad/config.yaml"
    _render_client_config() { return 1; }
    local rc=0
    _generate_group PC || rc=$?
    [ "$rc" -eq 1 ]
    [ "${GENERATE_CLIENT_FAILED[*]}" = 'bad good' ]
    [ "${#GENERATE_CLIENT_OK[@]}" -eq 0 ]
    cmp -s "$GENERATED_DIR/PC/bad/config.yaml" <(printf 'previous\n')
}

@test "unavailable node makes generation fail without replacing a client's previous config" {
    load_fixture_config
    mkdir -p "$GENERATED_DIR/PC/my-pc"
    printf 'previous\n' > "$GENERATED_DIR/PC/my-pc/config.yaml"
    SSH_RUN_MOCK_EXIT=1
    local rc=0
    generate_all </dev/null || rc=$?
    [ "$rc" -eq 1 ]
    array_contains my-pc "${GENERATE_CLIENT_FAILED[@]}"
    [ "${#GENERATE_CLIENT_OK[@]}" -eq 0 ]
    cmp -s "$GENERATED_DIR/PC/my-pc/config.yaml" <(printf 'previous\n')
}

@test "duplicate connection names skip the client and preserve its old config" {
    load_fixture_config
    jq_w '.nodes[1].aliases = {}'
    mkdir -p "$GENERATED_DIR/ROUTER/my-router"
    printf 'previous\n' > "$GENERATED_DIR/ROUTER/my-router/config.yaml"
    _node_config_cache_set de-vps "$(load_fixture_client_config)"
    _node_config_cache_set ru-vps "$(load_fixture_client_config)"
    AWG_PEERS_CHECKED=(de-vps ru-vps)
    _generate_group ROUTER
    [ "${GENERATE_CLIENT_SKIPPED[*]}" = my-router ]
    [ "${#GENERATE_CLIENT_OK[@]}" -eq 0 ]
    [ "${#GENERATE_CLIENT_FAILED[@]}" -eq 0 ]
    cmp -s "$GENERATED_DIR/ROUTER/my-router/config.yaml" <(printf 'previous\n')
}
