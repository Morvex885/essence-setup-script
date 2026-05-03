#!/bin/bash

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "  ${CYAN}[*]${NC} $*"; }
success() { echo -e "  ${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
error()   { echo -e "  ${RED}[✗]${NC} $*"; exit 1; }

# Кликабельная ссылка через OSC 8. Поддерживается современными терминалами
# (Windows Terminal, iTerm2, VS Code, GNOME Terminal, kitty). В неподдерживающих
# терминалах escape-последовательности игнорируются и виден только текст.
# hyperlink URL [TEXT] — если TEXT не задан, используется URL.
hyperlink() {
    local url="$1"
    local text="${2:-$1}"
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$text"
}

# ─── Y/N подтверждение с валидацией ─────────────────────────────────────────
# confirm_yn "Текст вопроса" [Y|N]
# Второй аргумент — дефолт (Y или N). По умолчанию N.
# Возвращает 0 (yes) или 1 (no).
confirm_yn() {
    local prompt="$1"
    local default="${2:-N}"
    local hint="y/N"
    [[ "$default" =~ ^[Yy]$ ]] && hint="Y/n"

    while true; do
        read -rp "  ${prompt} [${hint}]: " _answer
        _answer="${_answer:-$default}"
        case "$_answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) warn "Введите y или n." ;;
        esac
    done
}

# ─── Ожидание apt lock ──────────────────────────────────────────────────────
_apt_lock_menu() {
    while true; do
        echo ""
        warn "apt lock не освободился за 60с"
        echo -e "  ${CYAN}Процессы, блокирующие apt:${NC}"
        local pids
        pids=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null)
        for pid in $pids; do
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "???")
            echo -e "    PID ${YELLOW}${pid}${NC}  ${pname}"
        done
        echo ""
        echo -e "  ${GREEN}1)${NC} Завершить процесс и продолжить"
        echo -e "  ${CYAN}2)${NC} Подождать ещё 60с"
        echo -e "  ${RED}3)${NC} Прервать установку"
        echo ""
        read -rp "  Выберите: " _choice
        case "$_choice" in
            1)
                for pid in $pids; do
                    local pname
                    pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "???")
                    if confirm_yn "Завершить процесс ${pname} (PID ${pid})?"; then
                        kill "$pid" 2>/dev/null
                        sleep 3
                        if kill -0 "$pid" 2>/dev/null; then
                            warn "Процесс не завершился, отправляю SIGKILL..."
                            kill -9 "$pid" 2>/dev/null
                            sleep 2
                        fi
                    fi
                done
                if ! fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
                    success "apt lock освобождён"
                    return 0
                fi
                warn "Lock всё ещё занят"
                ;;
            2) return 0 ;;
            3) error "Установка прервана пользователем." ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

apt_wait() {
    local max_wait=60 waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        if [[ $waited -eq 0 ]]; then
            info "Ожидаю завершения другого процесса apt..."
        fi
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge $max_wait ]]; then
            _apt_lock_menu
            waited=0
        fi
    done
}

# ─── Порты ──────────────────────────────────────────────────────────────────

# Проверить свободен ли порт
is_port_free() {
    local port="$1"
    ! ss -tulpn 2>/dev/null | awk '{print $5}' | grep -qE ":${port}$"
}

# Сгенерировать свободный случайный порт в диапазоне [min, max]
gen_free_port() {
    local min="$1" max="$2"
    local range=$((max - min + 1))
    local port
    for _ in $(seq 1 100); do
        port=$((RANDOM % range + min))
        is_port_free "$port" && echo "$port" && return 0
    done
    error "Не удалось найти свободный порт в диапазоне ${min}-${max}"
    return 1
}

# ─── JSON-конфиг (jq) ───────────────────────────────────────────────────────

_ensure_config() {
    mkdir -p "$(dirname "$CONFIG_JSON")"
    [[ -f "$CONFIG_JSON" ]] || echo '{"nodes":[],"groups":[{"name":"ROUTER","template":"default.yaml"},{"name":"PC","template":"default.yaml"},{"name":"MOBILE","template":"default.yaml"}],"clients":[],"connections":[]}' > "$CONFIG_JSON"
}

jq_r() { jq -r "$@" "$CONFIG_JSON" | tr -d '\r'; }

jq_w() {
    local tmp="${CONFIG_JSON}.tmp.$$"
    if ! jq "$@" "$CONFIG_JSON" > "$tmp"; then
        rm -f "$tmp"
        warn "Не удалось обновить конфиг (jq error)"
        return 1
    fi
    mv "$tmp" "$CONFIG_JSON"
}

# ─── Рамка меню ─────────────────────────────────────────────────────────────
BOX_W=42
box_top() { echo -e "${CYAN}╔$(printf '═%.0s' $(seq 1 $BOX_W))╗${NC}"; }
box_mid() { echo -e "${CYAN}╠$(printf '═%.0s' $(seq 1 $BOX_W))╣${NC}"; }
box_bot() { echo -e "${CYAN}╚$(printf '═%.0s' $(seq 1 $BOX_W))╝${NC}"; }

# Печатает строку внутри рамки с правильным паддингом.
# $1 = видимый текст (без ANSI-кодов) — для подсчёта длины
# $2 = цветной текст (с ANSI-кодами) — для вывода (необязательно)
# Возвращает кол-во символов (не байтов), корректно для кириллицы/UTF-8
# Длина строки в символах (UTF-8, не зависит от локали)
# Считает байты через od, исключая continuation-байты (0x80-0xBF)
_vis_len() {
    local count
    count=$(printf '%s' "$1" | od -An -tx1 | tr -s '[:space:]' '\n' | grep -c '^[0-7c-f]' || true)
    echo "${count:-0}"
}

box_line() {
    local visible="$1"
    local colored="${2:-$1}"
    local pad=$((BOX_W - $(_vis_len "$visible")))
    (( pad < 0 )) && pad=0
    printf "${CYAN}║${NC}%b%*s${CYAN}║${NC}\n" "$colored" "$pad" ""
}

# Печатает строку по центру внутри рамки.
# $1 = видимый текст, $2 = цветной текст (необязательно)
box_center() {
    local visible="$1"
    local colored="${2:-$1}"
    local total=$((BOX_W - $(_vis_len "$visible")))
    (( total < 0 )) && total=0
    local lpad=$((total / 2))
    local rpad=$((total - lpad))
    printf "${CYAN}║${NC}%*s%b%*s${CYAN}║${NC}\n" "$lpad" "" "$colored" "$rpad" ""
}

# ─── Рамка успеха (зелёная, широкая) ────────────────────────────────────────
SUCCESS_BOX_W=58
success_box() {
    local text="$1"
    echo -e "${GREEN}╔$(printf '═%.0s' $(seq 1 $SUCCESS_BOX_W))╗${NC}"
    local total=$((SUCCESS_BOX_W - $(_vis_len "$text")))
    (( total < 0 )) && total=0
    local lpad=$((total / 2))
    local rpad=$((total - lpad))
    printf "${GREEN}║%*s%s%*s║${NC}\n" "$lpad" "" "$text" "$rpad" ""
    echo -e "${GREEN}╚$(printf '═%.0s' $(seq 1 $SUCCESS_BOX_W))╝${NC}"
}

# ─── Toggle-выбор ───────────────────────────────────────────────────────────
# toggle_select <header> <items_array_name> <flags_array_name>
# Модифицирует flags_array на месте. Каждый флаг 0 или 1.
toggle_select() {
    local header="$1"
    local -n _ts_items=$2
    local -n _ts_flags=$3
    while true; do
        echo ""
        echo -e "  $header:"
        local i=1
        for item in "${_ts_items[@]}"; do
            if [[ "${_ts_flags[$((i-1))]}" == "1" ]]; then
                echo -e "  ${GREEN}${i})${NC} [x] $item"
            else
                echo -e "  ${GREEN}${i})${NC} [ ] $item"
            fi
            i=$((i + 1))
        done
        echo ""
        read -rp "Переключить (номер) или Enter для сохранения: " TOGGLE
        [[ -z "$TOGGLE" ]] && break
        if [[ "$TOGGLE" =~ ^[0-9]+$ ]] && (( TOGGLE >= 1 && TOGGLE <= ${#_ts_items[@]} )); then
            local idx=$((TOGGLE - 1))
            [[ "${_ts_flags[$idx]}" == "1" ]] && _ts_flags[$idx]=0 || _ts_flags[$idx]=1
        else
            warn "Неверный номер."
        fi
    done
}

# ─── Проверка обновлений (фоновая) ───────────────────────────────────────────
_REPO="Morvex885/essence-setup-script"
_UPDATE_TMP=""

check_update_start() {
    _UPDATE_TMP=$(mktemp)
    trap 'rm -f "$_UPDATE_TMP"' EXIT
    local token="${GITHUB_TOKEN:-}"
    local curl_args=(-fsSL --connect-timeout 3 --max-time 5)
    [[ -n "$token" ]] && curl_args+=(-H "Authorization: token $token")
    (
        curl "${curl_args[@]}" \
            "https://api.github.com/repos/${_REPO}/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' \
        | grep -o '"[^"]*"$' \
        | tr -d '"' > "$_UPDATE_TMP"
    ) &
}

# Возвращает тег последней версии (пусто если ещё не готово или ошибка)
latest_version() {
    [[ -n "${_UPDATE_TMP:-}" && -s "$_UPDATE_TMP" ]] && cat "$_UPDATE_TMP" || echo ""
}

# Сравнивает semver: возвращает 0 если a > b
_ver_gt() {
    local a="$1" b="$2"
    local a_major a_minor a_patch b_major b_minor b_patch
    IFS='.' read -r a_major a_minor a_patch <<< "$a"
    IFS='.' read -r b_major b_minor b_patch <<< "$b"
    a_major="${a_major:-0}"; a_minor="${a_minor:-0}"; a_patch="${a_patch:-0}"
    b_major="${b_major:-0}"; b_minor="${b_minor:-0}"; b_patch="${b_patch:-0}"
    (( a_major > b_major )) && return 0
    (( a_major < b_major )) && return 1
    (( a_minor > b_minor )) && return 0
    (( a_minor < b_minor )) && return 1
    (( a_patch > b_patch )) && return 0
    return 1
}

# Возвращает 0 если версия current устарела
has_update() {
    local current="$1" latest latest_clean current_clean
    [[ "$current" == "none" ]] && return 1
    latest=$(latest_version)
    latest_clean="${latest#v}"
    current_clean="${current#v}"
    [[ -z "$latest_clean" ]] && return 1
    _ver_gt "$latest_clean" "$current_clean"
}
