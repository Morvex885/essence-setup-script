#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/mock_ssh'
    setup_test_env
    source_common
    source_module 'telegram-proxy.sh'
    CURRENT_VERSION='1.2.3'
    REMOTE_DIR='/root/essence-setup'
    TELEGRAM_PROXY_REMOTE_DIR="$REMOTE_DIR"
    SETUP_DIR="$PROJECT_ROOT/setup-essence"
    COMMON_DIR="$PROJECT_ROOT/common"
    VERSION_PATH="$PROJECT_ROOT/VERSION"
    NODE_NAME='node-1'; SERVER_IP='127.0.0.1'; SERVER_PORT=22
    SERVER_USER='root'; SERVER_AUTH='key'; SERVER_PASS=''
    reset_ssh_mocks
    node_load() {
        NODE_NAME='node-1'; SERVER_IP='127.0.0.1'; SERVER_PORT=22
        SERVER_USER='root'; SERVER_AUTH='key'; SERVER_PASS=''
        return 0
    }
    REMOTE_MATCH_RC=0
    _telegram_proxy_remote_scripts_match() {
        SSH_RUN_CALLS+=("checksum")
        return "$REMOTE_MATCH_RC"
    }
    cat > "$CONFIG_JSON" <<'EOF'
{"nodes":[{"name":"node-1","ip":"127.0.0.1","port":22,"user":"root","auth":"key"}],"groups":[],"clients":[],"connections":[]}
EOF
}
@test "matching script manifest does not upload" {
    REMOTE_MATCH_RC=0
    run ensure_remote_scripts_current
    [ "$status" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
}

@test "mismatching script manifest is read-only and blocks action" {
    REMOTE_MATCH_RC=10
    run ensure_remote_scripts_current
    [ "$status" -eq 1 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
}

@test "single action uses nested server CLI and default scoped timeout" {
    REMOTE_MATCH_RC=0
    telegram_proxy_remote_single web restart false >/dev/null
    [ "$?" -eq 0 ]
    [[ "${SSH_RUN_CALLS[*]}" == *'web restart'* ]]
}

@test "force is rejected for restart and status" {
    run telegram_proxy_remote_single web restart true
    [ "$status" -eq 2 ]
    run telegram_proxy_remote_single shared status true
    [ "$status" -eq 2 ]
}

@test "single action applies timeout to SSH operation" {
    REMOTE_MATCH_RC=0
    ssh_run() {
        local args="$*"
        SSH_RUN_CALLS+=("$args")
        [ "${SSH_RUN_TIMEOUT:-}" = 120 ]
    }
    telegram_proxy_remote_single web restart false >/dev/null
}

@test "batch uses source order while reusing four worker slots" {
    local starts="$BATS_TEST_TMPDIR/starts"
    : > "$starts"
    node_load() {
        local index="$1"
        NODE_NAME="node-$index"; SERVER_IP="127.0.0.$index"; SERVER_PORT=22
        SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=''
        printf '%s\n' "$NODE_NAME"
        return 0
    }
    ssh_run() {
        local args="$*"
        if [[ "$args" == *"VERSION"* ]]; then
            echo '1.2.3'
            return 0
        fi
        printf '%s\n' "$NODE_NAME" >> "$starts"
        [[ "$NODE_NAME" == node-1 ]] && sleep 1
        return 0
    }
    run telegram_proxy_remote_batch web restart false 1 2 3 4 5 6
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$starts" | tr -d ' ')" -eq 6 ]
    local first fifth sixth
    first=$(sed -n '1p' "$starts")
    fifth=$(sed -n '5p' "$starts")
    sixth=$(sed -n '6p' "$starts")
    [[ -n "$first" ]]
    [[ "$fifth" = node-* ]]
    [[ "$sixth" = node-* ]]
}

@test "FIFO dispatcher never exceeds four active worker slots" {
    QUEUE_TEST_DIR="$BATS_TEST_TMPDIR/queue"
    mkdir -p "$QUEUE_TEST_DIR"
    printf '0\n0\n' > "$QUEUE_TEST_DIR/active"
    printf '0\n' > "$QUEUE_TEST_DIR/max"
    node_load() {
        local index="$1"
        NODE_NAME="node-$index"; SERVER_IP="127.0.0.$index"; SERVER_PORT=22
        SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=''
    }
    telegram_proxy_remote_single() {
        local n max
        while ! mkdir "$QUEUE_TEST_DIR/lock" 2>/dev/null; do sleep 0.01; done
        n=$(sed -n '1p' "$QUEUE_TEST_DIR/active")
        n=$((n + 1))
        max=$(sed -n '1p' "$QUEUE_TEST_DIR/max")
        (( n > max )) && printf '%s\n' "$n" > "$QUEUE_TEST_DIR/max"
        printf '%s\n' "$n" > "$QUEUE_TEST_DIR/active"
        rmdir "$QUEUE_TEST_DIR/lock"
        sleep 0.15
        while ! mkdir "$QUEUE_TEST_DIR/lock" 2>/dev/null; do sleep 0.01; done
        n=$(sed -n '1p' "$QUEUE_TEST_DIR/active")
        printf '%s\n' "$((n - 1))" > "$QUEUE_TEST_DIR/active"
        rmdir "$QUEUE_TEST_DIR/lock"
        return 0
    }
    telegram_proxy_remote_batch web restart false 1 2 3 4 5 6 7 8 >/dev/null
    [ "$(sed -n '1p' "$QUEUE_TEST_DIR/max")" -le 4 ]
    [ "$(sed -n '1p' "$QUEUE_TEST_DIR/active")" -eq 0 ]
}


@test "node load failure does not consume a worker slot or deadlock queue" {
    local starts="$BATS_TEST_TMPDIR/starts"
    : > "$starts"
    node_load() {
        local index="$1"
        [ "$index" -ne 2 ] || return 1
        NODE_NAME="node-$index"; SERVER_IP="127.0.0.$index"; SERVER_PORT=22
        SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=''
    }
    ssh_run() {
        local args="$*"
        if [[ "$args" == *"VERSION"* ]]; then
            echo '1.2.3'
            return 0
        fi
        printf '%s\n' "$NODE_NAME" >> "$starts"
        return 0
    }
    run telegram_proxy_remote_batch web restart false 1 2 3 4 5
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$starts" | tr -d ' ')" -eq 4 ]
    [[ "$output" == *'#2'* ]]
}

@test "status probes only enabled components and redacts malformed output" {
    local probes="$BATS_TEST_TMPDIR/probes"
    : > "$probes"
    _telegram_proxy_external_probe() {
        printf 'web\n' >> "$probes"
        TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=UNVERIFIED
        return 0
    }
    _telegram_proxy_mtproto_probe() {
        printf 'mtproto\n' >> "$probes"
        return 0
    }
    ssh_run() {
        local args="$*"
        if [[ "$args" == *"VERSION"* ]]; then
            echo '1.2.3'
        else
            printf '%s\n' '{"installed":true,"web_enabled":false,"mtproto_enabled":true,"mtproto_ipv4":"203.0.113.4"}'
        fi
        return 0
    }
    run telegram_proxy_remote_batch shared status false 1
    [ "$status" -eq 0 ]
    [[ "$output" == *'OK'* ]]
    [ "$(cat "$probes")" = mtproto ]

    ssh_run() {
        local args="$*"
        if [[ "$args" == *"VERSION"* ]]; then
            echo '1.2.3'
        else
            printf '%s\n' 'invalid secret=0123456789abcdef0123456789abcdef'
        fi
        return 0
    }
    run telegram_proxy_remote_batch shared status false 1
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAILED'* ]]
    [[ "$output" != *'0123456789abcdef0123456789abcdef'* ]]
}

@test "forced batch action is noninteractive and preserves nested grammar" {
    local calls="$BATS_TEST_TMPDIR/calls"
    : > "$calls"
    ssh_run() {
        local args="$*"
        printf '%s\n' "$args" >> "$calls"
        if [[ "$args" == *"VERSION"* ]]; then
            echo '1.2.3'
        fi
        return 0
    }
    telegram_proxy_remote_batch mtproto install true 1 >/dev/null
    local action_call
    action_call=$(sed -n '/setup-essence.sh mtproto install/p' "$calls")
    [[ "$action_call" == *'mtproto install --force'* ]]
    [[ "$action_call" != *' -t '* ]]
}

@test "batch maps exit three to skipped and continues" {
    ssh_run() {
        SSH_RUN_CALLS+=("$*")
        return 3
    }
    run telegram_proxy_remote_batch shared status false 1 1
    [ "$status" -eq 3 ]
    [[ "$output" == *'SKIPPED: не установлен'* ]]
}


@test "runner preflights, confirms once, uploads only stale node, then acts" {
    load_remote_menu_fixture
    local events="$BATS_TEST_TMPDIR/events"
    : > "$events"
    _telegram_proxy_remote_scripts_match() {
        printf 'probe:%s\n' "${SERVER_IP:-}" >> "$events"
        if [[ "${SERVER_IP:-}" == 192.0.2.1 && "${UPLOADED_NODE:-}" != 1 ]]; then
            return 10
        fi
        return 0
    }
    confirm_yn() {
        printf 'confirm\n' >> "$events"
        return 0
    }
    upload_scripts() {
        printf 'upload:%s\n' "${SERVER_IP:-}" >> "$events"
        UPLOADED_NODE=1
        return 0
    }
    ssh_run() {
        printf 'action:%s\n' "${SERVER_IP:-}" >> "$events"
        return 0
    }
    run _telegram_proxy_remote_run batch web restart false 1 2
    [ "$status" -eq 0 ]
    [ "$(grep -c '^confirm$' "$events")" -eq 1 ]
    [ "$(grep -c '^upload:192.0.2.1$' "$events")" -eq 1 ]
    [ "$(grep -c '^action:' "$events")" -eq 2 ]
    [ "$(sed -n '1p' "$events")" = 'probe:192.0.2.1' ]
    [ "$(sed -n '2p' "$events")" = 'probe:192.0.2.2' ]
}
@test "invalid action rejected" {
    run telegram_proxy_remote_single web unknown
    [ "$status" -ne 0 ]
}

@test "missing remote action arguments return grammar error" {
    run telegram_proxy_remote_single
    [ "$status" -eq 2 ]
}


load_remote_menu_fixture() {
    cat > "$CONFIG_JSON" <<'EOF'
{"schema_version":2,"nodes":[{"id":"11111111111111111111111111111111","name":"Нода один","ip":"192.0.2.1","port":22,"user":"root","auth":"key"},{"id":"22222222222222222222222222222222","name":"Нода два","ip":"192.0.2.2","port":22,"user":"root","auth":"key"}],"groups":[],"clients":[],"connections":[]}
EOF
    source_module 'nodes.sh'
    CURRENT_VERSION='1.2.3'
    TELEGRAM_PROXY_NODE_SCOPED=false
    CURRENT_NODE_INDEX=""
    REMOTE_MENU_JOURNAL="$BATS_TEST_TMPDIR/menu-journal"
    : > "$REMOTE_MENU_JOURNAL"
    ssh_run() {
        local args=()
        while [[ $# -gt 0 && "$1" != "--" ]]; do
            args+=("$1")
            shift
        done
        [[ "$1" == "--" ]] && shift
        local command="$*"
        if [[ "$command" == *VERSION* ]]; then
            printf '%s\n' '1.2.3'
            return 0
        fi
        printf '%s|%s\n' "${NODE_NAME:-}" "$command" >> "$REMOTE_MENU_JOURNAL"
        [[ "$command" == *"status --json"* ]] &&
            printf '%s\n' '{"installed":true,"web_enabled":false,"mtproto_enabled":true,"mtproto_ipv4":"203.0.113.4"}'
        return 0
    }
    _telegram_proxy_remote_scripts_match() { return 0; }
}

invoke_remote_menu() {
    local input="$1" output="$2"
    telegram_proxy_remote_menu < "$input" > "$output"
    local rc=$?
    printf '%s\n' MENU_RETURNED >> "$output"
    return "$rc"
}

@test "Telegram menu: zero and EOF return from active full-module menu" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" menu_output="$BATS_TEST_TMPDIR/output"
    printf '0\n' > "$input"
    run invoke_remote_menu "$input" "$menu_output"
    [ "$status" -eq 0 ]
    [[ "$(cat "$menu_output")" == *MENU_RETURNED* ]]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]

    run invoke_remote_menu /dev/null "$menu_output"
    [ "$status" -eq 0 ]
    [[ "$(cat "$menu_output")" == *MENU_RETURNED* ]]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]
}

@test "Telegram menu: invalid and cancelled component selector do not call remote" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'4\nunknown\n\n0\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [[ "$(cat "$output")" == *MENU_RETURNED* ]]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]
}

@test "Telegram menu: cancelled WEB install does not report operation failure" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'1\nweb\nW\n0\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [[ "$(cat "$output")" == *MENU_RETURNED* ]]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]
}

@test "Telegram menu: cancelled toggle selection clears stale targets" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'5\n1\n0\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]
    [ "${#TELEGRAM_PROXY_SELECTED[@]}" -eq 0 ]
    [ "${#TOGGLE_SELECT_ITEMS[@]}" -eq 0 ]
    [ "${#TOGGLE_SELECT_FLAGS[@]}" -eq 0 ]
}

@test "Telegram menu: scoped node skips pickers for status and connection" {
    load_remote_menu_fixture
    node_load 2
    TELEGRAM_PROXY_NODE_SCOPED=true
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'5\n6\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'status --json' "$REMOTE_MENU_JOURNAL")" -eq 1 ]
    [ "$(grep -c 'connection' "$REMOTE_MENU_JOURNAL")" -eq 1 ]
    [[ "$(cat "$REMOTE_MENU_JOURNAL")" == *'Нода два'* ]]
    [[ "$(cat "$REMOTE_MENU_JOURNAL")" != *'Нода один'* ]]
}

@test "Telegram menu: tag submenu loops after explicit show" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'8\n1\nS\ns\n0\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'tag show' "$REMOTE_MENU_JOURNAL")" -eq 2 ]
    [[ "$(cat "$REMOTE_MENU_JOURNAL")" == *'Нода один'* ]]
}

@test "Telegram menu: remove component is confirmed before remote version upload" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'4\nw\n1\n\nn\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
}

@test "Telegram menu: remove all sends one force after confirmation" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" output="$BATS_TEST_TMPDIR/output"
    local parser="$BATS_TEST_TMPDIR/server-parser.sh"
    local parser_journal="$BATS_TEST_TMPDIR/parser-journal"
    export TPROXY_PARSER_JOURNAL="$parser_journal"
    cat > "$parser" <<EOF
#!/bin/bash
source "$PROJECT_ROOT/common/common.sh"
source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
telegram_proxy_remove_all() {
    printf '%s\n' remove-all >> "\$TPROXY_PARSER_JOURNAL"
    return 0
}
[[ "\${1:-}" == telegram-proxy ]] && shift
telegram_proxy_cli "\$@"
EOF
    chmod 755 "$parser"
    ssh_run() {
        if [[ "${1:-}" == -- && "${2:-}" == if* ]]; then
            printf '%s\n' 1.2.3
            return 0
        fi
        [[ "${1:-}" == -- ]] && shift
        local script="${1:-}"
        shift
        printf '%s|%s %s\n' "${NODE_NAME:-}" "$script" "$*" >> "$REMOTE_MENU_JOURNAL"
        [[ "$script" == "$TELEGRAM_PROXY_REMOTE_DIR/setup-essence.sh" ]] || return 1
        /bin/bash "$parser" "$@"
    }
    printf '%s' $'10\n2\n\ny\n0\n' > "$input"
    run invoke_remote_menu "$input" "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'remove-all' "$REMOTE_MENU_JOURNAL")" -eq 1 ]
    [ "$(cat "$parser_journal")" = remove-all ]
    local command
    command=$(cat "$REMOTE_MENU_JOURNAL")
    [[ "$command" == *'remove-all --force'* ]]
    [[ "$command" != *'--force --force'* ]]
    [[ "$command" == *'Нода два'* ]]
    [[ "$command" != *'Нода один'* ]]
}

@test "Telegram menu: component confirmation displays every selected target" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" menu_output="$BATS_TEST_TMPDIR/output"
    printf '%s' $'4\nm\n1\n2\n\ny\n0\n' > "$input"
    run invoke_remote_menu "$input" "$menu_output"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'mtproto remove' "$REMOTE_MENU_JOURNAL")" -eq 2 ]
    [[ "$(cat "$menu_output")" == *'Нода один'* ]]
    [[ "$(cat "$menu_output")" == *'Нода два'* ]]
    [[ "$(cat "$menu_output")" == *'192.0.2.1:22'* ]]
    [[ "$(cat "$menu_output")" == *'192.0.2.2:22'* ]]
}

@test "Telegram menu: confirmation rejects unknown and invalid targets without reading input" {
    load_remote_menu_fixture
    local input="$BATS_TEST_TMPDIR/input" remaining
    printf 'y\n' > "$input"
    exec 7< "$input"
    _telegram_proxy_remote_confirm_action unknown remove 1 <&7 || true
    _telegram_proxy_remote_confirm_action web remove 1+1 <&7 || true
    _telegram_proxy_remote_confirm_action web remove 3 <&7 || true
    IFS= read -r remaining <&7
    exec 7<&-
    [ "$remaining" = y ]
    [ ! -s "$REMOTE_MENU_JOURNAL" ]
}
@test "runner prevents stale entrypoint action and uploads before install" {
    load_remote_menu_fixture
    local remote_root="$BATS_TEST_TMPDIR/remote-root"
    local old_marker="$BATS_TEST_TMPDIR/old-menu"
    local action_marker="$BATS_TEST_TMPDIR/web-install"
    mkdir -p "$remote_root/modules"
    cp "$PROJECT_ROOT/setup-essence/setup-essence.sh" "$remote_root/setup-essence.sh"
    cp "$PROJECT_ROOT/setup-essence/modules/"*.sh "$remote_root/modules/"
    cp -R "$PROJECT_ROOT/common" "$remote_root/"
    cp "$PROJECT_ROOT/VERSION" "$remote_root/VERSION"
    printf '#!/bin/bash\nprintf OLD_MENU >> "%s"\n' "$old_marker" > "$remote_root/setup-essence.sh"
    chmod 755 "$remote_root/setup-essence.sh"
    TELEGRAM_PROXY_REMOTE_DIR="$remote_root"
    REMOTE_DIR="$remote_root"
    source_module 'ssh.sh'
    unset -f _telegram_proxy_remote_scripts_match
    source "$PROJECT_ROOT/remote-control/modules/telegram-proxy.sh"
    ssh_run() {
        local args=() command check_rc
        while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
        [[ "${1:-}" == "--" ]] && shift
        command="$1"
        shift || true
        if [[ "${args[*]}" == *-n* ]]; then
            /bin/bash -c "$command"
            check_rc=$?
            printf 'checkrc:%s\n' "$check_rc" >> "$action_marker.checks"
            return "$check_rc"
        fi
        if [[ "$command" == mkdir* ]]; then
            mkdir -p "$remote_root/modules"
            return 0
        fi
        if [[ "$command" == chmod* ]]; then
            chmod 755 "$remote_root/setup-essence.sh" "$remote_root/modules/"*.sh
            return 0
        fi
        if [[ "$command" == "$remote_root/setup-essence.sh" ]]; then
            printf '%s\n' "$*" >> "$action_marker"
            return 0
        fi
        return 2
    }
    scp_run() {
        printf 'scp:%s\n' "$*" >> "$action_marker.checks"
        local args=("$@") dest src
        dest="${args[$((${#args[@]} - 1))]}"
        dest="${dest#*:}"
        for src in "${args[@]}"; do
            [[ "$src" == "$dest" || "$src" == -r ]] && continue
            if [[ -d "$src" ]]; then
                cp -R "$src" "$remote_root/"
            elif [[ "$dest" == */ ]]; then
                cp "$src" "$dest"
            else
                cp "$src" "$dest"
            fi
        done
        return 0
    }
    run telegram_proxy_remote_single web install false
    [ "$status" -eq 1 ]
    [ ! -e "$old_marker" ]
    [ ! -e "$action_marker" ]
    confirm_yn() {
        _telegram_proxy_remote_scripts_match() { return 0; }
        return 0
    }
    run _telegram_proxy_remote_run single web install false 1
    [ "$status" -eq 0 ]
    [ ! -e "$old_marker" ]
    [ "$(wc -l < "$action_marker" | tr -d ' ')" -eq 1 ]
}
@test "runner continues on reachable node and preserves unavailable failure" {
    load_remote_menu_fixture
    local probes="$BATS_TEST_TMPDIR/preflight-probes"
    : > "$probes"
    _telegram_proxy_remote_scripts_match() {
        printf '%s\n' "${SERVER_IP:-}" >> "$probes"
        [[ "${SERVER_IP:-}" != 192.0.2.1 ]]
    }
    ssh_run() { return 0; }
    run _telegram_proxy_remote_run batch web restart false 1 2
    [ "$status" -eq 1 ]
    [[ "$output" == *'Нода один'*FAILED* ]]
    [[ "$output" == *'Нода два'*OK* ]]
    [ "$(grep -c '192.0.2.1' "$probes")" -eq 1 ]
}
