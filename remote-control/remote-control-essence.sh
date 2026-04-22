#!/bin/bash
# ─── Удалённое управление setup-essence ───────────────────────────────────────
# Запускается локально. Хранит список нод, подключается по SSH и выполняет
# пункты основного скрипта setup-essence.sh в интерактивном режиме.

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

# ─── Авто-установка зависимостей (jq, openssl, ssh) ──────────────────────────
if [[ -f "$SCRIPT_DIR/common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/common/ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/../common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/../common/ensure-deps.sh"
else
    echo "  [✗] Не найден common/ensure-deps.sh" >&2; exit 1
fi
ensure_dep jq openssl ssh

# ─── Подключаем модули ───────────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/common/common.sh" ]]; then
    source "$SCRIPT_DIR/common/common.sh"
elif [[ -f "$SCRIPT_DIR/../common/common.sh" ]]; then
    source "$SCRIPT_DIR/../common/common.sh"
fi
source "$SCRIPT_DIR/modules/nodes.sh"
source "$SCRIPT_DIR/modules/ssh.sh"
source "$SCRIPT_DIR/modules/self.sh"
source "$SCRIPT_DIR/modules/groups.sh"
source "$SCRIPT_DIR/modules/clients.sh"
source "$SCRIPT_DIR/modules/connections.sh"
source "$SCRIPT_DIR/modules/templates.sh"
source "$SCRIPT_DIR/modules/generate.sh"
source "$SCRIPT_DIR/modules/hardening.sh"
source "$SCRIPT_DIR/modules/awg_peers.sh"
source "$SCRIPT_DIR/modules/subscription.sh"

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
CURRENT_VERSION="none"
[[ -n "$VERSION_PATH" && -f "$VERSION_PATH" ]] && CURRENT_VERSION=$(tr -d '\r' < "$VERSION_PATH")

# ─── Текущая нода (глобальные переменные) ────────────────────────────────────
NODE_NAME=""
SERVER_IP=""
SERVER_PORT=""
SERVER_USER=""
SERVER_PASS=""
SERVER_AUTH=""  # "key" или "password"

# ─── Меню выбора ноды ─────────────────────────────────────────────────────────
menu_nodes() {
    while true; do
        local count
        count=$(nodes_count)

        local latest
        latest=$(latest_version)

        echo ""
        box_top
        box_center "Essence Remote Management"
        local _ver="версия: ${CURRENT_VERSION}"
        box_center "$_ver" "${DIM}${_ver}${NC}"
        if has_update "$CURRENT_VERSION"; then
            local _upd="↑ ${latest} — нажмите U"
            box_center "$_upd" "${YELLOW}↑ ${latest} — нажмите U${NC}"
        fi
        box_mid
        if [[ $count -eq 0 ]]; then
            box_line " (нод нет — добавьте первую)" " ${DIM}(нод нет — добавьте первую)${NC}"
        else
            local _num=1
            while IFS=$'\t' read -r _name _addr _tag; do
                local _tag_plain="" _tag_color=""
                [[ -n "$_tag" ]] && { _tag_plain=" [${_tag}]"; _tag_color=" ${DIM}[${_tag}]${NC}"; }
                box_line " ${_num}) ${_name}  ${_addr}${_tag_plain}" " ${GREEN}${_num})${NC} ${_name}  ${_addr}${_tag_color}"
                _num=$((_num + 1))
            done < <(jq_r '.nodes[] | "\(.name)\t\(.ip):\(.port)\t\(.tag // "")"')
        fi
        box_mid
        box_line " a) Добавить ноду" " ${GREEN}a)${NC} Добавить ноду"
        if [[ $count -gt 0 ]]; then
            box_line " n) Переименовать ноду" " ${YELLOW}n)${NC} Переименовать ноду"
            box_line " t) Тег ноды" " ${YELLOW}t)${NC} Тег ноды"
            box_line " d) Удалить ноду" " ${RED}d)${NC} Удалить ноду"
        fi
        box_mid
        box_line " C) Клиенты" " ${CYAN}C)${NC} Клиенты"
        box_line " G) Группы" " ${YELLOW}G)${NC} Группы"
        box_mid
        box_line " P) Подключения нод для групп" " ${YELLOW}P)${NC} Подключения нод для групп"
        box_line " W) AWG подключения" " ${CYAN}W)${NC} AWG подключения"
        box_mid
        box_line " F) Сгенерировать конфиги" " ${GREEN}F)${NC} Сгенерировать конфиги"
        box_line " S) Подписки (Subscriptions)" " ${GREEN}S)${NC} Подписки (Subscriptions)"
        box_mid
        box_line " U) Обновить скрипт" " ${CYAN}U)${NC} Обновить скрипт"
        box_line " L) Пароль скрипта" " ${YELLOW}L)${NC} Пароль скрипта"
        box_line " R) Удалить remote-control" " ${RED}R)${NC} Удалить remote-control"
        box_line " 0) Выход"
        box_bot
        echo ""
        read -rp "  Выберите ноду или действие: " _pick

        if [[ "$_pick" == "0" ]]; then
            echo ""; echo "  Выход."; exit 0
        elif [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= count )); then
            node_load "$_pick"
            menu_operations
        elif [[ "$_pick" == "a" || "$_pick" == "A" ]]; then
            add_node
        elif [[ $count -gt 0 ]] && [[ "$_pick" == "d" || "$_pick" == "D" ]]; then
            delete_node
        elif [[ $count -gt 0 ]] && [[ "$_pick" == "n" || "$_pick" == "N" ]]; then
            rename_node
        elif [[ $count -gt 0 ]] && [[ "$_pick" == "t" || "$_pick" == "T" ]]; then
            set_node_tag
        elif [[ "$_pick" == "C" || "$_pick" == "c" ]]; then
            clients_menu
        elif [[ "$_pick" == "P" || "$_pick" == "p" ]]; then
            connections_menu
        elif [[ "$_pick" == "G" || "$_pick" == "g" ]]; then
            groups_menu
        elif [[ "$_pick" == "F" || "$_pick" == "f" ]]; then
            generate_menu
        elif [[ "$_pick" == "W" || "$_pick" == "w" ]]; then
            awg_peers_menu
        elif [[ "$_pick" == "S" || "$_pick" == "s" ]]; then
            subscription_menu
        elif [[ "$_pick" == "U" || "$_pick" == "u" ]]; then
            self_update
        elif [[ "$_pick" == "L" || "$_pick" == "l" ]]; then
            set_script_password
        elif [[ "$_pick" == "R" || "$_pick" == "r" ]]; then
            uninstall_self
        else
            warn "Неверный выбор."
        fi
    done
}

# ─── Меню операций (для выбранной ноды) ──────────────────────────────────────
menu_operations() {
    # Проверяем соединение и загружаем скрипты при первом входе
    echo ""
    ssh_connect || return
    upload_scripts

    while true; do
        echo ""
        box_top
        local _node="${NODE_NAME}  (${SERVER_IP})"
        box_center "$_node" "${GREEN}${_node}${NC}"
        box_mid
        box_line " 1) Открыть меню сервера" " ${GREEN}1)${NC} Открыть меню сервера"
        box_mid
        box_line " h) Настройка SSH ключа на ноде" " ${YELLOW}h)${NC} Настройка SSH ключа на ноде"
        box_line " u) Обновить скрипты на сервере" " ${CYAN}u)${NC} Обновить скрипты на сервере"
        box_line " 0) Назад"
        box_bot
        echo ""
        read -rp "  Выберите пункт: " CHOICE

        case "$CHOICE" in
            1)
                run_remote
                echo ""
                echo -e "  ${DIM}── SSH-сессия завершена ──────────────────${NC}"
                confirm_yn "Продолжить работу с ${NODE_NAME}?" Y || return
                ;;
            h|H)        ssh_hardening ;;
            u|U)        upload_scripts ;;
            0)          return ;;
            *)          warn "Неверный выбор: $CHOICE" ;;
        esac
    done
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
check_deps
check_script_password
menu_nodes
