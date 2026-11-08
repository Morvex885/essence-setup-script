#!/bin/bash
# ─── serve: протокол JSON-строк для интерфейсов ──────────────────────────────
#
# remote-control-essence serve — долгоживущий процесс ядра. stdout: первая
# строка {"event":"hello","protocol":1,"version":V}, затем на каждый запрос
# {"id":…,"argv":[…],"secrets":{…}?} — события журнала
# {"id","event":"log","level","text"} и ровно один ответ {"id",…конверт}.
# Запросы выполняются строго по одному; Ctrl+C не прерывает команду; EOF stdin
# закрывает сессию и завершает процесс.

SERVE_TMP=""
SERVE_ACTIVE_ID=""

serve_help() {
    cat <<'EOF'

  Использование: remote-control-essence serve

  Протокол JSON-строк для интерфейсов (TUI, веб, приложение).
  stdout, первая строка:  {"event":"hello","protocol":1,"version":"X"}
  Запрос (строка stdin):  {"id":1,"argv":["group","list"],"secrets":{"password":"…"}}
    id — строка или число; argv — массив строк; secrets — необязательный объект строк.
  События до ответа:      {"id":1,"event":"log","level":"info|success|warn|error|output","text":"…"}
  Ответ:                  {"id":1,"ok":true,"data":…} или {"id":1,"ok":false,"error":{"code","message",…}}

  Сначала session open (секреты script-password, vault-password), иначе session_closed.
  Опасная команда без --yes отвечает confirmation_required с plan и plan_token;
  выполнение — тот же argv с --yes --plan-token T, изменившийся план — plan_changed.
  Запросы выполняются по одному; Ctrl+C не прерывает команду; EOF stdin завершает serve.

EOF
}

# Насос журнала: строки команды → события log с id запроса (в fd 3).
# Управляющие символы C0/C1 (включая NUL, кроме табуляции) вырезаются: имена из
# конфигурации и вывод нод не должны доходить до интерфейса escape-последовательностями.
_serve_pump() {
    # shellcheck disable=SC2016
    jq -cR --unbuffered --argjson id "$1" '
        sub("\r$"; "") as $l
        | (if ($l | startswith("  [*] ")) then ["info", $l[6:]]
           elif ($l | startswith("  [✓] ")) then ["success", $l[6:]]
           elif ($l | startswith("  [!] ")) then ["warn", $l[6:]]
           elif ($l | startswith("  [✗] ")) then ["error", $l[6:]]
           else ["output", $l] end) as [$level, $text]
        | {id:$id, event:"log", level:$level,
           text:($text | explode | map(select(. == 9 or (. >= 32 and (. < 127 or . > 159)))) | implode)}' >&3
}

_serve_reply_error() {
    jq -cn --argjson id "$1" --arg c "$2" --arg m "$3" \
        '{id:$id, ok:false, error:{code:$c, message:$m}}' >&3
}

# EXIT-очистка: аварийный ответ на незавершённый запрос и временный каталог.
serve_cleanup() {
    if [[ -n "$SERVE_ACTIVE_ID" ]]; then
        _serve_reply_error "$SERVE_ACTIVE_ID" failed "Ядро завершилось аварийно." 2>/dev/null ||
            printf '%s\n' '{"id":null,"ok":false,"error":{"code":"failed","message":"Ядро завершилось аварийно."}}' >&3
        SERVE_ACTIVE_ID=""
    fi
    [[ -z "$SERVE_TMP" ]] || rm -rf "$SERVE_TMP"
}

# Запрос → id (JSON), секреты (JSON или «!» для неверного запроса), argv — через NUL.
# shellcheck disable=SC2016
_SERVE_REQUEST_FILTER='
def okstr: type == "string" and (explode | all(. != 0));
if type != "object" then "null", "\u0000", "!", "\u0000"
else
  (if (.id | type) == "string" or (.id | type) == "number" then .id else null end) as $id
  | ($id | tojson), "\u0000",
    (if (.id == null or (.id | type) == "string" or (.id | type) == "number")
        and (.argv | type) == "array" and all(.argv[]; okstr)
        and (.secrets == null or ((.secrets | type) == "object" and all(.secrets[]; type == "string")))
     then ((.secrets // {}) | tojson), "\u0000", (.argv[] | ., "\u0000")
     else "!", "\u0000" end)
end'

# Канал журнала запроса: FIFO в приватном каталоге. Если его удалили (очистка
# /tmp во время простоя), создаётся новый каталог — старый путь не переиспользуется.
_serve_log_ready() {
    local dir=""
    [[ -n "$SERVE_TMP" && -p "$SERVE_TMP/log" ]] && return 0
    if ! dir=$(umask 077; mktemp -d) || ! mkfifo "$dir/log"; then
        [[ -z "$dir" ]] || rm -rf "$dir"
        return 1
    fi
    [[ -z "$SERVE_TMP" ]] || rm -rf "$SERVE_TMP"
    SERVE_TMP="$dir"
}

serve_handle_line() {
    local line="$1" id_json="" secrets_json="" item pump
    local -a argv=()
    {
        IFS= read -r -d '' id_json
        IFS= read -r -d '' secrets_json
        while IFS= read -r -d '' item; do
            argv+=("$item")
        done
    } < <(printf '%s' "$line" | jq -j "$_SERVE_REQUEST_FILTER" 2>/dev/null)
    [[ -n "$id_json" ]] || id_json=null
    if [[ "$secrets_json" != "{"* ]]; then
        _serve_reply_error "$id_json" usage "Неверный запрос."
        return 0
    fi
    for item in "${argv[@]}"; do
        case "$item" in
            --password-stdin|--secrets-stdin)
                _serve_reply_error "$id_json" usage "В serve секреты передаются полем secrets."
                return 0
                ;;
        esac
    done
    if ! _serve_log_ready; then
        _serve_reply_error "$id_json" failed "Не удалось подготовить канал журнала serve."
        return 0
    fi
    SERVE_ACTIVE_ID="$id_json"
    RC_REQUEST_SECRETS="$secrets_json"
    secrets_json=""
    # Ответ берётся только из этого запроса: без конверта — ошибка, не прошлый ответ.
    RC_ENVELOPE=""
    _serve_pump "$id_json" < "$SERVE_TMP/log" &
    pump=$!
    rc_dispatch "${argv[@]}" > "$SERVE_TMP/log" 2>&1 < /dev/null
    if [[ -z "$RC_ENVELOPE" ]]; then
        # Перенаправление не открылось: насос ждёт писателя — снять его.
        unset RC_REQUEST_SECRETS
        kill "$pump" 2>/dev/null
        wait "$pump" 2>/dev/null
        _serve_reply_error "$id_json" failed "Не удалось открыть канал журнала serve."
        SERVE_ACTIVE_ID=""
        return 0
    fi
    wait "$pump"
    printf '%s' "$RC_ENVELOPE" | jq -c --argjson id "$id_json" '{id:$id} + .' >&3
    SERVE_ACTIVE_ID=""
}

serve_main() {
    local line RC_SERVE_TIMEOUT_FLAG=--ignore-int
    RC_SESSION_AUTO_OPEN=0
    RC_QUIET_DECISIONS=1
    unset RC_SCRIPT_PASSWORD RC_VAULT_PASSWORD
    _rc_plain_output
    trap '' INT PIPE
    exec 3>&1 1>&2
    if ! _serve_log_ready; then
        printf '  [✗] Не удалось подготовить канал журнала serve.\n' >&2
        return 1
    fi
    register_exit_cleanup session_close ||
        warn "Не удалось зарегистрировать закрытие сессии."
    register_exit_cleanup serve_cleanup ||
        warn "Не удалось зарегистрировать очистку serve."
    # Фоновая проверка обновлений не должна держать ни журнал, ни протокол.
    check_update_start </dev/null >/dev/null 2>&1 3>&- || true
    jq -cn --arg v "${CURRENT_VERSION:-0.0.0}" '{event:"hello", protocol:1, version:$v}' >&3
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        serve_handle_line "$line"
    done
    exit 0
}
