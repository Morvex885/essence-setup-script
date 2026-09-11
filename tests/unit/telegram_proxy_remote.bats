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
    NODE_NAME='node-1'; SERVER_IP='127.0.0.1'; SERVER_PORT=22
    SERVER_USER='root'; SERVER_AUTH='key'; SERVER_PASS=''
    reset_ssh_mocks
    node_load() {
        NODE_NAME='node-1'; SERVER_IP='127.0.0.1'; SERVER_PORT=22
        SERVER_USER='root'; SERVER_AUTH='key'; SERVER_PASS=''
        return 0
    }
    cat > "$CONFIG_JSON" <<'EOF'
{"nodes":[{"name":"node-1","ip":"127.0.0.1","port":22,"user":"root","auth":"key"}],"groups":[],"clients":[],"connections":[]}
EOF
}

teardown() { teardown_test_env; }

@test "version match does not upload" {
    SSH_RUN_MOCK_OUTPUT='1.2.3'
    run ensure_remote_scripts_current
    [ "$status" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 0 ]
}

@test "version mismatch uploads scripts" {
    SSH_RUN_MOCK_OUTPUT='old'
    ensure_remote_scripts_current
    [ "$?" -eq 0 ]
    [ "${#UPLOAD_CALLS[@]}" -eq 1 ]
}

@test "single action uses nested server CLI and default scoped timeout" {
    SSH_RUN_MOCK_OUTPUT='1.2.3'
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
    SSH_RUN_MOCK_OUTPUT='1.2.3'
    ssh_run() {
        local args="$*"
        SSH_RUN_CALLS+=("$args")
        if [[ "$args" == *"VERSION"* ]]; then
            echo '1.2.3'
        else
            [ "${SSH_RUN_TIMEOUT:-}" = 120 ]
        fi
        return 0
    }
    telegram_proxy_remote_single web restart false >/dev/null
}

@test "missing remote version uploads scripts" {
    ssh_run() {
        local args="$*"
        SSH_RUN_CALLS+=("$args")
        [[ "$args" == *"VERSION"* ]] && echo '__MISSING_VERSION__'
        return 0
    }
    ensure_remote_scripts_current
    [ "${#UPLOAD_CALLS[@]}" -eq 1 ]
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
        local args="$*"
        SSH_RUN_CALLS+=("$args")
        if [[ "$args" == *"cat '/root/essence-setup/VERSION'"* ]]; then
            echo '1.2.3'
            return 0
        fi
        return 3
    }
    run telegram_proxy_remote_batch shared status false 1 1
    [ "$status" -eq 3 ]
    [[ "$output" == *'SKIPPED: не установлен'* ]]
}

@test "shared actions use top-level grammar" {
    SSH_RUN_MOCK_OUTPUT='1.2.3'
    telegram_proxy_remote_single shared tag-show false >/dev/null
    [[ "${SSH_RUN_CALLS[*]}" == *'setup-essence.sh tag show'* ]]
    telegram_proxy_remote_single shared connection false >/dev/null
    [[ "${SSH_RUN_CALLS[*]}" == *'connection'* ]]
}

@test "invalid action rejected" {
    run telegram_proxy_remote_single web unknown
    [ "$status" -ne 0 ]
}

@test "missing remote action arguments return grammar error" {
    run telegram_proxy_remote_single
    [ "$status" -eq 2 ]
}
