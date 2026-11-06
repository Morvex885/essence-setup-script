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

# Keep editor discovery independent of editors installed on the test host.
_select_test_editor() {
    TEST_TEMPLATE_EDITOR="$1"
    command() {
        if [[ "$1" == -v && ( "$2" == nano || "$2" == vi ) ]]; then
            [[ "$2" == "$TEST_TEMPLATE_EDITOR" ]]
            return $?
        fi
        builtin command "$@"
    }
    nano() {
        printf 'partial editor change\n' >> "$1"
        return 73
    }
    vi() {
        printf 'partial editor change\n' >> "$1"
        return 74
    }
}

@test "template editing rejects failed nano and vi while retaining their partial changes" {
    local editor before
    before=$(jq -S . "$CONFIG_JSON")
    for editor in nano vi; do
        _select_test_editor "$editor"
        printf 'original template\n' > "$TEMPLATES_DIR/default.yaml"
        run edit_template <<< '1'
        [ "$status" -ne 0 ]
        cmp -s "$TEMPLATES_DIR/default.yaml" <(printf 'original template\npartial editor change\n')
        [ "$(jq -S . "$CONFIG_JSON")" = "$before" ]
    done
}

@test "new template editor failures leave partial files without assigning either template to the group" {
    local editor before
    before=$(jq -S . "$CONFIG_JSON")
    for editor in nano vi; do
        _select_test_editor "$editor"
        run _create_new_template PC <<< "failed-$editor"
        [ "$status" -ne 0 ]
        cmp -s "$TEMPLATES_DIR/failed-$editor.yaml" \
            <(cat "$TEMPLATES_DIR/default.yaml"; printf 'partial editor change\n')
        [ "$(jq -S . "$CONFIG_JSON")" = "$before" ]
    done
}

@test "no editor preserves manual editing and permits assigning a newly copied template" {
    _select_test_editor none
    local before
    before=$(jq -S . "$CONFIG_JSON")
    run edit_template <<< $'n\nmanual-edit'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$TEMPLATES_DIR/manual-edit.yaml"* ]]
    cmp -s "$TEMPLATES_DIR/manual-edit.yaml" "$TEMPLATES_DIR/default.yaml"
    [ "$(jq -S . "$CONFIG_JSON")" = "$before" ]

    run _create_new_template PC <<< 'manual-group'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$TEMPLATES_DIR/manual-group.yaml"* ]]
    cmp -s "$TEMPLATES_DIR/manual-group.yaml" "$TEMPLATES_DIR/default.yaml"
    jq -e '.groups[] | select(.name=="PC") | .template=="manual-group.yaml"' "$CONFIG_JSON"
    jq -e '.groups[] | select(.name=="MOBILE") | .template=="missing.yaml"' "$CONFIG_JSON"
}
