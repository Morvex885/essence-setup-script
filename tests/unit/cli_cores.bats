#!/usr/bin/env bats
# Core-функции CLI/TUI: валидация через rc_fail до любых эффектов.
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    override_pass_key
    load_fixture_config
    load_fixture_template
    reset_ssh_mocks
    rc_error_reset
}

teardown() { teardown_test_env; }

config_snapshot() { jq -S . "$CONFIG_JSON"; }

@test 'core_node_rename cascades into connections and clients' {
    core_node_rename de-vps de-new
    [ "$(jq -r '[.nodes[].name] | join(",")' "$CONFIG_JSON")" = "de-new,ru-vps" ]
    jq -e 'any(.connections[]; .node=="de-new")' "$CONFIG_JSON" >/dev/null
    jq -e '.clients[] | select(.name=="my-pc") | .nodes == ["de-new"] and .connections[0].node == "de-new"' "$CONFIG_JSON" >/dev/null
}

@test 'core_node_rename reports conflict and not_found without writing' {
    local before
    before=$(config_snapshot)
    core_node_rename de-vps ru-vps || true
    [ "$RC_ERROR_CODE" = conflict ]
    rc_error_reset
    core_node_rename missing other || true
    [ "$RC_ERROR_CODE" = not_found ]
    [ "$(config_snapshot)" = "$before" ]
}

@test 'core_node_add rejects invalid input before any SSH' {
    core_node_add de-vps 9.9.9.9 22 root key "" T accept-new false || true
    [ "$RC_ERROR_CODE" = conflict ]
    rc_error_reset
    core_node_add new 9.9.9.9 22 root key "" "" accept-new false || true
    [ "$RC_ERROR_CODE" = invalid ]
    rc_error_reset
    core_node_add new 9.9.9.9 70000 root key "" T accept-new false || true
    [ "$RC_ERROR_CODE" = invalid ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "$(jq '.nodes | length' "$CONFIG_JSON")" -eq 2 ]
}

@test 'core_node_add known-only refuses an unpinned host key and reports fingerprints' {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    cat > "$bin/ssh-keyscan" <<'EOF'
#!/bin/bash
echo "9.9.9.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTests"
EOF
    cat > "$bin/ssh-keygen" <<'EOF'
#!/bin/bash
case "$1" in
    -F) exit 1 ;;
    -l*|-E) echo "256 SHA256:fakefingerprint 9.9.9.9 (ED25519)" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin/ssh-keyscan" "$bin/ssh-keygen"
    PATH="$bin:$PATH" core_node_add new 9.9.9.9 22 root key "" T known-only false || true
    [ "$RC_ERROR_CODE" = host_key_unknown ]
    jq -e '.fingerprints | index("SHA256:fakefingerprint")' <<< "$RC_ERROR_EXTRA" >/dev/null
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "$(jq '.nodes | length' "$CONFIG_JSON")" -eq 2 ]
}

@test 'core_client_set_connections refuses an inheriting client' {
    local before
    before=$(config_snapshot)
    core_client_set_connections my-router de-vps vless-reality || true
    [ "$RC_ERROR_CODE" = invalid ]
    [ "$(config_snapshot)" = "$before" ]
}

@test 'core_conn_assign with an unknown group changes nothing' {
    local before
    before=$(config_snapshot)
    core_conn_assign de-vps 1 NOPE vless-reality || true
    [ "$RC_ERROR_CODE" = not_found ]
    [ "$(config_snapshot)" = "$before" ]
}

@test 'subscription_publish rejects a bad TTL before uploading anything' {
    jq_w '.subscription_host = {node:"de-vps", base_url:"https://sub.example"}'
    mkdir -p "$(dirname "$(_client_config_file my-pc)")"
    printf 'proxies: []\n' > "$(_client_config_file my-pc)"
    subscription_publish my-pc 1m status || true
    [ "$RC_ERROR_CODE" = invalid ]
    [ "${#SCP_RUN_CALLS[@]}" -eq 0 ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    jq -e '.clients[] | select(.name=="my-pc") | .subscription == null' "$CONFIG_JSON" >/dev/null
}

@test '_sub_ttl_to_epoch accepts h/d/w with exact offsets and rejects the rest' {
    local now got bad
    now=$(date +%s)
    got=$(_sub_ttl_to_epoch 1h); (( got - now >= 3600 && got - now <= 3602 ))
    got=$(_sub_ttl_to_epoch 7d); (( got - now >= 604800 && got - now <= 604802 ))
    got=$(_sub_ttl_to_epoch 2w); (( got - now >= 1209600 && got - now <= 1209602 ))
    for bad in 0d 1m d -1d "1 d" ""; do
        run _sub_ttl_to_epoch "$bad"
        assert_failure
    done
}

@test 'core_telegram_run without --yes stops at confirmation before any remote write' {
    _telegram_proxy_remote_preflight() {
        _telegram_proxy_remote_clear_plan
        TELEGRAM_PROXY_PLAN_INDEX=(1) TELEGRAM_PROXY_PLAN_NAME=(de-vps)
        TELEGRAM_PROXY_PLAN_IP=(1.2.3.4) TELEGRAM_PROXY_PLAN_PORT=(22)
        TELEGRAM_PROXY_PLAN_STATE=(ready) TELEGRAM_PROXY_PLAN_REASON=("")
        TELEGRAM_PROXY_PLAN_FINGERPRINT=fp-1 TELEGRAM_PROXY_PLAN_VERSION=1.0.0
        return 0
    }
    telegram_proxy_remote_batch() { echo batch >> "$BATS_TEST_TMPDIR/batch"; return 0; }
    local token
    RC_CONFIRM_SCOPE=$'telegram install\n--node\nde-vps'
    core_telegram_run mtproto install 1 || true
    [ "$RC_ERROR_CODE" = confirmation_required ]
    jq -e '.plan | length > 0' <<< "$RC_ERROR_EXTRA" >/dev/null
    token=$(jq -r '.plan_token' <<< "$RC_ERROR_EXTRA")
    [ ! -e "$BATS_TEST_TMPDIR/batch" ]
    local call
    for call in "${SSH_RUN_CALLS[@]}"; do
        [[ "$call" != *"mtproto install"* ]]
    done

    # Другой комплект скриптов меняет токен, хотя текст плана тот же.
    _telegram_proxy_remote_preflight() {
        _telegram_proxy_remote_clear_plan
        TELEGRAM_PROXY_PLAN_INDEX=(1) TELEGRAM_PROXY_PLAN_NAME=(de-vps)
        TELEGRAM_PROXY_PLAN_IP=(1.2.3.4) TELEGRAM_PROXY_PLAN_PORT=(22)
        TELEGRAM_PROXY_PLAN_STATE=(ready) TELEGRAM_PROXY_PLAN_REASON=("")
        TELEGRAM_PROXY_PLAN_FINGERPRINT=fp-2 TELEGRAM_PROXY_PLAN_VERSION=1.0.0
        return 0
    }
    rc_error_reset
    RC_CONFIRM_YES=1 RC_CONFIRM_TOKEN="$token"
    core_telegram_run mtproto install 1 || true
    [ "$RC_ERROR_CODE" = plan_changed ]
    [ ! -e "$BATS_TEST_TMPDIR/batch" ]

    RC_CONFIRM_TOKEN=$(jq -r '.plan_token' <<< "$RC_ERROR_EXTRA")
    [ "$RC_CONFIRM_TOKEN" != "$token" ]
    rc_error_reset
    core_telegram_run mtproto install 1
    [ -s "$BATS_TEST_TMPDIR/batch" ]
}

@test 'core_generate_client writes only the requested client config' {
    _reset_node_cache
    _node_config_cache_set "de-vps" "$(load_fixture_client_config)"
    _ensure_all_awg_peers() { :; }
    _sync_listeners_on_nodes() { :; }
    core_generate_client my-pc
    [ -s "$GENERATED_DIR/PC/my-pc/config.yaml" ]
    [ ! -e "$GENERATED_DIR/ROUTER/my-router/config.yaml" ]
    run core_generate_client nobody
    assert_failure
}

@test 'nested state_action does not deadlock and releases the lock' {
    inner() { return 0; }
    outer() { state_action inner inner; }
    RC_LOCK_WAIT=2 state_action outer outer
    [ ! -e "$CONFIG_DIR/.rc-lock" ]
}

@test 'a live foreign session lock fails a mutation immediately' {
    sleep 30 &
    local holder=$!
    mkdir "$CONFIG_DIR/.rc-lock"
    printf 'pid=%s\nkind=session\nlabel=github-session\n' "$holder" > "$CONFIG_DIR/.rc-lock/owner"
    local start=$SECONDS
    RC_LOCK_WAIT=20 state_action noop true || true
    kill "$holder" 2>/dev/null || true
    [ "$RC_ERROR_CODE" = locked ]
    (( SECONDS - start < 5 ))
    [ -d "$CONFIG_DIR/.rc-lock" ]
}

@test 'a lock leaked by an exited subshell of this process is reclaimed' {
    noop() { return 0; }
    ( rc_lock_acquire mutation leaked; exit 0 )
    [ -d "$CONFIG_DIR/.rc-lock" ]
    local start=$SECONDS
    RC_LOCK_WAIT=10 state_action noop noop
    (( SECONDS - start < 5 ))
    [ ! -e "$CONFIG_DIR/.rc-lock" ]
}

@test 'error() exit under --json still leaves exactly one ok:false document on fd 3' {
    run --separate-stderr bash -c '
        source "$1/common/common.sh"
        source "$1/remote-control/modules/state.sh"
        source "$1/remote-control/modules/cli.sh"
        exec 3>&1 1>&2
        register_exit_cleanup cli_json_fallback
        error "сбой ядра"
    ' _ "$PROJECT_ROOT"
    [ "$status" -eq 1 ]
    [ "$(printf "%s\n" "$output" | wc -l | tr -d " ")" -eq 1 ]
    jq -e '.ok == false and .error.code == "failed"' <<< "$output" >/dev/null
}

@test 'partial result is checkpointed but still reported as failure' {
    state_checkpoint() { : > "$BATS_TEST_TMPDIR/checkpointed"; }
    half_done() { jq_w '.marker = "changed"'; rc_fail partial "Изменено частично."; }
    fails() { rc_fail invalid "Нет."; }
    state_action half_done half_done && return 1
    [ "$RC_ERROR_CODE" = partial ]
    [ -e "$BATS_TEST_TMPDIR/checkpointed" ]
    rm "$BATS_TEST_TMPDIR/checkpointed"
    state_action fails fails && return 1
    [ ! -e "$BATS_TEST_TMPDIR/checkpointed" ]
}

@test 'GitHub transport persists and pushes a partial result, not a plain failure' {
    source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
    CONFIG_SOURCE=github
    local log="$BATS_TEST_TMPDIR/persist.log"
    state_validate() { echo validate >> "$log"; }
    state_checkpoint() { echo checkpoint >> "$log"; }
    github_config_checkpoint() { echo github_checkpoint >> "$log"; }
    github_sync_flush() { echo flush >> "$log"; }
    half_done() { rc_fail partial "Изменено частично."; }
    fails() { rc_fail failed "Нет."; }

    state_action half_done half_done && return 1
    [ "$RC_ERROR_CODE" = partial ]
    [ "$(tr '\n' ' ' < "$log")" = "validate checkpoint github_checkpoint flush " ]

    rm -f "$log"
    state_action fails fails && return 1
    [ ! -e "$log" ]
}

# ─── Диспетчер rc_dispatch ───────────────────────────────────────────────────

@test 'rc_dispatch without an open session answers session_closed in serve mode' {
    RC_SESSION_AUTO_OPEN=0
    run_cmd group list
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = session_closed ]
    run_cmd session status
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.open')" = false ]
}

@test 'rc_dispatch plan token: confirmation_required, plan_changed, then execution' {
    local token
    open_local_session
    run_cmd group add --name lab
    [ "$status" -eq 0 ]
    run_cmd group delete --name LAB --json
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    token=$(cmd_jq '.error.plan_token')
    [[ "$token" =~ ^[0-9a-f]{16}$ ]]
    run_cmd group delete --name LAB --yes --plan-token "$token" --name-typo x
    [ "$(cmd_jq '.error.code')" = usage ]
    # Другой порядок аргументов — другая область токена.
    run_cmd group delete --yes --plan-token="$token" --name=LAB
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = plan_changed ]
    [ "$(cmd_jq '.error.plan_token')" != "$token" ]
    jq -e 'any(.groups[]; .name=="LAB")' "$CONFIG_JSON" >/dev/null
    run_cmd group delete --name LAB --yes --plan-token "$token" --json
    [ "$status" -eq 0 ]
    run jq -e 'any(.groups[]; .name=="LAB")' "$CONFIG_JSON"
    assert_failure
}

@test 'rc_dispatch checks secrets against the spec and resets per-command state' {
    open_local_session
    RC_REQUEST_SECRETS='{"password":"pw"}'
    run_cmd group list
    [ "$status" -eq 2 ]
    [[ "$(cmd_jq '.error.message')" == *"password"* ]]
    [ -z "${RC_REQUEST_SECRETS+x}" ]
    RC_REQUEST_SECRETS='["pw"]'
    run_cmd node password --name de-vps
    [ "$(cmd_jq '.error.code')" = usage ]
    GITHUB_DECISION_REMEMBER_KEY=1 GITHUB_SECRET_VAULT_PASSWORD=x CLI_OPT_stale=1 CLI_SET_stale=1
    run_cmd group list
    [ "$status" -eq 0 ]
    [ -z "${GITHUB_DECISION_REMEMBER_KEY+x}${GITHUB_SECRET_VAULT_PASSWORD+x}${CLI_SET_stale+x}" ]
}

@test 'rc_secret reads only the request secrets and _rc_secrets_add keeps earlier ones' {
    local json
    RC_REQUEST_SECRETS='{"password":"","script-password":"a b"}'
    run rc_secret password
    assert_success
    assert_output ''
    [ "$(rc_secret script-password)" = 'a b' ]
    run rc_secret vault-password
    assert_failure
    json=$(_rc_secrets_add '{}' script-password $'p1\nx')
    json=$(_rc_secrets_add "$json" vault-password 'p"2')
    jq -e '. == {"script-password":"p1\nx","vault-password":"p\"2"}' <<< "$json" >/dev/null
}

@test 'RC_QUIET_DECISIONS hides only decision codes from the log' {
    RC_QUIET_DECISIONS=1
    run rc_fail confirmation_required "скрыто"
    assert_output ''
    run rc_fail plan_changed "скрыто"
    assert_output ''
    run rc_fail conflict "видно"
    assert_output --partial 'видно'
    RC_QUIET_DECISIONS=0
    run rc_fail vault_password_required "видно"
    assert_output --partial 'видно'
}

@test '_rc_finish maps codes to exit codes and keeps data on errors' {
    local code
    for code in usage host_key_unknown plan_changed confirmation_required auth_required; do
        rc_fail "$code" "" || true
        CLI_DATA=""
        _rc_finish 1 >/dev/null
        [ "$RC_EXIT_CODE" -eq 2 ]
    done
    rc_fail partial "Частично." >/dev/null || true
    CLI_DATA='{"ok":["a"]}'
    _rc_finish 1
    [ "$RC_EXIT_CODE" -eq 1 ]
    jq -e '.ok == false and .error.code == "partial" and .data.ok == ["a"]' <<< "$RC_ENVELOPE" >/dev/null
    CLI_NOUN=telegram
    rc_fail not_installed "Нет." >/dev/null || true
    _rc_finish 3
    [ "$RC_EXIT_CODE" -eq 3 ]
    CLI_NOUN=group CLI_DATA='not json'
    _rc_finish 0
    [ "$RC_ENVELOPE" = '{"ok":true,"data":null}' ]
}

@test 'cli_render_human renders tables, nested objects and scalar cells' {
    RC_ENVELOPE='{"ok":true,"data":[{"name":"a","on":true,"tags":["x","y"]},{"name":"bbb","on":null,"extra":{"k":1}}]}'
    run cli_render_human
    assert_success
    assert_line --index 0 '  name  on  tags  extra'
    assert_line --index 1 '  a     да  x, y  —'
    assert_line --index 2 '  bbb   —   —     {"k":1}'
    RC_ENVELOPE='{"ok":true,"data":{"version":"1","counts":{"nodes":2},"items":[{"n":1}],"empty":[]}}'
    run cli_render_human
    assert_line --index 0 '  version: 1'
    assert_line --index 1 '  counts:'
    assert_line --index 2 '    nodes: 2'
    assert_line --index 3 '  items:'
    assert_line --index 4 '    n'
    assert_line --index 5 '    1'
    assert_line --index 6 '  empty: —'
    RC_ENVELOPE='{"ok":false,"error":{"code":"remote_failed","message":"m","reason":"timeout"}}'
    run cli_render_human
    assert_output '  reason: timeout'
}

# ─── telegram: команды поверх core_telegram_run ──────────────────────────────

# Узлы «готовы»: действие — одна строка action:<нода> в TG_EVENTS (FIFO-воркеры
# пишут туда из подоболочек); TG_FAIL_NODE — нода, где действие завершается ошибкой.
_tg_setup() {
    open_local_session
    TG_EVENTS="$BATS_TEST_TMPDIR/tg-events"
    : > "$TG_EVENTS"
    VERSION_PATH="$BATS_TEST_TMPDIR/VERSION"
    printf '1.2.3\n' > "$VERSION_PATH"
    TG_PROBE_STATE=ready
    _telegram_proxy_remote_bundle_fingerprint() { printf 'fp\n'; }
    _remote_scripts_probe() {
        REMOTE_SCRIPTS_STATE="$TG_PROBE_STATE"; REMOTE_SCRIPTS_VERSION=1.2.3
        [[ ! -e "$BATS_TEST_TMPDIR/uploaded-$NODE_NAME" ]] || REMOTE_SCRIPTS_STATE=ready
    }
    upload_scripts() { printf 'upload:%s\n' "$NODE_NAME" >> "$TG_EVENTS"; : > "$BATS_TEST_TMPDIR/uploaded-$NODE_NAME"; }
    ssh_run() { printf 'action:%s\n' "$NODE_NAME" >> "$TG_EVENTS"; [[ "$NODE_NAME" != "${TG_FAIL_NODE:-}" ]]; }
}

@test 'telegram commands validate nodes and flags before any SSH or plan' {
    _tg_setup
    local before
    before=$(config_snapshot)
    run_cmd telegram install
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd telegram install --node de-vps --all
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd telegram install --node de-vps --component web
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd telegram remove --node de-vps
    [ "$status" -eq 2 ]
    run_cmd telegram remove --node de-vps --component bogus
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd telegram web-update --node missing
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = not_found ]
    [ ! -s "$TG_EVENTS" ]
    [ "${#SSH_RUN_CALLS[@]}" -eq 0 ]
    [ "$(config_snapshot)" = "$before" ]
}

@test 'telegram web-restart acts on every selected node without a gate and returns per-node results' {
    _tg_setup
    run_cmd telegram web-restart --all
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '[.data.results[] | [.node, .status]]')" = '[["de-vps","ok"],["ru-vps","ok"]]' ]
    [ "$(sort "$TG_EVENTS" | tr '\n' ' ')" = 'action:de-vps action:ru-vps ' ]
}

@test 'telegram batch failure on one node keeps the other result and reports remote_failed' {
    _tg_setup
    TG_FAIL_NODE=ru-vps
    run_cmd telegram web-restart --all
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ "$(cmd_jq -c '[.data.results[] | [.node, .status]]')" = '[["de-vps","ok"],["ru-vps","error"]]' ]
    grep -qx 'action:de-vps' "$TG_EVENTS"
}

@test 'telegram partial and not_installed aggregates map to their own codes and statuses' {
    _tg_setup
    telegram_proxy_remote_batch() {
        TELEGRAM_PROXY_RESULT_NAMES=(de-vps ru-vps)
        TELEGRAM_PROXY_RESULT_CODES=(0 "$TG_AGGREGATE")
        TELEGRAM_PROXY_RESULT_REASONS=("" "причина")
        return "$TG_AGGREGATE"
    }
    TG_AGGREGATE=4
    run_cmd telegram web-restart --all
    [ "$status" -eq 4 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    [ "$(cmd_jq -c '[.data.results[] | .status]')" = '["ok","partial"]' ]
    TG_AGGREGATE=3
    run_cmd telegram web-restart --all
    [ "$status" -eq 3 ]
    [ "$(cmd_jq '.error.code')" = not_installed ]
    [ "$(cmd_jq -c '[.data.results[] | .status]')" = '["ok","not_installed"]' ]
    [ "$(cmd_jq '.data.results[1].reason')" = причина ]
}

@test 'telegram remove-all is gated, executes only with the matching plan token and rejects a changed plan' {
    _tg_setup
    run_cmd telegram remove-all --all
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(cmd_jq '.error.plan | length > 0')" = true ]
    [[ "$(cmd_jq '.error.plan | join("\n")')" == *de-vps*ru-vps* ]]
    [ ! -s "$TG_EVENTS" ]
    local token
    token=$(cmd_jq '.error.plan_token')
    # План изменился (теперь нужна загрузка скриптов): старый токен не годится.
    TG_PROBE_STATE=missing
    run_cmd telegram remove-all --all --yes --plan-token "$token"
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = plan_changed ]
    [ ! -s "$TG_EVENTS" ]
    # Прежний план и его токен: выполняется на обеих нодах.
    TG_PROBE_STATE=ready
    run_cmd telegram remove-all --all --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '[.data.results[] | .status]')" = '["ok","ok"]' ]
    [ "$(grep -c '^action:' "$TG_EVENTS")" -eq 2 ]
}

@test 'telegram remove needs a component and is gated per component' {
    _tg_setup
    run_cmd telegram remove --component web --node de-vps
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ ! -s "$TG_EVENTS" ]
    run_cmd telegram remove --component mtproto --node de-vps --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data.results | map(.node)')" = '["de-vps"]' ]
}

@test 'telegram install uploads scripts only after consent when the bundle is missing' {
    _tg_setup
    TG_PROBE_STATE=missing
    run_cmd telegram install --node de-vps
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ ! -s "$TG_EVENTS" ]
    local token
    token=$(cmd_jq '.error.plan_token')
    run_cmd telegram install --node de-vps --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^upload:de-vps$' "$TG_EVENTS")" -eq 1 ]
}

@test 'telegram verbs map to component and action; status needs no nodes and no gate' {
    _tg_setup
    core_telegram_run() { printf '%s %s |%s\n' "$1" "$2" "${*:3}" >> "$TG_EVENTS"; TELEGRAM_PROXY_RESULT_NAMES=(); }
    local verb
    for verb in install refresh-ip web-update web-restart backend-restart; do
        run_cmd telegram "$verb" --node ru-vps
        [ "$status" -eq 0 ]
    done
    run_cmd telegram remove --component web --node de-vps --node ru-vps
    run_cmd telegram remove-all --all
    run_cmd telegram status
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"results":[]}' ]
    [ "$(cat "$TG_EVENTS")" = "$(printf '%s\n' 'mtproto install |2' 'mtproto refresh-ip |2' 'web update |2' \
        'web restart |2' 'backend restart |2' 'web remove |1 2' 'shared remove-all |1 2' 'shared status |1 2')" ]
}

# ─── node rename / tag / aliases ─────────────────────────────────────────────

@test 'node rename changes the name everywhere, answers the new name and refuses conflicts and unknown nodes' {
    open_local_session
    run_cmd node rename --name de-vps --new-name de-new
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.name')" = de-new ]
    [ "$(jq -r '[.nodes[].name] | join(",")' "$CONFIG_JSON")" = "de-new,ru-vps" ]
    jq -e 'any(.connections[]; .node=="de-new") and (any(.connections[]; .node=="de-vps") | not)' "$CONFIG_JSON" >/dev/null
    local before
    before=$(config_snapshot)
    run_cmd node rename --name de-new --new-name ru-vps
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = conflict ]
    run_cmd node rename --name nope --new-name other
    [ "$(cmd_jq '.error.code')" = not_found ]
    run_cmd node rename --name de-new
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    local bad
    for bad in '../x' 'bad/name' 'a b' '..' 'x;y'; do
        run_cmd node rename --name de-new --new-name "$bad"
        [ "$status" -eq 1 ]
        [ "$(cmd_jq '.error.code')" = invalid ]
    done
    [ "$(config_snapshot)" = "$before" ]
}

@test 'node tag stores the tag and answers it; unknown node and a missing tag change nothing' {
    open_local_session
    run_cmd node tag --name de-vps --tag EU-1
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"name":"de-vps","tag":"EU-1"}' ]
    [ "$(jq -r '.nodes[] | select(.name=="de-vps") | .tag' "$CONFIG_JSON")" = EU-1 ]
    local before
    before=$(config_snapshot)
    run_cmd node tag --name nope --tag X
    [ "$(cmd_jq '.error.code')" = not_found ]
    run_cmd node tag --name de-vps --tag
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    local bad
    for bad in 'bad;tag' 'a/b' 'x$y' $'a\tb' "$(printf 'T%.0s' {1..33})"; do
        run_cmd node tag --name de-vps --tag "$bad"
        [ "$status" -eq 1 ]
        [ "$(cmd_jq '.error.code')" = invalid ]
    done
    [ "$(config_snapshot)" = "$before" ]
}

@test 'node aliases sets, replaces and unsets connection aliases in one state action' {
    open_local_session
    run_cmd node aliases --name de-vps --set a=b --set c=d
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data.aliases')" = '{"a":"b","c":"d"}' ]
    [ "$(jq -c '.nodes[] | select(.name=="de-vps") | .aliases' "$CONFIG_JSON")" = '{"a":"b","c":"d"}' ]
    run_cmd node aliases --name de-vps --set a=z --unset c
    [ "$status" -eq 0 ]
    [ "$(jq -c '.nodes[] | select(.name=="de-vps") | .aliases' "$CONFIG_JSON")" = '{"a":"z"}' ]
    run_cmd node aliases --name de-vps --set a=
    [ "$(jq -c '.nodes[] | select(.name=="de-vps") | .aliases' "$CONFIG_JSON")" = '{}' ]
}

@test 'node aliases rejects malformed --set/--unset and unknown nodes without writing' {
    open_local_session
    local before
    before=$(config_snapshot)
    run_cmd node aliases --name de-vps --set novalue
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd node aliases --name de-vps --unset
    [ "$status" -eq 2 ]
    run_cmd node aliases --name nope --set a=b
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = not_found ]
    [ "$(config_snapshot)" = "$before" ]
}

# ─── template list / import ──────────────────────────────────────────────────

@test 'template list reports every template with its source and the groups that use it' {
    open_local_session
    printf 'mode: rule\n' > "$TEMPLATES_DIR/extra.yaml"
    run_cmd template list
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '[.data[] | select(.name=="default.yaml") | .groups | sort] | .[0]')" = '["MOBILE","PC","ROUTER"]' ]
    [ "$(cmd_jq -c '[.data[] | select(.name=="extra.yaml") | .groups] | .[0]')" = '[]' ]
    [ "$(cmd_jq '[.data[] | .source] | all(. == "user" or . == "builtin")')" = true ]
}

@test 'template import copies a new file; overwriting is gated and a stale token changes nothing' {
    open_local_session
    local src="$BATS_TEST_TMPDIR/in.yaml"
    printf 'mode: global\n' > "$src"
    run_cmd template import --name imported --file "$src"
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.name')" = imported.yaml ]
    cmp -s "$src" "$TEMPLATES_DIR/imported.yaml"
    printf 'mode: direct\n' > "$src"
    run_cmd template import --name imported.yaml --file "$src"
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(cat "$TEMPLATES_DIR/imported.yaml")" = 'mode: global' ]
    run_cmd template import --name imported --file "$src" --yes --plan-token 0000000000000000
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = plan_changed ]
    [ "$(cat "$TEMPLATES_DIR/imported.yaml")" = 'mode: global' ]
    run_cmd template import --name imported --file "$src" --yes --plan-token "$(cmd_jq '.error.plan_token')"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEMPLATES_DIR/imported.yaml")" = 'mode: direct' ]
}

@test 'template import rejects a missing file, an unsafe name and a missing flag without writing' {
    open_local_session
    run_cmd template import --name x --file "$BATS_TEST_TMPDIR/absent.yaml"
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = invalid ]
    printf 'a: b\n' > "$BATS_TEST_TMPDIR/in.yaml"
    run_cmd template import --name '../evil' --file "$BATS_TEST_TMPDIR/in.yaml"
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd template import --name x
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    [ ! -e "$TEMPLATES_DIR/x.yaml" ]
    [ ! -e "$TEMPLATES_DIR/../evil.yaml" ]
}

# ─── source github-*: решения и подтверждение до любых записей ───────────────

_github_age_session() {
    open_local_session
    CONFIG_SOURCE=github
    GITHUB_STORAGE_MODE=age
    GITHUB_WORKTREE="$BATS_TEST_TMPDIR/worktree"
    mkdir -p "$GITHUB_WORKTREE"
    printf 'locked\n' > "$GITHUB_WORKTREE/unlock.age"
    _cli_source_require_github() { return 0; }
    git() { printf 'git %s\n' "$*" >> "$BATS_TEST_TMPDIR/git.calls"; return 1; }
}

@test 'source github-rotate-key asks for the new password first, then needs consent and a matching token' {
    _github_age_session
    run_cmd source github-rotate-key --yes
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = new_vault_password_required ]
    RC_REQUEST_SECRETS='{"new-vault-password":"np"}' run_cmd source github-rotate-key
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(cmd_jq '.error.plan | length > 0')" = true ]
    RC_REQUEST_SECRETS='{"new-vault-password":"np"}' run_cmd source github-rotate-key --yes --plan-token 0000000000000000
    [ "$(cmd_jq '.error.code')" = plan_changed ]
    [[ "$output$CMD_ENVELOPE" != *'"np"'* ]]
    # Ни одна запись в рабочей копии не начата.
    [ ! -e "$BATS_TEST_TMPDIR/git.calls" ]
    [ "$(cat "$GITHUB_WORKTREE/unlock.age")" = locked ]
}

@test 'source github-rewrap-password reports which password is missing before touching the repository' {
    _github_age_session
    run_cmd source github-rewrap-password
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = vault_password_required ]
    RC_REQUEST_SECRETS='{"vault-password":"op"}' run_cmd source github-rewrap-password
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = new_vault_password_required ]
    [ "$(cat "$GITHUB_WORKTREE/unlock.age")" = locked ]
}

@test 'source github-rewrap-password and rotate-key need age storage and a connected source' {
    open_local_session
    run_cmd source github-rotate-key --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = not_ready ]
    run_cmd source github-rewrap-password
    [ "$(cmd_jq '.error.code')" = not_ready ]
    _github_age_session
    GITHUB_STORAGE_MODE=none
    run_cmd source github-rotate-key --yes
    [ "$(cmd_jq '.error.code')" = not_ready ]
    run_cmd source github-rewrap-password
    [ "$(cmd_jq '.error.code')" = not_ready ]
}

@test 'source github-import-recovery-key rejects a missing flag, a missing file and plaintext storage' {
    _github_age_session
    run_cmd source github-import-recovery-key
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd source github-import-recovery-key --file "$BATS_TEST_TMPDIR/absent.key"
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = invalid ]
    mkdir "$BATS_TEST_TMPDIR/dir.key"
    run_cmd source github-import-recovery-key --file "$BATS_TEST_TMPDIR/dir.key"
    [ "$(cmd_jq '.error.code')" = invalid ]
    GITHUB_STORAGE_MODE=none
    run_cmd source github-import-recovery-key --file "$BATS_TEST_TMPDIR/absent.key"
    [ "$(cmd_jq '.error.code')" = not_ready ]
}

# ─── node delete --scope server ──────────────────────────────────────────────

@test 'node delete --scope server uninstalls on the selected node with a 900 second SSH timeout, then drops it locally' {
    open_local_session
    REMOTE_DIR='/opt/essence scripts'
    ensure_remote_scripts_current() { return 0; }
    ssh_run() { printf '%s|%s|%s\n' "$NODE_NAME" "${SSH_RUN_TIMEOUT:-}" "$*" >> "$BATS_TEST_TMPDIR/ssh.log"; }
    run_cmd node delete --name ru-vps --scope server
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ ! -e "$BATS_TEST_TMPDIR/ssh.log" ]
    run_cmd node delete --name ru-vps --scope server --yes --plan-token "$(cmd_jq '.error.plan_token')"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/ssh.log")" = "ru-vps|900|-- bash /opt/essence\\ scripts/setup-essence.sh uninstall --force" ]
    [ "$(jq -r '[.nodes[].name] | join(",")' "$CONFIG_JSON")" = de-vps ]
}

@test 'node delete --scope server keeps the node when the remote uninstall fails' {
    open_local_session
    ensure_remote_scripts_current() { return 0; }
    ssh_run() { return 1; }
    local before
    before=$(config_snapshot)
    run_cmd node delete --name ru-vps --scope server --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ "$(config_snapshot)" = "$before" ]
}

# ─── plan_changed: устаревший токен не выполняет ни одной команды с подтверждением ─

@test 'a stale plan token answers plan_changed and changes nothing for every gated config command' {
    open_local_session
    local out="$BATS_TEST_TMPDIR/exists.yaml" before cmd
    printf 'x\n' > "$out"
    local -a gated=(
        "client set-group --name my-pc --group ROUTER"
        "client nodes --name my-pc --inherit"
        "client connections --name my-pc --node de-vps --reset"
        "node delete --name ru-vps"
        "template export --name default.yaml --output $out"
    )
    before=$(config_snapshot)
    for cmd in "${gated[@]}"; do
        # shellcheck disable=SC2086
        run_cmd $cmd
        [ "$status" -eq 2 ] || { echo "no gate: $cmd"; return 1; }
        [ "$(cmd_jq '.error.code')" = confirmation_required ] || { echo "no gate: $cmd"; return 1; }
        # shellcheck disable=SC2086
        run_cmd $cmd --yes --plan-token 0000000000000000
        [ "$status" -eq 2 ] || { echo "stale token ran: $cmd"; return 1; }
        [ "$(cmd_jq '.error.code')" = plan_changed ] || { echo "stale token ran: $cmd"; return 1; }
        [ "$(cmd_jq '.error.plan_token | length')" -gt 0 ]
        [ "$(config_snapshot)" = "$before" ] || { echo "state changed: $cmd"; return 1; }
    done
    [ "$(cat "$out")" = x ]
}

# ─── round 2: dispatch ───────────────────────────────────────────────────────

@test 'commands need an open AND authorized session (recovery authorizes without opening)' {
    open_local_session
    RC_SESSION_OPEN=0
    RC_SESSION_AUTHORIZED=1
    run_cmd group list
    [ "$status" -eq 1 ]
    [ "$(cmd_jq -r '.error.code')" = session_closed ]
    RC_SESSION_OPEN=1
    run_cmd group list
    [ "$status" -eq 0 ]
}
