#!/bin/bash
# ─── Удалённое управление setup-essence ───────────────────────────────────────
# Запускается локально. Хранит список нод, подключается по SSH и выполняет
# пункты основного скрипта setup-essence.sh. С аргументами — разовая команда
# ядра (modules/cli.sh) или serve; без аргументов — TUI (tui/main.sh), который
# сам запускает это же ядро как serve.

if (( BASH_VERSINFO[0] < 3 || ( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf '  [✗] Требуется Bash 3.2 или новее.\n' >&2
    exit 1
fi

_SELF="${BASH_SOURCE[0]}"
while [[ -L "$_SELF" ]]; do _SELF="$(readlink "$_SELF")"; done
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REMOTE_DIR="/root/essence-setup"

# Dev-режим (запуск из репо) → данные в .remote-data/ внутри remote-control/
# Installed-режим → данные в ~/.config/remote-control-essence/
if [[ -d "$SCRIPT_DIR/../.git" ]] || [[ -f "$SCRIPT_DIR/../VERSION" ]]; then
    CONFIG_DIR="$SCRIPT_DIR/.remote-data"
else
    CONFIG_DIR="$HOME/.config/remote-control-essence"
fi
CONFIG_JSON="$CONFIG_DIR/config.json"
SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
CONFIG_SOURCE="${CONFIG_SOURCE:-local}"

# ─── Подключаем общий слой до проверки зависимостей ────────────────────────────
if [[ -f "$SCRIPT_DIR/common/common.sh" ]]; then
    source "$SCRIPT_DIR/common/common.sh"
    source "$SCRIPT_DIR/common/protocols/vless-xhttp.sh"
elif [[ -f "$SCRIPT_DIR/../common/common.sh" ]]; then
    source "$SCRIPT_DIR/../common/common.sh"
    source "$SCRIPT_DIR/../common/protocols/vless-xhttp.sh"
else
    printf '  [✗] Не найден common/common.sh\n' >&2
    exit 1
fi

if [[ -f "$SCRIPT_DIR/common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/common/ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/../common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/../common/ensure-deps.sh"
else
    printf '  [✗] Не найден common/ensure-deps.sh\n' >&2
    exit 1
fi

# _startup_ensure_deps INTERACTIVE — true: предложить меню восстановления.
_startup_ensure_deps() {
    while ! ensure_dep jq openssl ssh scp base64 curl; do
        warn "Не удалось подготовить обязательные зависимости."
        [[ "${1:-false}" == true ]] || return 1
        startup_recovery_menu "Восстановление зависимостей" true || return 1
    done
}

if (( $# == 0 )); then
    _startup_ensure_deps true || exit 1
    # RC_DEPS_READY — зависимости уже проверены: serve-потомок TUI их не повторяет.
    RC_ENTRYPOINT="$SCRIPT_DIR/${_SELF##*/}" RC_DEPS_READY=1
    export RC_ENTRYPOINT RC_DEPS_READY
    exec "$BASH" "$SCRIPT_DIR/tui/main.sh"
fi

# stdout разовой команды с --json зарезервирован под один JSON-ответ.
if [[ "${RC_DEPS_READY:-}" != 1 ]] && ! _startup_ensure_deps false >&2; then
    for _rc_arg in "$@"; do
        if [[ "$_rc_arg" == --json ]]; then
            printf '%s\n' '{"ok":false,"error":{"code":"deps_missing","message":"Не удалось подготовить обязательные зависимости."}}'
            break
        fi
    done
    exit 1
fi

# ─── Подключаем модули ───────────────────────────────────────────────────────
source "$SCRIPT_DIR/modules/state.sh"
source "$SCRIPT_DIR/modules/github-config.sh"
if github_source_metadata_valid "$CONFIG_DIR/source.json"; then
    CONFIG_SOURCE=github
fi

source "$SCRIPT_DIR/modules/nodes.sh"
source "$SCRIPT_DIR/modules/ssh.sh"
source "$SCRIPT_DIR/modules/telegram-proxy.sh"
source "$SCRIPT_DIR/modules/self.sh"
source "$SCRIPT_DIR/modules/groups.sh"
source "$SCRIPT_DIR/modules/clients.sh"
source "$SCRIPT_DIR/modules/connections.sh"
source "$SCRIPT_DIR/modules/templates.sh"
source "$SCRIPT_DIR/modules/generate.sh"
source "$SCRIPT_DIR/modules/hardening.sh"
source "$SCRIPT_DIR/modules/awg_peers.sh"
source "$SCRIPT_DIR/modules/subscription.sh"
source "$SCRIPT_DIR/modules/source.sh"
source "$SCRIPT_DIR/modules/session.sh"
source "$SCRIPT_DIR/modules/cli.sh"
source "$SCRIPT_DIR/modules/serve.sh"
for _rc_module in "$SCRIPT_DIR"/modules/cmd_*.sh; do
    source "$_rc_module"
done
unset _rc_module

# ─── Пути к setup-essence, common и VERSION (dev / installed) ─────────────────
SETUP_DIR=""
if [[ -d "$SCRIPT_DIR/setup-essence" ]]; then
    SETUP_DIR="$SCRIPT_DIR/setup-essence"
elif [[ -d "$SCRIPT_DIR/../setup-essence" ]]; then
    SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-essence" && pwd)"
fi

COMMON_DIR=""
if [[ -d "$SCRIPT_DIR/common" ]]; then
    COMMON_DIR="$SCRIPT_DIR/common"
elif [[ -d "$SCRIPT_DIR/../common" ]]; then
    COMMON_DIR="$(cd "$SCRIPT_DIR/../common" && pwd)"
fi

VERSION_PATH=""
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    VERSION_PATH="$SCRIPT_DIR/VERSION"
elif [[ -f "$SCRIPT_DIR/../VERSION" ]]; then
    VERSION_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/VERSION"
fi

# ─── Текущая версия ─────────────────────────────────────────────────────────
CURRENT_VERSION="0.0.0"
[[ -n "$VERSION_PATH" && -f "$VERSION_PATH" ]] && CURRENT_VERSION=$(tr -d '\r' < "$VERSION_PATH")

# ─── Текущая нода (глобальные переменные) ────────────────────────────────────
NODE_NAME=""

# ─── Разовая команда или serve ───────────────────────────────────────────────
# Одной строкой: self update перезаписывает этот файл на месте, и bash не должен
# дочитывать новое содержимое после возврата из cli_main.
cli_main "$@"; exit $?
