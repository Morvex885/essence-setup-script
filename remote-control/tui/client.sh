#!/bin/bash
# ─── Клиент serve и общие виджеты TUI ────────────────────────────────────────
# Запрос — строка {"id","argv","secrets"?} в fd 7, ответ и события журнала —
# строки из fd 8. Секреты идут только полем secrets, в argv процессов их нет.

TUI_TMP=""
TUI_SERVE_PID=""
TUI_TTY_STATE=""
TUI_ID=0
TUI_RESPONSE=""
TUI_OK=false
TUI_CODE=""
TUI_DATA=null
TUI_ERROR=null
TUI_PICK=""
TUI_PICKED=()

# Хвост журнала serve, затем сообщение об ошибке процесса и выход 1 (`error`).
tui_fatal() {
    if [[ -n "$TUI_TMP" && -f "$TUI_TMP/serve.log" ]]; then
        tail -n 20 "$TUI_TMP/serve.log"
    fi
    error "$1"
}

# Каталог принадлежит только TUI; editor-файлы очищаются и при exit из INT trap.
tui_tmp_init() {
    [[ -z "$TUI_TMP" ]] || return 0
    TUI_TMP=$(umask 077; mktemp -d) || {
        warn "Не удалось создать временный каталог."
        return 1
    }
    register_exit_cleanup tui_shutdown
}

tui_tty_restore() {
    [[ -n "$TUI_TTY_STATE" ]] || return 0
    stty "$TUI_TTY_STATE" </dev/tty || return 1
    TUI_TTY_STATE=""
}

# Вызов внешнего редактора: EXIT-очистка восстанавливает tty и при Ctrl+C.
tui_with_tty() {
    local rc=0
    if { : </dev/tty; } 2>/dev/null; then
        TUI_TTY_STATE=$(stty -g </dev/tty) || return 1
        register_exit_cleanup tui_tty_restore || return 1
    fi
    "$@" || rc=$?
    tui_tty_restore || return 1
    return "$rc"
}

tui_serve_start() {
    local line protocol
    trap '' PIPE
    [[ -n "${RC_ENTRYPOINT:-}" && -f "$RC_ENTRYPOINT" ]] ||
        tui_fatal "Не найден файл remote-control (RC_ENTRYPOINT)."
    tui_tmp_init || tui_fatal "Не удалось подготовить временный каталог."
    mkfifo "$TUI_TMP/req" "$TUI_TMP/resp" || tui_fatal "Не удалось создать каналы обмена с ядром."
    "${BASH:-bash}" "$RC_ENTRYPOINT" serve < "$TUI_TMP/req" > "$TUI_TMP/resp" 2> "$TUI_TMP/serve.log" &
    TUI_SERVE_PID=$!
    exec 7> "$TUI_TMP/req"
    exec 8< "$TUI_TMP/resp"
    register_exit_cleanup tui_shutdown
    if ! IFS= read -r line <&8; then
        tui_fatal "Ядро remote-control не запустилось."
    fi
    protocol=$(printf '%s' "$line" | jq -r 'select(.event == "hello") | .protocol // empty' 2> /dev/null)
    [[ "$protocol" == 1 ]] || tui_fatal "Неподдерживаемый протокол ядра remote-control."
}

tui_shutdown() {
    [[ -n "$TUI_TMP" ]] || return 0
    exec 7>&-
    [[ -z "$TUI_SERVE_PID" ]] || wait "$TUI_SERVE_PID" 2> /dev/null
    exec 8<&-
    rm -rf "$TUI_TMP"
    TUI_TMP=""
    TUI_SERVE_PID=""
}

# Текст журнала без управляющих символов C0 (кроме табуляции) и C1: текст
# приходит от ядра и серверов и не должен управлять терминалом.
_tui_strip_controls() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\012-\037\177' |
        LC_ALL=C sed $'s/\xc2[\x80-\x9f]//g'
}

# Строка журнала по уровню; префиксы те же, что в common.sh.
tui_render_log() {
    local level="$1" text
    text=$(_tui_strip_controls "$2")
    case "$level" in
        info)    printf '  %b[*]%b %s\n' "$CYAN" "$NC" "$text" ;;
        success) printf '  %b[✓]%b %s\n' "$GREEN" "$NC" "$text" ;;
        warn)    printf '  %b[!]%b %s\n' "$YELLOW" "$NC" "$text" ;;
        error)   printf '  %b[✗]%b %s\n' "$RED" "$NC" "$text" ;;
        *)       printf '%s\n' "$text" ;;
    esac
}

# tui_call ARGV… → TUI_RESPONSE, TUI_OK, TUI_CODE, TUI_DATA, TUI_ERROR; rc 0 при ok.
tui_call() {
    local req line kind level text
    TUI_ID=$((TUI_ID + 1))
    req=$(jq -cn --argjson id "$TUI_ID" '{id:$id, argv:$ARGS.positional}' --args -- "$@")
    if [[ -n "${TUI_SECRETS:-}" ]]; then
        req=$(printf '%s' "$TUI_SECRETS" | jq -c --argjson r "$req" '$r + {secrets: .}')
    fi
    printf '%s\n' "$req" >&7 2> /dev/null
    req=""
    trap '' INT
    while IFS= read -r line <&8; do
        IFS=$'\t' read -r kind level text < <(printf '%s' "$line" | jq -r --argjson id "$TUI_ID" '
            if .event == "log" and .id == $id then "log\t\(.level)\t\(.text)"
            elif .event == null and .id == $id then "reply\t\t"
            else "skip\t\t" end' 2> /dev/null)
        case "$kind" in
            log) tui_render_log "$level" "$text" ;;
            reply)
                TUI_RESPONSE="$line"
                TUI_OK=$(printf '%s' "$line" | jq -r '.ok')
                TUI_CODE=$(printf '%s' "$line" | jq -r '.error.code // ""')
                TUI_DATA=$(printf '%s' "$line" | jq -c '.data // null')
                TUI_ERROR=$(printf '%s' "$line" | jq -c '.error // null')
                trap tui_on_int INT
                [[ "$TUI_OK" == true ]]
                return
                ;;
        esac
    done
    trap tui_on_int INT
    tui_fatal "Ядро remote-control неожиданно завершилось."
}

# Данные и ошибка последнего ответа: jq -r без \r.
tui_q() { printf '%s' "$TUI_DATA" | jq -r "$@" | tr -d '\r'; }
tui_eq() { printf '%s' "$TUI_ERROR" | jq -r "$@" | tr -d '\r'; }

# tui_secret NAME VALUE — секрет в TUI_SECRETS. Прежние секреты и значение идут
# в jq только через stdin: в argv их увидел бы /proc/<pid>/cmdline.
tui_secret() {
    local name="$1" value="$2" merged
    merged=$({ printf '%s' "${TUI_SECRETS:-{\}}"; printf '\0'; printf '%s' "$value"; } |
        jq -Rsc --arg k "$name" 'split("\u0000") as [$s, $v] | ($s | fromjson) + {($k): $v}') || return 1
    TUI_SECRETS="$merged"
}

tui_secrets_clear() { unset TUI_SECRETS; }

# tui_run_confirmed TITLE QUESTION ARGV… — план, согласие, повтор с токеном.
# Сообщения об ошибках уже показал журнал; повторно их не печатаем.
tui_run_confirmed() {
    local title="$1" question="$2" token line changed=0
    local -a argv plan
    shift 2
    argv=("$@")
    tui_call "${argv[@]}" && return 0
    while true; do
        case "$TUI_CODE" in
            confirmation_required) ;;
            plan_changed)
                changed=$((changed + 1))
                if (( changed > 2 )); then
                    warn "План продолжает меняться. Действие не выполнено; повторите позже."
                    return 1
                fi
                warn "План изменился. Проверьте его ещё раз."
                ;;
            *) return 1 ;;
        esac
        token=$(tui_eq '.plan_token // empty')
        plan=()
        while IFS= read -r line; do
            plan+=("$line")
        done < <(tui_eq '.plan[]?')
        review_frame "$title" "${plan[@]}"
        if ! confirm_yn "$question" N; then
            info "Отменено."
            return 1
        fi
        tui_call "${argv[@]}" --yes --plan-token "$token" && return 0
    done
}

# ─── Виджеты выбора ──────────────────────────────────────────────────────────

# _tui_pick PROMPT EMPTY TITLE LABEL_FILTER ARGV… → TUI_PICK (имя). rc 1 — отмена.
_tui_pick() {
    local prompt="$1" empty="$2" title="$3" filter="$4" line
    local -a labels=()
    shift 4
    TUI_PICK=""
    tui_call "$@" || return 1
    while IFS= read -r line; do
        labels+=("$line")
    done < <(tui_q ".[] | $filter")
    MENU_SELECT_EMPTY="$empty"
    menu_select "$title" "$prompt" "${labels[@]}" || return 1
    TUI_PICK=$(tui_q ".[$((MENU_SELECT_INDEX - 1))].name")
}

tui_pick_node()     { _tui_pick "Выберите ноду" "Нет нод" "$1" '"\(.name)  \(.ip):\(.port)"' node list; }
tui_pick_client()   { _tui_pick "Выберите клиента" "Нет клиентов" "$1" '.name' client list; }
tui_pick_group()    { _tui_pick "Выберите группу" "Нет групп" "$1" '.name' group list; }

# tui_toggle_nodes TITLE → TUI_PICKED (имена отмеченных нод). rc 1 — отмена.
tui_toggle_nodes() {
    local title="$1" line i rc=0
    local -a names=()
    TUI_PICKED=()
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    tui_call node list || return 1
    while IFS= read -r line; do
        names+=("$line")
    done < <(tui_q '.[].name')
    while IFS= read -r line; do
        TOGGLE_SELECT_ITEMS+=("$line")
        TOGGLE_SELECT_FLAGS+=(0)
    done < <(tui_q '.[] | "\(.name)  \(.ip):\(.port)"')
    toggle_select "$title" || rc=$?
    if (( rc == 0 )); then
        for i in "${!names[@]}"; do
            [[ "${TOGGLE_SELECT_FLAGS[$i]}" == 1 ]] && TUI_PICKED+=("${names[$i]}")
        done
    fi
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    return "$rc"
}

# tui_handle_node_codes NAME — после неуспешной команды над нодой.
# rc 2 — условие устранено, команду можно повторить; rc 1 — нет.
tui_handle_node_codes() {
    local name="$1" pw fp rc
    case "$TUI_CODE" in
        missing_secret)
            confirm_yn "Пароль SSH для ноды не сохранён. Сохранить сейчас?" N || return 1
            IFS= read -rsp "  Пароль SSH (Enter — отмена): " pw || { echo ""; return 1; }
            echo ""
            pw="${pw%$'\r'}"
            [[ -n "$pw" ]] || return 1
            tui_secret password "$pw" || return 1
            pw=""
            rc=0
            tui_call node password --name "$name" || rc=1
            tui_secrets_clear
            (( rc == 0 )) && return 2
            return 1
            ;;
        host_key_changed)
            fp=$(tui_eq '.fingerprints[0] // empty')
            [[ -n "$fp" ]] || return 1
            tui_run_confirmed "Ключ сервера изменился" "Доверять новому ключу?" \
                node trust-host-key --name "$name" --host-key "$fp" || return 1
            return 2
            ;;
        needs_setup)
            warn "Нода требует SSH-настройки: раздел n → h."
            return 1
            ;;
        *) return 1 ;;
    esac
}

# Ссылка, срок и заголовки подписки по данным `sub show` (TUI_DATA).
tui_render_share_bundle() {
    local client url expires line
    client=$(tui_q '.client')
    url=$(tui_q '.url')
    expires=$(tui_q '.expires_at // empty')
    echo ""
    box_top
    box_center "Подписка: $client"
    box_mid
    box_line " URL: $url" " ${GREEN}URL:${NC} $(hyperlink "$url")"
    if [[ -n "$expires" ]]; then
        box_line " Срок действия: $expires" " ${YELLOW}Срок действия:${NC} $expires"
    fi
    if [[ "$(tui_q '.headers | length')" -gt 0 ]]; then
        box_mid
        box_line " Сервер отдаст эти заголовки:" " ${DIM}Сервер отдаст эти заголовки:${NC}"
        while IFS= read -r line; do
            box_line "   $line"
        done < <(tui_q '.headers[] | "\(.name): \(.value)"')
    fi
    box_bot
    echo ""
    printf '  curl %s\n' "'$url'"
    echo ""
    printf '  %s\n' "$(printf '%s' "$url" | jq -Rsc '{url: .}')"
    if command -v qrencode > /dev/null 2>&1; then
        echo ""
        printf '%s' "$url" | qrencode -t UTF8 7>&- 8>&-
    fi
}

# ─── Общие помощники экранов ─────────────────────────────────────────────────

# Заголовок кадра: пустая строка, рамка, заголовок, разделитель.
_tui_head() {
    echo ""
    box_top
    box_center "$1"
    box_mid
}

# Меню действий: приглашение и ввод в TUI_CHOICE; rc 1 — EOF.
_tui_prompt() {
    local c
    echo ""
    IFS= read -rp "  ${1:-Выберите действие}: " c || return 1
    TUI_CHOICE="${c%$'\r'}"
}

# Вопрос с вводом в TUI_ANSWER; rc 1 — EOF.
_tui_ask() {
    local a
    IFS= read -rp "  $1: " a || return 1
    TUI_ANSWER="${a%$'\r'}"
}

# Строки результата jq-фильтра по TUI_DATA (аргументы как у tui_q) в массив TUI_LIST.
_tui_list_into() {
    local line
    TUI_LIST=()
    while IFS= read -r line; do
        TUI_LIST+=("$line")
    done < <(tui_q "$@")
}

# Мультивыбор: вход _TG_LABELS и _TG_FLAGS (0/1); выход TUI_PICKED_IDX (индексы
# отмеченных). Глобалы toggle_select очищаются на любом исходе.
_tui_toggle() {
    local title="$1" rc=0 i
    TUI_PICKED_IDX=()
    TOGGLE_SELECT_ITEMS=("${_TG_LABELS[@]}")
    TOGGLE_SELECT_FLAGS=("${_TG_FLAGS[@]}")
    toggle_select "$title" || rc=$?
    if (( rc == 0 )); then
        for i in "${!TOGGLE_SELECT_FLAGS[@]}"; do
            [[ "${TOGGLE_SELECT_FLAGS[$i]}" == 1 ]] && TUI_PICKED_IDX+=("$i")
        done
    fi
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    return "$rc"
}
