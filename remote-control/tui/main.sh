#!/bin/bash
# ─── Процесс TUI remote-control ──────────────────────────────────────────────
# Запускает serve дочерним процессом и общается с ним по протоколу JSON-строк.
# Подключает только common/common.sh и соседние tui/*.sh; модули ядра сюда
# не попадают. RC_ENTRYPOINT — путь к remote-control-essence.sh (задаёт bootstrap).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Installed-layout: common/ рядом с tui/; dev-режим: common/ в корне репозитория.
if [[ -f "$SCRIPT_DIR/common/common.sh" ]]; then
    source "$SCRIPT_DIR/common/common.sh"
else
    source "$SCRIPT_DIR/../common/common.sh"
fi
for tui_file in "$SCRIPT_DIR"/tui/*.sh; do
    [[ "${tui_file##*/}" == main.sh ]] && continue
    source "$tui_file"
done
unset tui_file

# Ctrl+C в меню закрывает сессию: выход с кодом 130, очистку делает exit-cleanup.
tui_on_int() {
    echo ""
    exit 130
}

tui_main() {
    trap 'tui_on_int' INT
    tui_serve_start
    local startup_rc=0
    tui_startup || startup_rc=$?
    # 2 — пользователь выбрал «Выход» на первом запуске: это не ошибка.
    (( startup_rc == 0 )) || exit $(( startup_rc == 2 ? 0 : 1 ))
    tui_dashboard
    exit 0
}

# Одной строкой: self update перезаписывает tui/*.sh на месте.
tui_main; exit $?
