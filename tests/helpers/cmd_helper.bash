#!/bin/bash
# ─── Тесты команд ядра: rc_dispatch в текущем shell ──────────────────────────
# Подключение: load '../helpers/test_helper'; setup_test_env;
# load '../helpers/cmd_helper'; load_core; затем при необходимости
# load '../helpers/mock_ssh' (после load_core — моки перекрывают ssh.sh).
# Секреты команды задаются переменной RC_REQUEST_SECRETS перед run_cmd.

# Модули ядра в порядке entrypoint.
load_core() {
    local module
    source_common
    source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
    source "$PROJECT_ROOT/common/ensure-deps.sh"
    for module in state github-config nodes ssh telegram-proxy self groups clients \
        connections templates generate hardening awg_peers subscription source session cli serve; do
        source "$PROJECT_ROOT/remote-control/modules/$module.sh"
    done
    for module in "$PROJECT_ROOT"/remote-control/modules/cmd_*.sh; do
        source "$module"
    done
    CURRENT_VERSION=$(tr -d '\r' < "$PROJECT_ROOT/VERSION")
}

# Локальная конфигурация в CONFIG_DIR и открытая авторизованная сессия.
open_local_session() {
    state_open_local || return 1
    CONFIG_SOURCE=local
    RC_SESSION_OPEN=1
    RC_SESSION_AUTHORIZED=1
}

# run_cmd ARGV… → status (RC_EXIT_CODE), output (журнал), CMD_ENVELOPE.
# Без подоболочки: вызовы моков (SSH_RUN_CALLS) и глобалы сохраняются.
run_cmd() {
    local __run_cmd_log="$BATS_TEST_TMPDIR/cmd.log"
    rc_dispatch "$@" > "$__run_cmd_log" 2>&1 || true
    status=$RC_EXIT_CODE
    output=$(cat "$__run_cmd_log")
    CMD_ENVELOPE=$RC_ENVELOPE
}

# cmd_jq FILTER… — jq -r по конверту последней команды.
cmd_jq() {
    printf '%s' "$CMD_ENVELOPE" | jq -r "$@"
}
