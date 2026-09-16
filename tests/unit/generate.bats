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

_setup_listener_sync_sandbox() {
    export REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
    export REMOTE_CONFIG="$REMOTE_DIR/config.yaml"
    export LISTENER_UPLOAD_LOG="$BATS_TEST_TMPDIR/listener-upload.log"
    export LISTENER_SSH_LOG="$BATS_TEST_TMPDIR/listener-ssh.log"
    export LISTENER_RESTART_LOG="$BATS_TEST_TMPDIR/listener-restart.log"
    export LISTENER_RESTART_SNAPSHOT="$BATS_TEST_TMPDIR/listener-restart.yaml"
    umask 077
    mkdir -p "$REMOTE_DIR/common"
    mkdir -p "$REMOTE_DIR/bin"
    cat > "$REMOTE_DIR/bin/awk" <<'EOF'
#!/bin/bash
if [[ "$1" == "-v" && "$2" == new_users=* ]]; then
    new_users="${2#new_users=}"
    shift 2
    program="$1"
    config="$2"
    NEW_USERS="$new_users" PROGRAM="$program" /usr/bin/perl -e '
        my $program = $ENV{PROGRAM};
        my ($marker) = $program =~ /# --- ([^ ]+) ---/;
        my $start = "# --- $marker ---";
        my $end = "# --- /$marker ---";
        my $new_users = $ENV{NEW_USERS} // "";
        my ($in_block, $skipping) = (0, 0);
        while (<>) {
            chomp;
            $in_block = 1 if $_ eq $start;
            $in_block = 0 if $_ eq $end;
            if ($in_block && /# client-users-start/) {
                print "      # client-users-start\n";
                print "$_\n" for grep { length } split /\n/, $new_users;
                print "      # client-users-end\n";
                $skipping = 1;
                next;
            }
            if ($in_block && $skipping && /# client-users-end/) {
                $skipping = 0;
                next;
            }
            next if $skipping;
            print "$_\n";
        }
    ' "$config"
else
    exec /usr/bin/awk "$@"
fi
EOF
    chmod 700 "$REMOTE_DIR/bin/awk"
    export PATH="$REMOTE_DIR/bin:$PATH"
    sed "s|/etc/mihomo/config.yaml|$REMOTE_CONFIG|g" \
        "$PROJECT_ROOT/common/listener-users.sh" > "$REMOTE_DIR/common/listener-users.sh"
    chmod 700 "$REMOTE_DIR/common/listener-users.sh"
    cat > "$REMOTE_CONFIG" <<'EOF'
# --- vless-tcp ---
  # client-users-start
      - username: old-tcp
        uuid: old-tcp-uuid
        flow: xtls-rprx-vision
      # client-users-end
      # cascade-user: tcp-cascade
      keep-tcp: true
# --- /vless-tcp ---
# --- vless-xhttp ---
  # client-users-start
      - username: old-xhttp
        uuid: old-xhttp-uuid
      # client-users-end
      # cascade-user: xhttp-cascade
      keep-xhttp: true
# --- /vless-xhttp ---
# --- vless-grpc ---
  # client-users-start
      - username: old-grpc
        uuid: old-grpc-uuid
      # client-users-end
      # cascade-user: grpc-cascade
      keep-grpc: true
# --- /vless-grpc ---
# --- hy2 ---
  # client-users-start
      old-hy2: old-hy2-password
      # client-users-end
      # cascade-user: hy2-cascade
      keep-hy2: true
# --- /hy2 ---
EOF
    local remote_config
    remote_config=$(cat <<'EOF'
--- VLESS TCP ---
--- VLESS xHTTP ---
--- VLESS gRPC ---
--- Hysteria2 ---
EOF
    )
    _reset_node_cache
    _node_config_cache_set de-vps "$remote_config"
    : > "$LISTENER_UPLOAD_LOG"
    : > "$LISTENER_SSH_LOG"
    : > "$LISTENER_RESTART_LOG"
    : > "$LISTENER_RESTART_SNAPSHOT"
    LISTENER_RESTART_RC=0

    node_load_by_name() {
        [[ "$1" == de-vps ]] || return 1
        NODE_NAME="$1"
        return 0
    }
    upload_scripts() {
        printf 'upload\n' >> "$LISTENER_UPLOAD_LOG"
        return 0
    }
    systemctl() {
        [[ "$1" == restart && "$2" == mihomo ]] || return 1
        cp "$REMOTE_CONFIG" "$LISTENER_RESTART_SNAPSHOT"
        printf 'restart:%s\n' "$2" >> "$LISTENER_RESTART_LOG"
        return "${LISTENER_RESTART_RC:-0}"
    }
    ssh_run() {
        [[ "$1" == "--" ]] || return 1
        shift
        printf '%s\n' "$1" >> "$LISTENER_SSH_LOG"
        (eval "$1")
    }
}

_listener_block() {
    local marker="$1" config="${2:-$REMOTE_CONFIG}"
    sed -n "/^# --- ${marker} ---$/,/^# --- \\/${marker} ---$/p" "$config"
}

_listener_users_body() {
    local marker="$1" config="${2:-$REMOTE_CONFIG}"
    _listener_block "$marker" "$config" |
        sed -n '/# client-users-start/,/# client-users-end/{ /# client-users-/d; p; }'
}

_invoke_listener_sync_without_pipefail() {
    set +o pipefail
    _sync_node_listeners de-vps
}

@test "_sync_node_listeners: clears all listener users when assignment becomes empty" {
    _setup_listener_sync_sandbox

    run _sync_node_listeners de-vps
    assert_success
    [[ "$(_listener_block vless-tcp)" == *"username: my-router"* ]]
    [[ "$(_listener_block vless-tcp)" == *"username: my-pc"* ]]
    [[ "$(_listener_block vless-tcp)" == *"flow: xtls-rprx-vision"* ]]
    [[ "$(_listener_block vless-xhttp)" == *"username: my-router"* ]]
    [[ "$(_listener_block vless-xhttp)" != *"flow: xtls-rprx-vision"* ]]
    [[ "$(_listener_block hy2)" == *"my-router: router-hy2-pass-0001"* ]]
    [[ "$(_listener_block hy2)" == *"my-pc: pc-hy2-pass-0002"* ]]
    [[ "$(_listener_block vless-tcp)" != *"old-tcp"* ]]

    jq_w '.clients=[]'
    : > "$LISTENER_UPLOAD_LOG"
    : > "$LISTENER_SSH_LOG"
    : > "$LISTENER_RESTART_LOG"
    run _sync_node_listeners de-vps
    assert_success
    for marker in vless-tcp vless-xhttp vless-grpc hy2; do
        [[ -z "$(_listener_users_body "$marker")" ]] || return 1
    done
    [[ "$(_listener_block vless-tcp)" == *"cascade-user: tcp-cascade"* ]]
    [[ "$(_listener_block vless-xhttp)" == *"keep-xhttp: true"* ]]
    [[ "$(_listener_block hy2)" == *"cascade-user: hy2-cascade"* ]]
    [[ "$(wc -l < "$LISTENER_RESTART_LOG")" -eq 1 ]]
    [[ -z "$(_listener_users_body vless-tcp "$LISTENER_RESTART_SNAPSHOT")" ]]
}

@test "_sync_node_listeners: malformed or missing JSON fails before remote changes" {
    local mode
    for mode in malformed missing; do
        _setup_listener_sync_sandbox
        cp "$REMOTE_CONFIG" "$BATS_TEST_TMPDIR/before-$mode.yaml"
        if [[ "$mode" == malformed ]]; then
            printf '{' > "$CONFIG_JSON"
        else
            rm -f "$CONFIG_JSON"
        fi

        run _invoke_listener_sync_without_pipefail
        assert_failure
        run cmp -s "$BATS_TEST_TMPDIR/before-$mode.yaml" "$REMOTE_CONFIG"
        assert_success
        [[ ! -s "$LISTENER_UPLOAD_LOG" ]]
        [[ ! -s "$LISTENER_SSH_LOG" ]]
        [[ ! -s "$LISTENER_RESTART_LOG" ]]
    done
}

@test "_sync_node_listeners: listener sync failure stops before restart" {
    _setup_listener_sync_sandbox
    jq_w '.clients=[]'
    awk '
        !removed && $0 ~ /# client-users-start/ { removed=1; next }
        { print }
    ' "$REMOTE_CONFIG" > "$REMOTE_CONFIG.tmp"
    mv "$REMOTE_CONFIG.tmp" "$REMOTE_CONFIG"
    run _sync_node_listeners de-vps
    assert_failure
    [[ ! -s "$LISTENER_RESTART_LOG" ]]
    [[ "$(_listener_block vless-xhttp)" == *"old-xhttp"* ]]
    [[ "$(_listener_block vless-grpc)" == *"old-grpc"* ]]
    [[ "$(_listener_block hy2)" == *"old-hy2"* ]]
}

@test "_sync_node_listeners: restart failure is returned after users are cleared" {
    _setup_listener_sync_sandbox
    jq_w '.clients=[]'
    LISTENER_RESTART_RC=1

    run _sync_node_listeners de-vps
    assert_failure
    local marker
    for marker in vless-tcp vless-xhttp vless-grpc hy2; do
        [[ -z "$(_listener_users_body "$marker")" ]] || return 1
    done
    [[ "$(wc -l < "$LISTENER_RESTART_LOG")" -eq 1 ]]
}
