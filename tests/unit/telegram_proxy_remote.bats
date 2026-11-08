#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/mock_ssh'
    setup_test_env
    source_common
    source_module 'ssh.sh'
    source "$PROJECT_ROOT/tests/helpers/mock_ssh.bash"
    source_module 'telegram-proxy.sh'
    source_module 'nodes.sh'
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote"
    SETUP_DIR="$BATS_TEST_TMPDIR/bundle/setup-essence"
    COMMON_DIR="$BATS_TEST_TMPDIR/bundle/common"
    VERSION_PATH="$BATS_TEST_TMPDIR/bundle/VERSION"
    mkdir -p "$SETUP_DIR/modules" "$COMMON_DIR/protocols" "$REMOTE_DIR"
    printf '1.2.3\n' > "$VERSION_PATH"
    printf '#!/bin/bash\n' > "$SETUP_DIR/setup-essence.sh"
    printf 'module\n' > "$SETUP_DIR/modules/example.sh"
    printf 'common\n' > "$COMMON_DIR/common.sh"
    printf 'nested\n' > "$COMMON_DIR/protocols/example.sh"
    CURRENT_VERSION=1.2.3
    EVENTS="$BATS_TEST_TMPDIR/events"
    : > "$EVENTS"
    cat > "$CONFIG_JSON" <<'EOF'
{"nodes":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"A","ip":"192.0.2.1","port":22,"user":"root","auth":"key"},{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"B","ip":"192.0.2.2","port":22,"user":"root","auth":"key"},{"id":"cccccccccccccccccccccccccccccccc","name":"C","ip":"192.0.2.3","port":22,"user":"root","auth":"key"}],"groups":[],"clients":[],"connections":[]}
EOF
    reset_ssh_mocks
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.2.3; }
    ssh_run() { printf 'action:%s\n' "$NODE_NAME" >> "$EVENTS"; }
    upload_scripts() { printf 'upload:%s\n' "$NODE_NAME" >> "$EVENTS"; }
    # Сессия меню идёт в текущий stdio вместо /dev/tty.
    _rc_tty_run() { "$@"; }
}
teardown() { teardown_test_env; }

prepared_batch() {
    local component="$1" action="$2" force="$3"
    shift 3
    _telegram_proxy_remote_preflight "$@" >/dev/null || return
    telegram_proxy_remote_batch "$component" "$action" "$force"
}

mixed_probe() {
    printf 'probe:%s\n' "$NODE_NAME" >> "$EVENTS"
    REMOTE_SCRIPTS_STATE=ready
    case "$NODE_NAME" in
        A)
            REMOTE_SCRIPTS_VERSION=1.0.0
            [[ -e "$REMOTE_DIR/A-uploaded" ]] && REMOTE_SCRIPTS_VERSION=1.2.3
            ;;
        B) return 1 ;;
        C) REMOTE_SCRIPTS_VERSION=1.2.3 ;;
    esac
    return 0
}

@test "preflight probes every target before one plan review and refusal has no mutations" {
    _remote_scripts_probe() { mixed_probe; }
    rc_confirm_gate() {
        [ "$(cat "$EVENTS")" = $'probe:A\nprobe:B\nprobe:C' ] || return 2
        local output
        output=$(printf '%s\n' "${CORE_PLAN_LINES[@]}")
        [[ "$output" == *'A  192.0.2.1:22 — будут загружены скрипты v1.2.3'* ]] || return 2
        [[ "$output" == *'B  192.0.2.2:22 — исключена:'* ]] || return 2
        [[ "$output" == *'C  192.0.2.3:22'* ]] || return 2
        [[ "$CORE_PLAN_EXTRA" == *" 1.2.3" ]] || return 2
        printf 'confirm\n' >> "$EVENTS"
        rc_fail confirmation_required ""
    }
    local rc=0
    core_telegram_run mtproto install 1 2 3 >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$RC_ERROR_CODE" = confirmation_required ]
    [ "$(cat "$EVENTS")" = $'probe:A\nprobe:B\nprobe:C\nconfirm' ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
}

@test "approval uploads only old eligible node and executes frozen eligible targets" {
    _remote_scripts_probe() { mixed_probe; }
    rc_confirm_gate() {
        [ "$(cat "$EVENTS")" = $'probe:A\nprobe:B\nprobe:C' ] || return 2
        printf 'confirm\n' >> "$EVENTS"
        # The operation must use the snapshot, not this replacement config.
        jq_w '.nodes=[]' || return 2
    }
    upload_scripts() { touch "$REMOTE_DIR/A-uploaded"; printf 'upload:%s\n' "$NODE_NAME" >> "$EVENTS"; }
    run core_telegram_run mtproto install 1 2 3
    [ "$status" -eq 1 ]
    [ "$(grep -c '^confirm$' "$EVENTS")" -eq 1 ]
    [ "$(grep -c '^upload:A$' "$EVENTS")" -eq 1 ]
    [ "$(grep -c '^action:A$' "$EVENTS")" -eq 1 ]
    [ "$(grep -c '^action:C$' "$EVENTS")" -eq 1 ]
    [ "$(grep -c '^action:B$' "$EVENTS")" -eq 0 ]
    [[ "$output" == *'A — успешно'*'B — ошибка:'*'C — успешно'* ]]
}

@test "local fingerprint mutation after approval blocks uploads and actions without another question" {
    _remote_scripts_probe() { mixed_probe; }
    rc_confirm_gate() { printf 'confirm\n' >> "$EVENTS"; printf 'changed\n' >> "$SETUP_DIR/modules/example.sh"; }
    run core_telegram_run mtproto install 1 2 3
    [ "$status" -eq 1 ]
    [ "$(grep -c '^confirm$' "$EVENTS")" -eq 1 ]
    [ "$(grep -c '^upload:' "$EVENTS")" -eq 0 ]
    [ "$(grep -c '^action:' "$EVENTS")" -eq 0 ]
}

@test "ready and newer backends restart without confirmation or per-worker preparation" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=9.0.0; }
    rc_confirm_gate() { printf 'unexpected-confirm\n' >> "$EVENTS"; return 1; }
    core_telegram_run backend restart 3 1 >/dev/null
    [ "$?" -eq 0 ]
    [ "$(wc -l < "$EVENTS")" -eq 2 ]
    [ "$(grep -c '^action:' "$EVENTS")" -eq 2 ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "all excluded produces failures with no question and cleans frozen credentials" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=broken; REMOTE_SCRIPTS_VERSION=1.2.3; }
    rc_confirm_gate() { printf 'unexpected-confirm\n' >> "$EVENTS"; return 0; }
    local rc=0
    core_telegram_run mtproto install 1 2 3 >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ ! -s "$EVENTS" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "upload requires an exact ready version before action" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.0.0; }
    rc_confirm_gate() { return 0; }
    run core_telegram_run mtproto install 1
    [ "$status" -eq 1 ]
    [ "$(cat "$EVENTS")" = upload:A ]
}

@test "fingerprint is deterministic and covers version entry modules and nested common files" {
    local original changed file
    original=$(_telegram_proxy_remote_bundle_fingerprint)
    [ "$original" = "$(_telegram_proxy_remote_bundle_fingerprint)" ]
    for file in "$VERSION_PATH" "$SETUP_DIR/setup-essence.sh" "$SETUP_DIR/modules/example.sh" "$COMMON_DIR/protocols/example.sh"; do
        printf 'changed\n' >> "$file"
        changed=$(_telegram_proxy_remote_bundle_fingerprint)
        [ "$original" != "$changed" ]
        original="$changed"
    done
    rm "$SETUP_DIR/setup-essence.sh"
    run _telegram_proxy_remote_bundle_fingerprint
    [ "$status" -ne 0 ]
}

@test "fingerprint rejects hash find and sort failures rather than a partial bundle" {
    _telegram_proxy_remote_hash() { return 1; }
    run _telegram_proxy_remote_bundle_fingerprint
    [ "$status" -ne 0 ]
    source_module 'telegram-proxy.sh'
    find() { return 1; }
    run _telegram_proxy_remote_bundle_fingerprint
    [ "$status" -ne 0 ]
    unset -f find
    sort() { return 1; }
    run _telegram_proxy_remote_bundle_fingerprint
    [ "$status" -ne 0 ]
}

@test "invalid requests neither consume input nor keep a previous plan" {
    local input="$BATS_TEST_TMPDIR/input" remaining component idx
    printf 'y\n' > "$input"
    exec 7< "$input"
    for component in web shared backend mtproto; do
        TELEGRAM_PROXY_PLAN_PASS=(sensitive)
        core_telegram_run "$component" unknown 1 <&7 >/dev/null || true
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
        [ "$RC_ERROR_CODE" = usage ]
    done
    for idx in 0 01 1+1 4 ''; do
        core_telegram_run web restart "$idx" <&7 >/dev/null || true
        [ "$RC_ERROR_CODE" = usage ]
    done
    IFS= read -r remaining <&7
    exec 7<&-
    [ "$remaining" = y ]
    [ ! -s "$EVENTS" ]
}

@test "direct batch uses only frozen plan and rejects indices instead of rereading config" {
    _telegram_proxy_remote_preflight 1 3 >/dev/null
    node_load() { printf 'unexpected-load\n' >> "$EVENTS"; return 1; }
    telegram_proxy_remote_batch web restart false >/dev/null
    [ "$?" -eq 0 ]
    [ "$(grep -c '^action:' "$EVENTS")" -eq 2 ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
    TELEGRAM_PROXY_PLAN_PASS=(sensitive)
    run telegram_proxy_remote_batch web restart false 1
    [ "$status" -eq 2 ]
}

@test "refusal without --yes discards the entire plan before workers" {
    local rc
    for rc in 1 2; do
        RC_CONFIRM_YES=0
        core_telegram_run mtproto install 1 2 >/dev/null && return 1
        [ "$RC_ERROR_CODE" = confirmation_required ]
        [ ! -s "$EVENTS" ]
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
    RC_CONFIRM_YES=1 RC_CONFIRM_TOKEN=0000000000000000
    core_telegram_run mtproto install 1 >/dev/null && return 1
    [ "$RC_ERROR_CODE" = plan_changed ]
    [ ! -s "$EVENTS" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "FIFO reuses four slots before slow first job finishes and retains output source order" {
    node_load() { NODE_NAME="node-$1"; SERVER_IP="127.0.0.$1"; SERVER_PORT=22; SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=''; }
    ssh_run() {
        printf 'start:%s\n' "$NODE_NAME" >> "$EVENTS"
        [[ "$NODE_NAME" != node-1 ]] || sleep 2
        printf 'finish:%s\n' "$NODE_NAME" >> "$EVENTS"
    }
    run prepared_batch web restart false 1 2 3 4 5 6
    [ "$status" -eq 0 ]
    [ "$(grep -c '^start:' "$EVENTS")" -eq 6 ]
    [[ "$(cat "$EVENTS")" == *start:node-5*finish:node-1* ]]
    [[ "$output" == *'node-1 —'*'node-2 —'*'node-3 —'*'node-4 —'*'node-5 —'*'node-6 —'* ]]
}

@test "FIFO never exceeds four active workers and releases all slots" {
    local queue="$BATS_TEST_TMPDIR/queue"
    mkdir "$queue"
    printf '0\n' > "$queue/active"
    printf '0\n' > "$queue/max"
    node_load() { NODE_NAME="node-$1"; SERVER_IP="127.0.0.$1"; SERVER_PORT=22; SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=''; }
    ssh_run() {
        local n max
        while ! mkdir "$queue/lock" 2>/dev/null; do sleep 0.01; done
        n=$(cat "$queue/active"); n=$((n + 1)); max=$(cat "$queue/max")
        (( n <= max )) || printf '%s\n' "$n" > "$queue/max"
        printf '%s\n' "$n" > "$queue/active"
        rmdir "$queue/lock"
        sleep 0.25
        while ! mkdir "$queue/lock" 2>/dev/null; do sleep 0.01; done
        n=$(cat "$queue/active"); printf '%s\n' "$((n - 1))" > "$queue/active"
        rmdir "$queue/lock"
    }
    prepared_batch web restart false 1 2 3 4 5 6 7 8 >/dev/null
    [ "$?" -eq 0 ]
    [ "$(cat "$queue/max")" -le 4 ]
    [ "$(cat "$queue/max")" -ge 2 ]
    [ "$(cat "$queue/active")" -eq 0 ]
}

@test "failed node load consumes no worker slot and next job cannot inherit credentials" {
    node_load() {
        [[ "$1" != 2 ]] || return 1
        NODE_NAME="node-$1"; SERVER_IP="127.0.0.$1"; SERVER_PORT=22; SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=''
    }
    run prepared_batch web restart false 1 2 3 4 5
    [ "$status" -eq 1 ]
    [ "$(grep -c '^action:' "$EVENTS")" -eq 4 ]
    [[ "$(cat "$EVENTS")" != *action:node-2* ]]
    [[ "$output" == *'node-1 —'*'#2 —'*'node-3 —'* ]]
}

@test "malformed status fails and credentials are redacted from errors" {
    ssh_run() { printf '%s\n' 'invalid secret=0123456789abcdef0123456789abcdef credential=VERY_PRIVATE token=TOKEN_PRIVATE'; }
    run prepared_batch shared status false 1
    [ "$status" -eq 1 ]
    [[ "$output" != *0123456789abcdef0123456789abcdef* ]]
    ssh_run() { printf '%s\n' 'secret=0123456789abcdef0123456789abcdef credential=VERY_PRIVATE token=TOKEN_PRIVATE'; return 1; }
    run prepared_batch web restart false 1
    [ "$status" -eq 1 ]
    [[ "$output" != *0123456789abcdef0123456789abcdef* && "$output" != *VERY_PRIVATE* && "$output" != *TOKEN_PRIVATE* ]]
}

@test "missing worker result fails and cleans private batch directory before reentry" {
    _telegram_proxy_remote_worker_body() { return 0; }
    SSH_RUN_TIMEOUT=0
    local rc=0
    prepared_batch web restart false 1 >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$TELEGRAM_PROXY_BATCH_DIR" ]
    [ -z "$TELEGRAM_PROXY_BATCH_PIDS" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    source_module 'telegram-proxy.sh'
    prepared_batch web restart false 1 >/dev/null
    [ "$?" -eq 0 ]
    [ "$(cat "$EVENTS")" = action:A ]
}

@test "status probes only enabled endpoints and absent status continues without probes" {
    local probes="$BATS_TEST_TMPDIR/probes"
    _telegram_proxy_external_probe() { printf 'web\n' >> "$probes"; TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=NOT_PRESENT; }
    _telegram_proxy_mtproto_probe() { printf 'mtproto\n' >> "$probes"; }
    ssh_run() { printf '%s\n' '{"installed":true,"web_enabled":false,"mtproto_enabled":true,"mtproto_ipv4":"203.0.113.4"}'; }
    run prepared_batch shared status false 1
    [ "$status" -eq 0 ]
    [ "$(cat "$probes")" = mtproto ]
    rm "$probes"
    ssh_run() { printf '%s\n' '{"installed":false,"web_enabled":false,"mtproto_enabled":false}'; return 3; }
    run prepared_batch shared status false 1 2
    [ "$status" -eq 3 ]
    [ ! -e "$probes" ]
}

@test "status after a noisy successful upload parses only server JSON and runs the enabled probe" {
    _remote_scripts_probe() {
        REMOTE_SCRIPTS_STATE=ready
        REMOTE_SCRIPTS_VERSION=1.0.0
        [[ ! -f "$BATS_TEST_TMPDIR/uploaded" ]] || REMOTE_SCRIPTS_VERSION=1.2.3
    }
    rc_confirm_gate() { return 0; }
    upload_scripts() {
        info "Загружаем скрипты..."
        success "Скрипты загружены"
        touch "$BATS_TEST_TMPDIR/uploaded"
    }
    ssh_run() {
        printf '%s\n' '{"installed":true,"web_enabled":false,"mtproto_enabled":true,"mtproto_ipv4":"8.8.8.8"}'
    }
    _telegram_proxy_mtproto_probe() { touch "$BATS_TEST_TMPDIR/mtproto-probed"; }
    run core_telegram_run shared status 1
    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/uploaded" ]
    [ -e "$BATS_TEST_TMPDIR/mtproto-probed" ]
}

@test "failed noisy upload preserves redacted diagnostics without requesting server status" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.0.0; }
    rc_confirm_gate() { return 0; }
    upload_scripts() { printf 'upload failed token=upload-private-fixture\n' >&2; return 1; }
    ssh_run() { touch "$BATS_TEST_TMPDIR/status-requested"; }
    run core_telegram_run shared status 1
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/status-requested" ]
    [[ "$output" == *'upload failed'* && "$output" != *upload-private-fixture* ]]
}

@test "server menu uses actual SSH option builder with TTY and quotes entry path" {
    source_module 'ssh.sh'
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.2.3; }
    export FAKE_SSH_JOURNAL="$BATS_TEST_TMPDIR/options"
    cat > "$BATS_TEST_TMPDIR/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_SSH_JOURNAL"
exit "${FAKE_SSH_RC:-0}"
EOF
    chmod +x "$BATS_TEST_TMPDIR/ssh"
    PATH="$BATS_TEST_TMPDIR:$PATH"
    REMOTE_DIR="$BATS_TEST_TMPDIR/path with spaces"
    run_with_timeout() { printf 'unexpected-timeout\n' >> "$EVENTS"; return 1; }
    core_telegram_menu 2
    [ "$?" -eq 0 ]
    local options entry
    options=$(cat "$FAKE_SSH_JOURNAL")
    printf -v entry '%q' "$REMOTE_DIR/setup-essence.sh"
    [[ "$options" == *$'\n-t\n--\nroot@192.0.2.2\n'"bash $entry telegram-proxy menu" ]]
    export FAKE_SSH_RC=2
    core_telegram_menu 2 && return 1
    [ "$RC_ERROR_CODE" = not_ready ]
    export FAKE_SSH_RC=255
    core_telegram_menu 2 && return 1
    [ "$RC_ERROR_CODE" = remote_failed ]
}

@test "unsupported menu keeps remote root context available for another selection" {
    ssh_run() { printf 'menu:%s\n' "$NODE_NAME" >> "$EVENTS"; return 2; }
    core_telegram_menu 2 >/dev/null && return 1
    [ "$RC_ERROR_CODE" = not_ready ]
    core_telegram_menu 3 >/dev/null && return 1
    [ "$(cat "$EVENTS")" = $'menu:B\nmenu:C' ]
}

@test "batch update and refresh have no force while destructive actions exercise real server grammar" {
    # Execute the local server parser against sandbox handler effects, not SSH.
    local parser="$REMOTE_DIR/setup-essence.sh"
    cat > "$parser" <<EOF
#!/bin/bash
source "$PROJECT_ROOT/common/common.sh"
source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
telegram_proxy_remove_all() { touch "$REMOTE_DIR/removed"; }
telegram_proxy_mtproto_install() { touch "$REMOTE_DIR/installed"; }
telegram_proxy_web_update() { [[ \$# -eq 0 ]] && touch "$REMOTE_DIR/updated"; }
telegram_proxy_refresh_ip() { [[ \$# -eq 0 ]] && touch "$REMOTE_DIR/refreshed"; }
shift
telegram_proxy_cli "\$@"
EOF
    ssh_run() { [[ "$1" == -- ]] || return 1; bash -c "$2"; }
    RC_CONFIRM_YES=1
    core_telegram_run web update 1 >/dev/null
    core_telegram_run mtproto refresh-ip 1 >/dev/null
    core_telegram_run mtproto install 1 >/dev/null
    core_telegram_run shared remove-all 1 >/dev/null
    [ "$?" -eq 0 ]
    [ -e "$REMOTE_DIR/updated" ]
    [ -e "$REMOTE_DIR/refreshed" ]
    [ -e "$REMOTE_DIR/installed" ]
    [ -e "$REMOTE_DIR/removed" ]
}

@test "SSH failures in batch leave one-node management usable" {
    ssh_run() {
        printf '%s|%s\n' "$NODE_NAME" "$*" >> "$EVENTS"
        [[ "$1" == -t ]]
    }
    core_telegram_run web restart 1 >/dev/null || true
    core_telegram_run backend restart 2 >/dev/null || true
    core_telegram_menu 3 >/dev/null
    [ "$(wc -l < "$EVENTS")" -eq 3 ]
    [[ "$(cat "$EVENTS")" == *'A|-- bash '*'web restart'*'B|-- bash '*'backend restart'*'C|-t -- bash '*'telegram-proxy menu'* ]]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
    [ -z "$TELEGRAM_PROXY_BATCH_DIR" ]
    [ -z "$TELEGRAM_PROXY_BATCH_PIDS" ]
}

@test "failed component-selected removal leaves one-node management usable and clears private state" {
    rc_confirm_gate() { printf 'confirm\n' >> "$EVENTS"; return 0; }
    ssh_run() {
        printf '%s|%s\n' "$NODE_NAME" "$*" >> "$EVENTS"
        [[ "$1" == -t ]]
    }
    core_telegram_run web remove 1 >/dev/null || true
    core_telegram_menu 3 >/dev/null
    [ "$(wc -l < "$EVENTS")" -eq 3 ]
    [[ "$(cat "$EVENTS")" == 'confirm'*'A|-- bash '*'web remove --force'*'C|-t -- bash '*'telegram-proxy menu'* ]]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
    [ -z "$TELEGRAM_PROXY_BATCH_DIR" ]
    [ -z "$TELEGRAM_PROXY_BATCH_PIDS" ]
}

@test "batch abort terminates tracked process removes private files and wipes passwords" {
    local abort_dir="$BATS_TEST_TMPDIR/aborted-batch" receipt="$BATS_TEST_TMPDIR/abort-receipt"
    mkdir "$abort_dir"
    printf 'private data\n' > "$abort_dir/credentials"
    abort_fixture() (
        TELEGRAM_PROXY_BATCH_DIR="$abort_dir"
        TELEGRAM_PROXY_PLAN_PASS=(private-password)
        sleep 30 &
        local pid=$!
        TELEGRAM_PROXY_BATCH_PIDS="$pid"
        _telegram_proxy_remote_batch_abort
        printf "%s %s %s %s\n" "${#TELEGRAM_PROXY_PLAN_PASS[@]}" "${TELEGRAM_PROXY_BATCH_DIR:-empty}" \
            "${TELEGRAM_PROXY_BATCH_PIDS:-empty}" "$TELEGRAM_PROXY_BATCH_ABORTED" > "$receipt"
        ! kill -0 "$pid" 2>/dev/null
    )
    run abort_fixture
    [ "$status" -eq 0 ]
    [ ! -e "$abort_dir" ]
    [ "$(cat "$receipt")" = '0 empty empty 1' ]
}

@test "single-node menu rejects noncanonical indices before loading or preparing a node" {
    local index
    for index in '' 0 01 1+1 4 '-1'; do
        core_telegram_menu "$index" >/dev/null && return 1
        [ "$RC_ERROR_CODE" = usage ]
        [ ! -s "$EVENTS" ]
    done
}

@test "single-node missing and older bundles require consent and refusal never writes or opens SSH menu" {
    local probe_state
    _remote_scripts_probe() {
        printf 'probe:%s\n' "$NODE_NAME" >> "$EVENTS"
        REMOTE_SCRIPTS_STATE="$probe_state"; REMOTE_SCRIPTS_VERSION=1.0.0
    }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    for probe_state in missing ready; do
        : > "$EVENTS"
        TELEGRAM_PROXY_PLAN_PASS=(stale-private-password)
        RC_CONFIRM_YES=0
        core_telegram_menu 1 >/dev/null && return 1
        [ "$RC_ERROR_CODE" = confirmation_required ]
        [ "$(cat "$EVENTS")" = probe:A ]
        [ ! -e "$REMOTE_DIR/uploaded" ]
        [ ! -e "$REMOTE_DIR/menu-opened" ]
        [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
}

@test "single-node approved upload opens the server menu using the frozen target" {
    _remote_scripts_probe() {
        printf 'probe:%s\n' "$NODE_NAME" >> "$EVENTS"
        REMOTE_SCRIPTS_STATE=missing; REMOTE_SCRIPTS_VERSION=""
        if [[ -f "$REMOTE_DIR/uploaded" ]]; then
            REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.2.3
        fi
    }
    rc_confirm_gate() {
        [ "$(cat "$EVENTS")" = probe:A ] || return 2
        printf 'consent\n' >> "$EVENTS"
        jq_w '.nodes=[]' || return 2
        SERVER_IP=203.0.113.99
    }
    upload_scripts() {
        printf 'upload:%s:%s\n' "$NODE_NAME" "$SERVER_IP" >> "$EVENTS"
        touch "$REMOTE_DIR/uploaded"
    }
    ssh_run() {
        [[ "$1" == -t && "$2" == -- ]] || return 2
        printf 'menu:%s:%s\n' "$NODE_NAME" "$SERVER_IP" >> "$EVENTS"
        bash -c "$3"
    }
    printf '#!/bin/bash\n[[ "$1 $2" == "telegram-proxy menu" ]] && touch "%s/menu-opened"\n' "$REMOTE_DIR" > "$REMOTE_DIR/setup-essence.sh"
    core_telegram_menu 1 >/dev/null
    [ "$?" -eq 0 ]
    [ "$(cat "$EVENTS")" = $'probe:A\nconsent\nupload:A:192.0.2.1\nprobe:A\nmenu:A:192.0.2.1' ]
    [ -e "$REMOTE_DIR/menu-opened" ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "single-node approval rejects a changed local bundle before any server mutation" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=missing; }
    rc_confirm_gate() {
        printf 'consent\n' >> "$EVENTS"
        printf 'changed\n' >> "$COMMON_DIR/protocols/example.sh"
    }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    local rc=0
    core_telegram_menu 1 >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(cat "$EVENTS")" = consent ]
    [ ! -e "$REMOTE_DIR/uploaded" ]
    [ ! -e "$REMOTE_DIR/menu-opened" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "single-node failed upload and unverified published version never open the menu" {
    local failure rc
    rc_confirm_gate() { return 0; }
    _remote_scripts_probe() {
        REMOTE_SCRIPTS_STATE=missing; REMOTE_SCRIPTS_VERSION=""
        if [[ -e "$REMOTE_DIR/uploaded" ]]; then
            REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=9.0.0
        fi
    }
    upload_scripts() {
        touch "$REMOTE_DIR/uploaded"
        [[ "$failure" != upload ]]
    }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    for failure in upload version; do
        rm -f "$REMOTE_DIR/uploaded"
        rc=0
        core_telegram_menu 1 >/dev/null || rc=$?
        [ "$rc" -eq 1 ]
        [ -e "$REMOTE_DIR/uploaded" ]
        [ ! -e "$REMOTE_DIR/menu-opened" ]
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
}

@test "single-node excluded targets never request approval upload or menu and wipe credentials" {
    local probe_state rc
    _remote_scripts_probe() {
        REMOTE_SCRIPTS_STATE="$probe_state"
        [[ "$probe_state" != unreachable ]]
    }
    rc_confirm_gate() { touch "$REMOTE_DIR/asked"; return 0; }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    for probe_state in broken unknown unreachable; do
        TELEGRAM_PROXY_PLAN_PASS=(stale-private-password)
        rc=0
        core_telegram_menu 1 >/dev/null || rc=$?
        [ "$rc" -eq 1 ]
        [ ! -e "$REMOTE_DIR/asked" ]
        [ ! -e "$REMOTE_DIR/uploaded" ]
        [ ! -e "$REMOTE_DIR/menu-opened" ]
        [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
}

@test "single-node equal and newer bundles open without approval or upload and preserve caller credentials" {
    local probe_version
    NODE_NAME=caller SERVER_IP=203.0.113.99 SERVER_PASS=caller-private-password
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION="$probe_version"; }
    rc_confirm_gate() { touch "$REMOTE_DIR/asked"; return 1; }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() {
        [[ "$1" == -t && "$2" == -- ]] || return 2
        [[ "$SERVER_IP" == 192.0.2.2 ]] || return 1
        touch "$REMOTE_DIR/menu-opened"
    }
    for probe_version in 1.2.3 9.0.0; do
        rm -f "$REMOTE_DIR/menu-opened"
        core_telegram_menu 2 >/dev/null
        [ "$?" -eq 0 ]
        [ -e "$REMOTE_DIR/menu-opened" ]
        [ ! -e "$REMOTE_DIR/asked" ]
        [ ! -e "$REMOTE_DIR/uploaded" ]
        [ "$NODE_NAME" = caller ]
        [ "$SERVER_IP" = 203.0.113.99 ]
        [ "$SERVER_PASS" = caller-private-password ]
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
}

@test "batch worker children do not inherit SERVER_PASS in their environment" {
    node_load() {
        NODE_NAME="node-$1"; SERVER_IP="127.0.0.$1"; SERVER_PORT=22; SERVER_USER=root
        SERVER_AUTH=password; SERVER_PASS='secret-pass-xyz'
    }
    ssh_run() { env > "$BATS_TEST_TMPDIR/worker-env"; }
    prepared_batch web restart false 1 >/dev/null
    [ -s "$BATS_TEST_TMPDIR/worker-env" ]
    ! grep -q '^SERVER_PASS=' "$BATS_TEST_TMPDIR/worker-env" || return 1
    ! grep -q 'secret-pass-xyz' "$BATS_TEST_TMPDIR/worker-env"
}

@test "batch keeps the caller's ignored INT trap after a normal run" {
    trap '' INT
    prepared_batch web restart false 1 >/dev/null
    local current
    current=$(trap -p INT)
    trap - INT
    [ "$current" = "trap -- '' SIGINT" ]
}

@test "batch abort cleans up, returns 130 and restores the caller's INT trap" {
    local worker_started="$BATS_TEST_TMPDIR/worker.started" test_pid=$$
    _telegram_proxy_remote_worker_body() { : > "$worker_started"; sleep 3; }
    trap '' INT
    (
        for _ in $(seq 1 100); do [[ -e "$worker_started" ]] && break; sleep 0.1; done
        kill -TERM "$test_pid"
    ) &
    local killer=$! rc=0
    prepared_batch web restart false 1 >/dev/null 2>&1 || rc=$?
    local current
    current=$(trap -p INT)
    trap - INT TERM
    wait "$killer" 2>/dev/null || true
    [ "$rc" -eq 130 ]
    [ "$current" = "trap -- '' SIGINT" ]
    [ -z "$TELEGRAM_PROXY_BATCH_DIR" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

# Отдельный bash нужен для настоящих сигналов: фоновая подоболочка BATS
# наследует SIG_IGN и скрывает замену serve-обработчика INT. Job control
# запускающего shell даёт foreground-сценарию исходный SIG_DFL и свою группу.
telegram_signal_fixture() {
    local mode="$1" signal="$2" launch="${3:-foreground}"
    local script="$BATS_TEST_TMPDIR/signal-fixture.sh" pid n ready=0 rc=0
    {
        declare -p PROJECT_ROOT CONFIG_DIR CONFIG_JSON SCRIPT_DIR TEMPLATES_DIR GENERATED_DIR \
            BATS_TEST_TMPDIR SETUP_DIR COMMON_DIR VERSION_PATH CURRENT_VERSION
        declare -f source_common
        cat <<'EOF'
source_common
source "$PROJECT_ROOT/tests/helpers/cmd_helper.bash"
for module in state nodes ssh telegram-proxy session cli serve cmd_nodes; do
    source "$PROJECT_ROOT/remote-control/modules/$module.sh"
done
open_local_session || exit 3
trap -p INT > "$BATS_TEST_TMPDIR/signal-initial-int"
trap ':' TERM HUP
_remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION="$CURRENT_VERSION"; }
check_update_start() { :; }
ssh_run() {
    printf '%s\n' "$TELEGRAM_PROXY_BATCH_DIR" > "$BATS_TEST_TMPDIR/signal-batch-dir"
    : > "$BATS_TEST_TMPDIR/signal-started"
    local n=0
    while [[ ! -e "$BATS_TEST_TMPDIR/signal-release" && "$n" -lt 200 ]]; do
        sleep 0.05
        n=$((n + 1))
    done
    [[ -e "$BATS_TEST_TMPDIR/signal-release" ]] || return 9
    : > "$BATS_TEST_TMPDIR/signal-completed"
}
record_signal_state() {
    trap -p INT TERM HUP > "$BATS_TEST_TMPDIR/signal-restored-traps"
    printf '%s %s %s\n' "$TELEGRAM_PROXY_BATCH_ABORTED" \
        "${TELEGRAM_PROXY_BATCH_DIR:-empty}" "${#TELEGRAM_PROXY_PLAN_PASS[@]}" \
        > "$BATS_TEST_TMPDIR/signal-state"
}
register_exit_cleanup record_signal_state
if [[ "$1" == serve ]]; then
    serve_main
else
    run_cmd telegram web-restart --node A
    printf '%s\n' "$CMD_ENVELOPE"
fi
EOF
    } > "$script"
    printf '%s\n' '{"id":1,"argv":["telegram","web-restart","--node","A"]}' \
        > "$BATS_TEST_TMPDIR/signal-request"
    if [[ "$launch" == foreground ]]; then set -m; fi
    bash "$script" "$mode" < "$BATS_TEST_TMPDIR/signal-request" \
        > "$BATS_TEST_TMPDIR/signal-response" 2> "$BATS_TEST_TMPDIR/signal-stderr" &
    pid=$!
    set +m
    for ((n=0; n<200; n++)); do
        if [[ -e "$BATS_TEST_TMPDIR/signal-started" ]]; then ready=1; break; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done
    if [[ "$ready" != 1 ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        cat "$BATS_TEST_TMPDIR/signal-stderr" "$BATS_TEST_TMPDIR/signal-response"
        return 1
    fi
    if [[ "$launch" == foreground ]]; then
        kill "-$signal" -- "-$pid" || rc=$?
    else
        kill "-$signal" "$pid" || rc=$?
    fi
    : > "$BATS_TEST_TMPDIR/signal-release"
    wait "$pid" || rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    [[ ! -e "$(cat "$BATS_TEST_TMPDIR/signal-batch-dir")" ]]
    grep -Fx "trap -- ':' SIGTERM" "$BATS_TEST_TMPDIR/signal-restored-traps"
    grep -Fx "trap -- ':' SIGHUP" "$BATS_TEST_TMPDIR/signal-restored-traps"
}

@test "foreground serve Telegram batch survives process-group Ctrl+C through dispatcher and workers" {
    telegram_signal_fixture serve INT
    [ ! -s "$BATS_TEST_TMPDIR/signal-initial-int" ]
    [ -e "$BATS_TEST_TMPDIR/signal-completed" ]
    [ "$(cat "$BATS_TEST_TMPDIR/signal-state")" = '0 empty 0' ]
    grep -Fx "trap -- '' SIGINT" "$BATS_TEST_TMPDIR/signal-restored-traps"
    jq -es 'map(select(.id == 1 and has("ok"))) |
        length == 1 and .[0].ok and .[0].data.results == [
            {"node":"A","code":0,"status":"ok","reason":null}]' \
        "$BATS_TEST_TMPDIR/signal-response"
}

@test "background TUI-style serve preserves inherited ignored INT during Telegram batch" {
    telegram_signal_fixture serve INT background
    grep -Fx "trap -- '' SIGINT" "$BATS_TEST_TMPDIR/signal-initial-int"
    [ -e "$BATS_TEST_TMPDIR/signal-completed" ]
    [ "$(cat "$BATS_TEST_TMPDIR/signal-state")" = '0 empty 0' ]
    grep -Fx "trap -- '' SIGINT" "$BATS_TEST_TMPDIR/signal-restored-traps"
    jq -es 'map(select(.id == 1 and has("ok"))) | length == 1 and .[0].ok' \
        "$BATS_TEST_TMPDIR/signal-response"
}

@test "ordinary foreground Telegram batch cancels INT and restores caller traps" {
    telegram_signal_fixture batch INT
    [ ! -s "$BATS_TEST_TMPDIR/signal-initial-int" ]
    [ "$(cat "$BATS_TEST_TMPDIR/signal-state")" = '1 empty 0' ]
    ! grep -q SIGINT "$BATS_TEST_TMPDIR/signal-restored-traps"
    jq -e '.ok == false and .error.code == "remote_failed"' "$BATS_TEST_TMPDIR/signal-response"
}

@test "Telegram batch TERM and HUP still abort cleanly and restore caller traps" {
    local signal
    for signal in TERM HUP; do
        rm -f "$BATS_TEST_TMPDIR"/signal-*
        telegram_signal_fixture batch "$signal"
        [ "$(cat "$BATS_TEST_TMPDIR/signal-state")" = '1 empty 0' ]
        ! grep -q SIGINT "$BATS_TEST_TMPDIR/signal-restored-traps"
        jq -e '.ok == false and .error.code == "remote_failed"' "$BATS_TEST_TMPDIR/signal-response"
    done
}
