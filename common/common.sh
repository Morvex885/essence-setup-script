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

# Компонуемый EXIT cleanup для процессов, которые используют несколько модулей.
_EXIT_CLEANUP_FUNCTIONS=()
_run_exit_cleanups() {
    local exit_status=$? i cleanup
    trap - EXIT
    for ((i = ${#_EXIT_CLEANUP_FUNCTIONS[@]} - 1; i >= 0; i--)); do
        cleanup="${_EXIT_CLEANUP_FUNCTIONS[$i]}"
        "$cleanup" >/dev/null 2>&1 || true
    done
    return "$exit_status"
}

register_exit_cleanup() {
    local cleanup="$1" existing
    declare -F "$cleanup" >/dev/null 2>&1 || return 1
    for existing in "${_EXIT_CLEANUP_FUNCTIONS[@]}"; do
        [[ "$existing" == "$cleanup" ]] && return 0
    done
    _EXIT_CLEANUP_FUNCTIONS+=("$cleanup")
    trap _run_exit_cleanups EXIT
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
        if ! IFS= read -rp "  ${prompt} [${hint}]: " _answer; then
            return 1
        fi
        _answer="${_answer%$'\r'}"
        [[ -z "$_answer" ]] && _answer="$default"
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
        local pids
        pids=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null)
        box_top
        box_center "Ожидание apt"
        box_mid
        box_line " Процессы, блокирующие apt:"
        if [[ -n "$pids" ]]; then
            local pid pname
            for pid in $pids; do
                pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "???")
                box_line "    PID ${pid}  ${pname}"
            done
        else
            box_line " Процессы не определены" " ${DIM}Процессы не определены${NC}"
        fi
        box_mid
        menu_item 1 "Завершить процесс и продолжить" GREEN
        menu_item 2 "Подождать ещё 60с" CYAN
        menu_item 3 "Прервать установку" RED
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " _choice; then
            return 1
        fi
        _choice="${_choice%$'\r'}"
        case "$_choice" in
            1)
                local pid pname
                for pid in $pids; do
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
            3) warn "Установка прервана пользователем."; return 1 ;;
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
            _apt_lock_menu || return 1
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

gen_free_port() {
    local min="$1" max="$2"
    local range=$((max - min + 1))
    local port
    for _ in $(seq 1 100); do
        port=$((RANDOM % range + min))
        is_port_free "$port" && echo "$port" && return 0
    done
    warn "Не удалось найти свободный порт в диапазоне ${min}-${max}" >&2
    return 1
}

# Ограниченный по времени запуск с fallback для macOS без coreutils timeout.
run_with_timeout() {
    local seconds="$1"
    shift
    local timeout_help
    if command -v timeout >/dev/null 2>&1; then
        timeout_help=$(timeout --help 2>&1)
        if [[ "$timeout_help" == *--foreground* ]]; then
            timeout --foreground --signal=TERM --kill-after=5 "$seconds" "$@"
        else
            timeout "$seconds" "$@"
        fi
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout --foreground --signal=TERM --kill-after=5 "$seconds" "$@"
        return $?
    fi
    "$@" &
    local child=$! watcher rc
    ( sleep "$seconds"; kill "$child" 2>/dev/null ) >/dev/null 2>&1 &
    watcher=$!
    wait "$child"
    rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    return "$rc"
}

# ─── JSON-конфиг (jq) ───────────────────────────────────────────────────────

_ensure_config() {
    mkdir -p "$(dirname "$CONFIG_JSON")"
    [[ -f "$CONFIG_JSON" ]] && return 0
    local tmp
    tmp=$(umask 077; mktemp "${CONFIG_JSON}.tmp.XXXXXX") || return 1
    cat > "$tmp" <<'EOF'
{"schema_version":2,"nodes":[],"groups":[{"name":"ROUTER","template":"default.yaml"},{"name":"PC","template":"default.yaml"},{"name":"MOBILE","template":"default.yaml"}],"clients":[],"connections":[]}
EOF
    chmod 600 "$tmp" && mv "$tmp" "$CONFIG_JSON" || {
        rm -f "$tmp"
        return 1
    }
}

jq_r() { jq -r "$@" "$CONFIG_JSON" | tr -d '\r'; }

jq_w() {
    local tmp
    CONFIG_PERSIST_LAST_ERROR=""
    tmp=$(umask 077; mktemp "${CONFIG_JSON}.tmp.XXXXXX") || return 1
    if ! jq "$@" "$CONFIG_JSON" > "$tmp"; then
        rm -f "$tmp"
        CONFIG_PERSIST_LAST_ERROR="Не удалось обновить конфиг (jq error)"
        warn "$CONFIG_PERSIST_LAST_ERROR"
        return 1
    fi
    if declare -F config_persist_candidate >/dev/null 2>&1; then
        if ! config_persist_candidate "$tmp"; then
            rm -f "$tmp"
            CONFIG_PERSIST_LAST_ERROR="${CONFIG_PERSIST_LAST_ERROR:-Не удалось сохранить представление конфига}"
            warn "$CONFIG_PERSIST_LAST_ERROR"
            return 1
        fi
        return 0
    fi
    if ! mv "$tmp" "$CONFIG_JSON"; then
        rm -f "$tmp"
        CONFIG_PERSIST_LAST_ERROR="Не удалось заменить конфиг"
        warn "$CONFIG_PERSIST_LAST_ERROR"
        return 1
    fi
}

# ─── Рамка меню ─────────────────────────────────────────────────────────────
BOX_W=68
box_top() { echo -e "${CYAN}╔$(printf '═%.0s' $(seq 1 $BOX_W))╗${NC}"; }
box_mid() { echo -e "${CYAN}╠$(printf '═%.0s' $(seq 1 $BOX_W))╣${NC}"; }
box_bot() { echo -e "${CYAN}╚$(printf '═%.0s' $(seq 1 $BOX_W))╝${NC}"; }

_vis_len() {
    local count
    count=$(printf '%s' "$1" | od -An -tx1 | tr -s '[:space:]' '\n' | grep -c '^[0-7c-f]' || true)
    echo "${count:-0}"
}

menu_item() {
    local key="$1"
    local label="$2"
    local color="${3:-CYAN}"
    local color_value="${!color}"
    box_line " ${key}) ${label}" " ${color_value}${key})${NC} ${label}"
}

menu_index_valid() {
    local value="$1"
    local count="$2"
    local value_len count_len
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
    value_len=${#value}
    count_len=${#count}
    (( value_len < count_len )) && return 0
    (( value_len > count_len )) && return 1
    [[ "$value" < "$count" || "$value" == "$count" ]]
}

startup_recovery_menu() {
    local title="$1"
    local allow_retry="${2:-true}"
    while true; do
        echo ""
        box_top
        box_center "Восстановление запуска"
        box_mid
        box_line " ${title}"
        if [[ "$allow_retry" == true ]]; then
            menu_item 1 "Повторить" GREEN
        fi
        menu_item 0 "Выход" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " _recovery_choice; then
            return 1
        fi
        _recovery_choice="${_recovery_choice%$'\r'}"
        if [[ "$allow_retry" == true && "$_recovery_choice" == 1 ]]; then
            return 0
        fi
        [[ "$_recovery_choice" == 0 ]] && return 1
        warn "Неверный выбор."
    done
}

_box_wrap_emit() {
    local content="$1"
    local alignment="$2"
    local visible_count="$3"
    local total=$((BOX_W - visible_count))
    (( total < 0 )) && total=0
    local left=0 right="$total"
    if [[ "$alignment" == center ]]; then
        left=$((total / 2))
        right=$((total - left))
    fi
    local close=""
    [[ -n "$osc" ]] && close=$'\033]8;;\033\\'
    [[ -n "$sgr" ]] && close="${close}"$'\033[0m'
    printf '%b%*s%s%s%*s%b\n' \
        "${CYAN}║${NC}" "$left" "" "$content" "$close" \
        "$right" "" "${CYAN}║${NC}"
}
_box_wrap() {
    local styled="$1"
    local alignment="${2:-left}"
    local LC_ALL=C
    local decoded
    printf -v decoded '%b' "$styled"
    local ESC=$'\033' BEL=$'\a'
    local i=0 n=${#decoded} byte token rest params uri hex char next_hex max_bytes j
    local line="" line_len=0
    local sgr="" osc="" line_sgr="" line_osc=""
    local had_line=false
    _box_wrap_newline() {
        line="$line_sgr$line_osc"
        line_len=0
        line_sgr="$sgr"
        line_osc="$osc"
    }
    _box_wrap_flush() {
        _box_wrap_emit "$line" "$alignment" "$line_len"
        line=""
        line_len=0
        line_sgr="$sgr"
        line_osc="$osc"
        had_line=true
    }
    _box_wrap_newline
    while (( i < n )); do
        byte="${decoded:i:1}"
        if [[ "$byte" == "$ESC" ]]; then
            token="$byte"
            if [[ "${decoded:i+1:1}" == "[" ]]; then
                token+="${decoded:i+1:1}"
                i=$((i + 2))
                while (( i < n )); do
                    byte="${decoded:i:1}"
                    token+="$byte"
                    i=$((i + 1))
                    [[ "$byte" == m ]] && break
                done
                if [[ "$token" == *m ]]; then
                    line+="$token"
                    rest="${token#$ESC[}"
                    rest="${rest%m}"
                    if [[ -z "$rest" || "$rest" == "0" ]]; then
                        sgr=""
                    elif [[ "$rest" == "0;"* ]]; then
                        sgr="$token"
                    else
                        sgr="${sgr}${token}"
                    fi
                    continue
                fi
                line+="^["
                i=$((i - ${#token} + 1))
                line_len=$((line_len + 1))
            elif [[ "${decoded:i+1:1}" == "]" && "${decoded:i+2:2}" == "8;" ]]; then
                token+="${decoded:i+1:1}${decoded:i+2:2}"
                i=$((i + 4))
                while (( i < n )); do
                    byte="${decoded:i:1}"
                    token+="$byte"
                    i=$((i + 1))
                    [[ "$byte" == "$BEL" ]] && break
                    if [[ "$byte" == "$ESC" && "${decoded:i:1}" == "\\" ]]; then
                        token+="\\"
                        i=$((i + 1))
                        break
                    fi
                done
                if [[ "$token" == *"$BEL" || "$token" == *"$ESC\\" ]]; then
                    line+="$token"
                    rest="${token#$ESC]8;}"
                    if [[ "$rest" == *"$BEL" ]]; then
                        rest="${rest%$BEL}"
                    else
                        rest="${rest%$ESC\\}"
                    fi
                    params="${rest%%;*}"
                    uri="${rest#*;}"
                    if [[ -n "$uri" ]]; then
                        osc="$token"
                    else
                        osc=""
                    fi
                    continue
                fi
                line+="^["
                i=$((i - ${#token} + 1))
                line_len=$((line_len + 1))
                continue
            else
                line+="^["
                i=$((i + 1))
                line_len=$((line_len + 1))
                continue
            fi
        fi
        if [[ "$byte" == $'\n' ]]; then
            _box_wrap_flush
            i=$((i + 1))
            _box_wrap_newline
            continue
        fi
        if (( line_len >= BOX_W )); then
            _box_wrap_flush
            _box_wrap_newline
        fi
        char="$byte"
        max_bytes=0
        hex=$(printf '%s' "$byte" | LC_ALL=C od -An -t x1 | tr -d ' \n')
        case "$hex" in
            C[2-9A-Fa-f]|c[2-9a-f]|D[0-3]|d[0-3]) max_bytes=1 ;;
            E[0-9A-Fa-f]|e[0-9a-f]) max_bytes=2 ;;
            F[0-4]|f[0-4]) max_bytes=3 ;;
        esac
        j=1
        while (( j <= max_bytes && i + j < n )); do
            next_hex=""
            next_hex=$(printf '%s' "${decoded:i+j:1}" | LC_ALL=C od -An -t x1 | tr -d ' \n')
            [[ "$next_hex" == [89ABabCDEFdef][0-9A-Fa-f] ]] || break
            char+="${decoded:i+j:1}"
            j=$((j + 1))
        done
        line+="$char"
        line_len=$((line_len + 1))
        i=$((i + j))
    done
    if [[ -n "$line" || "$had_line" == false ]]; then
        _box_wrap_emit "$line" "$alignment" "$line_len"
    fi
}

box_line() {
    local visible="$1"
    local colored="${2:-$1}"
    if [[ "$visible" != *$'\n'* ]] && (( $(_vis_len "$visible") <= BOX_W )); then
        local pad=$((BOX_W - $(_vis_len "$visible")))
        printf "${CYAN}║${NC}%b%*s${CYAN}║${NC}\n" "$colored" "$pad" ""
    else
        _box_wrap "$colored" left
    fi
}

box_center() {
    local visible="$1"
    local colored="${2:-$1}"
    if [[ "$visible" != *$'\n'* ]] && (( $(_vis_len "$visible") <= BOX_W )); then
        local total=$((BOX_W - $(_vis_len "$visible")))
        local lpad=$((total / 2))
        local rpad=$((total - lpad))
        printf "${CYAN}║${NC}%*s%b%*s${CYAN}║${NC}\n" "$lpad" "" "$colored" "$rpad" ""
    else
        _box_wrap "$colored" center
    fi
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

# Проверить наличие элемента в индексированном массиве.
# array_contains <needle> <array elements...>
array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ─── Toggle-выбор ───────────────────────────────────────────────────────────
# toggle_select <header>
# Массивы TOGGLE_SELECT_ITEMS и TOGGLE_SELECT_FLAGS задаются вызывающим кодом
# заранее. Флаги модифицируются на месте; каждый флаг — 0 или 1.
TOGGLE_SELECT_ITEMS=()
TOGGLE_SELECT_FLAGS=()
toggle_select() {
    local header="$1"
    local i item choice
    ((${#TOGGLE_SELECT_ITEMS[@]} > 0)) || {
        echo ""
        box_top
        box_center "$header"
        box_mid
        box_line " Нет вариантов для выбора" " ${DIM}Нет вариантов для выбора${NC}"
        menu_item 0 "Отмена" NC
        box_bot
        return 1
    }
    while true; do
        echo ""
        box_top
        box_center "$header"
        box_mid
        i=0
        while [[ $i -lt ${#TOGGLE_SELECT_ITEMS[@]} ]]; do
            item="${TOGGLE_SELECT_ITEMS[$i]}"
            if [[ "${TOGGLE_SELECT_FLAGS[$i]}" == "1" ]]; then
                box_line " $((i + 1))) [x] ${item}" " ${GREEN}$((i + 1)))${NC} [x] ${item}"
            else
                box_line " $((i + 1))) [ ] ${item}" " ${GREEN}$((i + 1)))${NC} [ ] ${item}"
            fi
            i=$((i + 1))
        done
        box_mid
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Переключить номер [Enter = сохранить, 0 = отмена]: " choice; then
            return 1
        fi
        choice="${choice%$'\r'}"
        [[ -z "$choice" ]] && return 0
        [[ "$choice" == 0 ]] && return 1
        if menu_index_valid "$choice" "${#TOGGLE_SELECT_ITEMS[@]}"; then
            i=$((choice - 1))
            [[ "${TOGGLE_SELECT_FLAGS[$i]}" == "1" ]] && TOGGLE_SELECT_FLAGS[$i]=0 || TOGGLE_SELECT_FLAGS[$i]=1
        else
            warn "Неверный номер."
        fi
    done
}

# ─── Проверка обновлений (фоновая) ───────────────────────────────────────────
_REPO="Morvex885/essence-setup-script"
_UPDATE_TMP=""

_cleanup_update_tmp() {
    [[ -z "${_UPDATE_TMP:-}" ]] || rm -f "$_UPDATE_TMP"
    _UPDATE_TMP=""
}

check_update_start() {
    _cleanup_update_tmp
    _UPDATE_TMP=$(umask 077; mktemp) || return 1
    register_exit_cleanup _cleanup_update_tmp || {
        rm -f "$_UPDATE_TMP"
        _UPDATE_TMP=""
        return 1
    }
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
