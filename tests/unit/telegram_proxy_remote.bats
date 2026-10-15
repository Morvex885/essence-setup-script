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
{"nodes":[{"name":"A","ip":"192.0.2.1","port":22,"user":"root","auth":"key"},{"name":"B","ip":"192.0.2.2","port":22,"user":"root","auth":"key"},{"name":"C","ip":"192.0.2.3","port":22,"user":"root","auth":"key"}],"groups":[],"clients":[],"connections":[]}
EOF
    reset_ssh_mocks
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.2.3; }
    ssh_run() { printf 'action:%s\n' "$NODE_NAME" >> "$EVENTS"; }
    upload_scripts() { printf 'upload:%s\n' "$NODE_NAME" >> "$EVENTS"; }
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

@test "preflight probes every target before one denied-default review and cancellation has no mutations" {
    _remote_scripts_probe() { mixed_probe; }
    local frame="$BATS_TEST_TMPDIR/frame"
    confirm_yn() {
        [ "$2" = N ] || return 2
        [ "$(cat "$EVENTS")" = $'probe:A\nprobe:B\nprobe:C' ] || return 2
        local output
        output=$(cat "$frame")
        [[ "$output" == *'A  192.0.2.1:22 — будут загружены скрипты v1.2.3'* ]] || return 2
        [[ "$output" == *'B  192.0.2.2:22 — исключена:'* ]] || return 2
        [[ "$output" == *'C  192.0.2.3:22'* ]] || return 2
        printf 'confirm\n' >> "$EVENTS"
        return 1
    }
    _telegram_proxy_remote_run mtproto install true 1 2 3 > "$frame"
    [ "$?" -eq 0 ]
    [ "$(cat "$EVENTS")" = $'probe:A\nprobe:B\nprobe:C\nconfirm' ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
}

@test "approval uploads only old eligible node and executes frozen eligible targets" {
    _remote_scripts_probe() { mixed_probe; }
    confirm_yn() {
        [ "$(cat "$EVENTS")" = $'probe:A\nprobe:B\nprobe:C' ] || return 2
        printf 'confirm\n' >> "$EVENTS"
        # The operation must use the snapshot, not this replacement config.
        jq_w '.nodes=[]' || return 2
    }
    upload_scripts() { touch "$REMOTE_DIR/A-uploaded"; printf 'upload:%s\n' "$NODE_NAME" >> "$EVENTS"; }
    run _telegram_proxy_remote_run mtproto install true 1 2 3
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
    confirm_yn() { printf 'confirm\n' >> "$EVENTS"; printf 'changed\n' >> "$SETUP_DIR/modules/example.sh"; }
    run _telegram_proxy_remote_run mtproto install true 1 2 3
    [ "$status" -eq 1 ]
    [ "$(grep -c '^confirm$' "$EVENTS")" -eq 1 ]
    [ "$(grep -c '^upload:' "$EVENTS")" -eq 0 ]
    [ "$(grep -c '^action:' "$EVENTS")" -eq 0 ]
}

@test "ready and newer backends restart without confirmation or per-worker preparation" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=9.0.0; }
    confirm_yn() { printf 'unexpected-confirm\n' >> "$EVENTS"; return 1; }
    _telegram_proxy_remote_run backend restart false 3 1 >/dev/null
    [ "$?" -eq 0 ]
    [ "$(wc -l < "$EVENTS")" -eq 2 ]
    [ "$(grep -c '^action:' "$EVENTS")" -eq 2 ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "all excluded produces failures with no question and cleans frozen credentials" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=broken; REMOTE_SCRIPTS_VERSION=1.2.3; }
    confirm_yn() { printf 'unexpected-confirm\n' >> "$EVENTS"; return 0; }
    local rc=0
    _telegram_proxy_remote_run mtproto install true 1 2 3 >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ ! -s "$EVENTS" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "upload requires an exact ready version before action" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.0.0; }
    confirm_yn() { return 0; }
    run _telegram_proxy_remote_run mtproto install true 1
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

@test "invalid requests neither consume confirmation input nor keep a previous plan" {
    local input="$BATS_TEST_TMPDIR/input" remaining component action force idx
    printf 'y\n' > "$input"
    exec 7< "$input"
    for component in web shared backend mtproto; do
        TELEGRAM_PROXY_PLAN_PASS=(sensitive)
        _telegram_proxy_remote_run "$component" unknown false 1 <&7 >/dev/null || true
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
    for idx in 0 01 1+1 4 ''; do
        _telegram_proxy_remote_run web restart false "$idx" <&7 >/dev/null || true
    done
    for action in update restart; do
        _telegram_proxy_remote_run web "$action" true 1 <&7 >/dev/null || true
    done
    _telegram_proxy_remote_run mtproto refresh-ip true 1 <&7 >/dev/null || true
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

@test "Enter refusal and EOF discard the entire plan before workers" {
    local input="$BATS_TEST_TMPDIR/input" rc
    for input_text in '' n; do
        printf '%s\n' "$input_text" > "$input"
        _telegram_proxy_remote_run mtproto install true 1 2 < "$input" >/dev/null
        [ "$?" -eq 0 ]
        [ ! -s "$EVENTS" ]
        [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
    done
    _telegram_proxy_remote_run mtproto install true 1 < /dev/null >/dev/null
    [ "$?" -eq 0 ]
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
    confirm_yn() { return 0; }
    upload_scripts() {
        info "Загружаем скрипты..."
        success "Скрипты загружены"
        touch "$BATS_TEST_TMPDIR/uploaded"
    }
    ssh_run() {
        printf '%s\n' '{"installed":true,"web_enabled":false,"mtproto_enabled":true,"mtproto_ipv4":"8.8.8.8"}'
    }
    _telegram_proxy_mtproto_probe() { touch "$BATS_TEST_TMPDIR/mtproto-probed"; }
    run _telegram_proxy_remote_run shared status false 1
    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/uploaded" ]
    [ -e "$BATS_TEST_TMPDIR/mtproto-probed" ]
}

@test "failed noisy upload preserves redacted diagnostics without requesting server status" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=ready; REMOTE_SCRIPTS_VERSION=1.0.0; }
    confirm_yn() { return 0; }
    upload_scripts() { printf 'upload failed token=upload-private-fixture\n' >&2; return 1; }
    ssh_run() { touch "$BATS_TEST_TMPDIR/status-requested"; }
    run _telegram_proxy_remote_run shared status false 1
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
    telegram_proxy_remote_open_menu 2
    [ "$?" -eq 0 ]
    local options entry
    options=$(cat "$FAKE_SSH_JOURNAL")
    printf -v entry '%q' "$REMOTE_DIR/setup-essence.sh"
    [[ "$options" == *$'\n-t\nroot@192.0.2.2\n'"bash $entry telegram-proxy menu" ]]
    export FAKE_SSH_RC=2
    run telegram_proxy_remote_open_menu 2
    [ "$status" -eq 2 ]
    export FAKE_SSH_RC=255
    run telegram_proxy_remote_open_menu 2
    [ "$status" -eq 255 ]
}

@test "unsupported menu keeps remote root context available for another selection" {
    ssh_run() { printf 'menu:%s\n' "$NODE_NAME" >> "$EVENTS"; return 2; }
    telegram_proxy_remote_menu <<< $'1\n2\n1\n3\n0' >/dev/null
    [ "$?" -eq 0 ]
    [ "$(cat "$EVENTS")" = $'menu:B\nmenu:C' ]
}

@test "menu zero EOF invalid keys and selector cancellation never start preflight" {
    _remote_scripts_probe() { printf 'unexpected-probe\n' >> "$EVENTS"; return 1; }
    local stream
    for stream in $'0' '' $'10\n11\nconnection\n0' $'6\n1\n0\n0' $'7\n1' $'8\nunknown\n\n0\n0' $'1\n0\n0'; do
        telegram_proxy_remote_menu <<< "$stream" >/dev/null
        [ "$?" -eq 0 ]
        [ ! -s "$EVENTS" ]
        [ "${#TELEGRAM_PROXY_SELECTED[@]}" -eq 0 ]
        [ "${#TOGGLE_SELECT_ITEMS[@]}" -eq 0 ]
        [ "${#TOGGLE_SELECT_FLAGS[@]}" -eq 0 ]
    done
    telegram_proxy_remote_menu < /dev/null >/dev/null
    [ "$?" -eq 0 ]
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
    confirm_yn() { return 0; }
    telegram_proxy_remote_menu <<< $'5\n1\n\n4\n1\n\n3\n1\n\n9\n1\n\n0' >/dev/null
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
    telegram_proxy_remote_menu <<< $'6\n1\n\n7\n2\n\n1\n3\n0' >/dev/null
    [ "$?" -eq 0 ]
    [ "$(wc -l < "$EVENTS")" -eq 3 ]
    [[ "$(cat "$EVENTS")" == *'A|-- bash '*'web restart'*'B|-- bash '*'backend restart'*'C|-t -- bash '*'telegram-proxy menu'* ]]
}

@test "batch abort terminates tracked process removes private files and wipes passwords" {
    local dir="$BATS_TEST_TMPDIR/aborted-batch" receipt="$BATS_TEST_TMPDIR/abort-receipt"
    mkdir "$dir"
    printf 'private data\n' > "$dir/credentials"
    abort_fixture() (
        TELEGRAM_PROXY_BATCH_DIR="$dir"
        TELEGRAM_PROXY_PLAN_PASS=(private-password)
        sleep 30 &
        local pid=$!
        TELEGRAM_PROXY_BATCH_PIDS="$pid"
        trap 'printf "%s %s %s\n" "${#TELEGRAM_PROXY_PLAN_PASS[@]}" "${TELEGRAM_PROXY_BATCH_DIR:-empty}" "${TELEGRAM_PROXY_BATCH_PIDS:-empty}" > "$receipt"; ! kill -0 "$pid" 2>/dev/null' EXIT
        _telegram_proxy_remote_batch_abort
    )
    run abort_fixture
    [ "$status" -eq 130 ]
    [ ! -e "$dir" ]
    [ "$(cat "$receipt")" = '0 empty empty' ]
}

@test "single-node menu rejects noncanonical indices before loading or preparing a node" {
    local index
    for index in '' 0 01 1+1 4 '-1'; do
        run telegram_proxy_remote_open_menu "$index"
        [ "$status" -eq 2 ]
        [ ! -s "$EVENTS" ]
    done
}

@test "single-node missing and older bundles require consent and refusal never writes or opens SSH menu" {
    local probe_state answer
    _remote_scripts_probe() {
        printf 'probe:%s\n' "$NODE_NAME" >> "$EVENTS"
        REMOTE_SCRIPTS_STATE="$probe_state"; REMOTE_SCRIPTS_VERSION=1.0.0
    }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    for probe_state in missing ready; do
        for answer in '' N EOF; do
            : > "$EVENTS"
            TELEGRAM_PROXY_PLAN_PASS=(stale-private-password)
            if [[ "$answer" == EOF ]]; then
                telegram_proxy_remote_open_menu 1 < /dev/null >/dev/null
            else
                telegram_proxy_remote_open_menu 1 <<< "$answer" >/dev/null
            fi
            [ "$?" -eq 0 ]
            [ "$(cat "$EVENTS")" = probe:A ]
            [ ! -e "$REMOTE_DIR/uploaded" ]
            [ ! -e "$REMOTE_DIR/menu-opened" ]
            [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
            [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
        done
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
    confirm_yn() {
        [ "$2" = N ] && [ "$(cat "$EVENTS")" = probe:A ] || return 2
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
    telegram_proxy_remote_open_menu 1 >/dev/null
    [ "$?" -eq 0 ]
    [ "$(cat "$EVENTS")" = $'probe:A\nconsent\nupload:A:192.0.2.1\nprobe:A\nmenu:A:192.0.2.1' ]
    [ -e "$REMOTE_DIR/menu-opened" ]
    [ "${#TELEGRAM_PROXY_PLAN_INDEX[@]}" -eq 0 ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "single-node approval rejects a changed local bundle before any server mutation" {
    _remote_scripts_probe() { REMOTE_SCRIPTS_STATE=missing; }
    confirm_yn() {
        printf 'consent\n' >> "$EVENTS"
        printf 'changed\n' >> "$COMMON_DIR/protocols/example.sh"
    }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    local rc=0
    telegram_proxy_remote_open_menu 1 >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(cat "$EVENTS")" = consent ]
    [ ! -e "$REMOTE_DIR/uploaded" ]
    [ ! -e "$REMOTE_DIR/menu-opened" ]
    [ "${#TELEGRAM_PROXY_PLAN_PASS[@]}" -eq 0 ]
}

@test "single-node failed upload and unverified published version never open the menu" {
    local failure rc
    confirm_yn() { return 0; }
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
        telegram_proxy_remote_open_menu 1 >/dev/null || rc=$?
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
    confirm_yn() { touch "$REMOTE_DIR/asked"; return 0; }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() { touch "$REMOTE_DIR/menu-opened"; }
    for probe_state in broken unknown unreachable; do
        TELEGRAM_PROXY_PLAN_PASS=(stale-private-password)
        rc=0
        telegram_proxy_remote_open_menu 1 >/dev/null || rc=$?
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
    confirm_yn() { touch "$REMOTE_DIR/asked"; return 1; }
    upload_scripts() { touch "$REMOTE_DIR/uploaded"; }
    ssh_run() {
        [[ "$1" == -t && "$2" == -- ]] || return 2
        [[ "$SERVER_IP" == 192.0.2.2 ]] || return 1
        touch "$REMOTE_DIR/menu-opened"
    }
    for probe_version in 1.2.3 9.0.0; do
        rm -f "$REMOTE_DIR/menu-opened"
        telegram_proxy_remote_open_menu 2 >/dev/null
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
