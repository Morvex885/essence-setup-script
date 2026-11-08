#!/bin/bash
# ─── Ядро команд: разбор, диспетчер, конверт, разовый CLI ────────────────────
#
# Команда — `noun verb --flags`. Спецификации и обработчики живут в
# modules/cmd_*.sh: cli_spec_<noun> VERB (токены флагов), _cli_help_<noun>
# (строки справки «usage|описание»), cli_cmd_<noun>[_<verb>] (обработчик).
# Обработчик не задаёт вопросов: кладёт результат в CLI_DATA (JSON) и
# возвращает rc; ошибки и решения — через rc_fail (state.sh).
#
# rc_dispatch ARGV… выполняет команду в текущем shell и оставляет RC_ENVELOPE
# ({ok,data|error}) и RC_EXIT_CODE. Транспорты: cli_main (разовый вызов) и
# serve_main (modules/serve.sh).
#
# Токены спецификации: name= (значение), name (булев), name+ (повторяемый),
# @secret (разрешённый секрет), !nosession (без открытой сессии), !tty (нужен
# /dev/tty). --yes, --plan-token и --json разрешены каждой команде.

CLI_DATA=""
CLI_NOUN=""
CLI_VERB=""
CLI_SPEC=""
RC_ENVELOPE=""
RC_EXIT_CODE=0
CLI_JSON_PRINTED=0

# ─── JSON-хелперы ────────────────────────────────────────────────────────────

# Аргументы → JSON-массив строк ([] без аргументов).
_cli_json_array() {
    if (( $# == 0 )); then
        printf '[]'
        return 0
    fi
    printf '%s\n' "$@" | jq -R . | jq -sc .
}

# Строки stdin → JSON-массив строк, пустые строки отбрасываются.
_cli_json_lines() {
    jq -R 'select(length > 0)' | jq -sc .
}

# ─── Секреты ─────────────────────────────────────────────────────────────────

# rc_secret NAME — значение секрета запроса (RC_REQUEST_SECRETS); rc 1, если
# секрета нет. Значение идёт в jq только через stdin.
rc_secret() {
    printf '%s' "${RC_REQUEST_SECRETS:-}" |
        jq -ej --arg k "$1" 'if type == "object" then .[$k] else null end | strings' 2>/dev/null
}

# _rc_secrets_add JSON NAME VALUE — JSON-объект секретов с добавленным NAME.
# Прежние секреты и значение передаются jq через stdin, не через argv.
_rc_secrets_add() {
    { printf '%s' "${1:-{\}}"; printf '\0'; printf '%s' "$3"; } |
        jq -Rsc --arg k "$2" 'split("\u0000") as [$s, $v] | ($s | fromjson) + {($k): $v}'
}

# Доступен ли управляющий терминал (node shell, telegram menu, пароли CLI).
_rc_tty_available() {
    { : </dev/tty; } 2>/dev/null
}

RC_TTY_STATE=""

_rc_tty_restore() {
    [[ -n "$RC_TTY_STATE" ]] || return 0
    stty "$RC_TTY_STATE" </dev/tty || return 1
    RC_TTY_STATE=""
}

# Интерактивная сессия сохраняет tty и не наследует режим noninteractive timeout.
_rc_tty_run() {
    local rc=0 RC_SERVE_TIMEOUT_FLAG=""
    RC_TTY_STATE=$(stty -g </dev/tty) || return 1
    register_exit_cleanup _rc_tty_restore || return 1
    "$@" </dev/tty >/dev/tty 2>/dev/tty || rc=$?
    _rc_tty_restore || return 1
    return "$rc"
}

# ─── Спецификации ────────────────────────────────────────────────────────────

# cli_spec NOUN VERB → токены; rc 1 — неизвестная команда.
cli_spec() {
    local noun="${1:-}" verb="${2:-}"
    [[ "$noun" =~ ^[a-z][a-z0-9]*$ ]] || return 1
    [[ -z "$verb" || "$verb" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    declare -F "cli_spec_$noun" >/dev/null 2>&1 || return 1
    "cli_spec_$noun" "$verb"
}

_cli_noun_known() {
    [[ "${1:-}" =~ ^[a-z][a-z0-9]*$ ]] && declare -F "cli_spec_$1" >/dev/null 2>&1
}

_cli_spec_has() {
    local tok
    for tok in $1; do
        [[ "$tok" == "$2" ]] && return 0
    done
    return 1
}

# Спецификация команды по argv (без транспортных флагов); rc 1 — неизвестна.
_cli_spec_for_argv() {
    local noun="${1:-}"
    _cli_noun_known "$noun" || return 1
    cli_spec "$noun" "" 2>/dev/null && return 0
    cli_spec "$noun" "${2:-}"
}

_cli_usage_hint() {
    printf 'Справка: remote-control-essence %s --help' "${CLI_NOUN:-help}"
}

# ─── Разбор флагов ───────────────────────────────────────────────────────────

cli_parse() {
    local spec="$1" arg name value has_value kind tok var v
    shift
    for v in $(compgen -A variable CLI_OPT_; compgen -A variable CLI_SET_); do
        unset "$v"
    done
    while (( $# > 0 )); do
        arg="$1"
        shift
        case "$arg" in
            --json) continue ;;
            --*=*) name="${arg%%=*}"; name="${name#--}"; value="${arg#*=}"; has_value=1 ;;
            --*) name="${arg#--}"; value=""; has_value=0 ;;
            *)
                rc_fail usage "Лишний аргумент: ${arg}. $(_cli_usage_hint)"
                return 1
                ;;
        esac
        kind=""
        if [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
            case "$name" in
                yes) kind=bool ;;
                plan-token) kind=value ;;
            esac
            for tok in $spec; do
                case "$tok" in
                    "$name=") kind=value ;;
                    "$name+") kind=multi ;;
                    "$name") kind=bool ;;
                esac
            done
        fi
        if [[ -z "$kind" ]]; then
            rc_fail usage "Неизвестный флаг: --${name}. $(_cli_usage_hint)"
            return 1
        fi
        var="${name//-/_}"
        if [[ "$kind" == bool ]]; then
            if [[ "$has_value" == 1 ]]; then
                rc_fail usage "Флаг --${name} не принимает значение. $(_cli_usage_hint)"
                return 1
            fi
            printf -v "CLI_OPT_$var" '%s' 1
            printf -v "CLI_SET_$var" '%s' 1
            continue
        fi
        if [[ "$has_value" == 0 ]]; then
            if (( $# == 0 )); then
                rc_fail usage "Флаг --${name} требует значение. $(_cli_usage_hint)"
                return 1
            fi
            value="$1"
            shift
        fi
        if [[ "$value" == *$'\n'* ]]; then
            rc_fail usage "Значение флага --${name} не может содержать перевод строки."
            return 1
        fi
        local set_var="CLI_SET_$var" opt_var="CLI_OPT_$var"
        if [[ "$kind" == multi ]]; then
            if [[ "${!set_var:-}" == 1 ]]; then
                printf -v "$opt_var" '%s\n%s' "${!opt_var}" "$value"
            else
                printf -v "$opt_var" '%s' "$value"
            fi
        else
            if [[ "${!set_var:-}" == 1 ]]; then
                rc_fail usage "Флаг --${name} указан дважды. $(_cli_usage_hint)"
                return 1
            fi
            printf -v "$opt_var" '%s' "$value"
        fi
        printf -v "$set_var" '%s' 1
    done
}

cli_has() {
    local var="CLI_SET_${1//-/_}"
    [[ "${!var:-}" == 1 ]]
}

cli_opt() {
    local var="CLI_OPT_${1//-/_}"
    printf '%s' "${!var:-}"
}

# Элементы повторяемого флага по строке.
cli_list() {
    cli_has "$1" || return 0
    local var="CLI_OPT_${1//-/_}"
    printf '%s\n' "${!var}"
}

cli_require() {
    local name
    for name in "$@"; do
        if ! cli_has "$name"; then
            rc_fail usage "Не указан обязательный флаг --${name}. $(_cli_usage_hint)"
            return 1
        fi
    done
}

# Флаги со значением, которые не должны быть пустыми.
cli_require_value() {
    local name
    cli_require "$@" || return 1
    for name in "$@"; do
        if [[ -z "$(cli_opt "$name")" ]]; then
            rc_fail usage "Флаг --${name} не может быть пустым. $(_cli_usage_hint)"
            return 1
        fi
    done
}

# Ровно один из перечисленных флагов.
cli_require_one() {
    local name count=0 list=""
    for name in "$@"; do
        cli_has "$name" && count=$((count + 1))
        list+="${list:+ | }--${name}"
    done
    if (( count != 1 )); then
        rc_fail usage "Укажите ровно один из флагов: ${list}. $(_cli_usage_hint)"
        return 1
    fi
}

# ─── Общие проверки существования ────────────────────────────────────────────

_cli_require_node() {
    if ! jq -e --arg n "$1" 'any(.nodes[]; .name==$n)' "$CONFIG_JSON" >/dev/null 2>&1; then
        rc_fail not_found "Нода '$1' не найдена."
        return 1
    fi
}

_cli_require_group() {
    if ! jq -e --arg g "$1" 'any(.groups[]; .name==$g)' "$CONFIG_JSON" >/dev/null 2>&1; then
        rc_fail not_found "Группа '$1' не найдена."
        return 1
    fi
}

_cli_require_client() {
    if ! jq -e --arg c "$1" 'any(.clients[]; .name==$c)' "$CONFIG_JSON" >/dev/null 2>&1; then
        rc_fail not_found "Клиент '$1' не найден."
        return 1
    fi
}

# Загрузить ноду для SSH: not_found / missing_secret.
_cli_node_load() {
    local rc=0
    _cli_require_node "$1" || return 1
    node_load_by_name "$1" >/dev/null || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) rc_fail missing_secret "Пароль SSH ноды '$1' недоступен." ;;
        *) rc_fail failed "Не удалось загрузить параметры ноды '$1'." ;;
    esac
}

# Статус пароля ноды: ok | missing | error (только для auth=password).
_cli_node_password_state() {
    local rc=0
    node_secret_get "$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) printf 'ok' ;;
        2) printf 'missing' ;;
        *) printf 'error' ;;
    esac
}

# Уникальные строки stdin с сохранением порядка → массив CLI_UNIQUE.
_cli_unique_lines() {
    local line
    CLI_UNIQUE=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if (( ${#CLI_UNIQUE[@]} > 0 )) && array_contains "$line" "${CLI_UNIQUE[@]}"; then
            continue
        fi
        CLI_UNIQUE+=("$line")
    done
}

# ─── Справка ─────────────────────────────────────────────────────────────────

_cli_help_help() {
    cat <<'EOF'
help [СУЩНОСТЬ]|Справка по командам (то же: --help, -h, <сущность> --help)
serve|Протокол JSON-строк через stdin/stdout для интерфейсов (serve --help — описание)
… --json|Ответ одним JSON-объектом {ok, data} или {ok, error} в stdout; журнал — в stderr
… --yes [--plan-token T]|Подтвердить опасное действие; T — plan_token из ответа confirmation_required
… --password-stdin | --secrets-stdin|Секреты из stdin: пароль строкой или JSON-объект {"имя":"значение"}
RC_SCRIPT_PASSWORD, RC_VAULT_PASSWORD, RC_LOCK_WAIT|Окружение: пароль запуска, пароль доступа к GitHub, ожидание блокировки (с)
Коды выхода|0 — успех; 1 — ошибка; 2 — неверное использование, нужно решение или --yes; telegram: 3 — не установлено, 4 — частично
EOF
}

# cli_help_json [NOUN] → {"commands":[{usage,description}]}.
cli_help_json() {
    local noun="${1:-}" fn
    {
        if [[ -n "$noun" ]]; then
            declare -F "_cli_help_$noun" >/dev/null 2>&1 && "_cli_help_$noun"
        else
            _cli_help_help
            for fn in $(compgen -A function _cli_help_ | LC_ALL=C sort); do
                [[ "$fn" == _cli_help_help ]] && continue
                "$fn"
            done
        fi
    } | jq -Rnc '[inputs | select(length > 0)
        | capture("^(?<usage>.*)[|](?<description>[^|]*)$")] | {commands: .}'
}

# ─── Диспетчер ───────────────────────────────────────────────────────────────

# Область токена плана: noun verb и argv без --yes, --plan-token и --json.
_rc_confirm_scope() {
    local out="$1 $2" arg skip=0
    shift 2
    for arg in "$@"; do
        if (( skip )); then
            skip=0
            continue
        fi
        case "$arg" in
            --yes|--json|--plan-token=*) continue ;;
            --plan-token) skip=1; continue ;;
        esac
        out+=$'\n'"$arg"
    done
    printf '%s' "$out"
}

# Секреты запроса — JSON-объект строк; ключи только из @-токенов спецификации.
_rc_check_secrets() {
    local spec="$1" keys key
    if ! keys=$(printf '%s' "${RC_REQUEST_SECRETS:-}" |
        jq -r 'if type == "object" and all(.[]; type == "string") then keys[] else error("secrets") end' 2>/dev/null); then
        rc_fail usage "Секреты должны быть JSON-объектом строк."
        return 1
    fi
    [[ -n "$keys" ]] || return 0
    while IFS= read -r key; do
        if ! _cli_spec_has "$spec" "@$key"; then
            rc_fail usage "Секрет ${key} не поддерживается командой."
            return 1
        fi
    done <<< "$keys"
}

# _cli_wants_help SPEC ARG… — есть ли --help/-h в позиции флага; значение флага
# со значением (`--name -h`) справкой не считается.
_cli_wants_help() {
    local spec="$1" arg name tok skip=0
    shift
    for arg in "$@"; do
        if (( skip )); then
            skip=0
            continue
        fi
        case "$arg" in
            --help|-h) return 0 ;;
            --*=*) ;;
            --*)
                name="${arg#--}"
                if [[ "$name" == plan-token ]]; then
                    skip=1
                    continue
                fi
                for tok in $spec; do
                    if [[ "$tok" == "$name=" || "$tok" == "$name+" ]]; then
                        skip=1
                        break
                    fi
                done
                ;;
        esac
    done
    return 1
}

_rc_dispatch_run() {
    local noun="${1:-}" verb="" spec="" help_spec handler want_help=0
    local -a rest=()
    case "$noun" in
        ""|help|--help|-h)
            CLI_NOUN=help
            if [[ "$noun" == help && -n "${2:-}" ]]; then
                if ! _cli_noun_known "$2"; then
                    rc_fail usage "Неизвестная команда: ${2}. Справка: remote-control-essence --help"
                    return 1
                fi
                CLI_DATA=$(cli_help_json "$2")
            else
                CLI_DATA=$(cli_help_json)
            fi
            return 0
            ;;
    esac
    if ! _cli_noun_known "$noun"; then
        rc_fail usage "Неизвестная команда: ${noun}. Справка: remote-control-essence --help"
        return 1
    fi
    CLI_NOUN="$noun"
    if spec=$(cli_spec "$noun" ""); then
        rest=("${@:2}")
    else
        spec=""
        verb="${2:-}"
        case "$verb" in
            "")
                rc_fail usage "Не указано действие для «${noun}». $(_cli_usage_hint)"
                return 1
                ;;
            help|--help|-h) want_help=1 ;;
        esac
        rest=("${@:3}")
    fi
    if [[ "$want_help" != 1 ]]; then
        help_spec="$spec"
        [[ -z "$verb" ]] || help_spec=$(cli_spec "$noun" "$verb" 2>/dev/null) || help_spec=""
        _cli_wants_help "$help_spec" "${rest[@]}" && want_help=1
    fi
    if [[ "$want_help" == 1 ]]; then
        CLI_DATA=$(cli_help_json "$noun")
        return 0
    fi
    if [[ -n "$verb" ]] && ! spec=$(cli_spec "$noun" "$verb"); then
        rc_fail usage "Неизвестная команда: ${noun} ${verb}. $(_cli_usage_hint)"
        return 1
    fi
    CLI_VERB="$verb"
    CLI_SPEC="$spec"
    handler="cli_cmd_${noun}${verb:+_${verb//-/_}}"
    if ! declare -F "$handler" >/dev/null 2>&1; then
        rc_fail usage "Команда не поддерживается: ${noun} ${verb}."
        return 1
    fi
    cli_parse "$spec" "${rest[@]}" || return 1
    _rc_check_secrets "$spec" || return 1
    # Нужны оба признака: команды восстановления авторизуют без открытого источника.
    if ! _cli_spec_has "$spec" '!nosession' &&
       [[ "${RC_SESSION_OPEN:-0}" != 1 || "${RC_SESSION_AUTHORIZED:-0}" != 1 ]]; then
        if [[ "${RC_SESSION_AUTO_OPEN:-0}" == 1 ]]; then
            session_open_from_transport || return 1
        else
            rc_fail session_closed "Сначала откройте сессию: session open."
            return 1
        fi
    fi
    if cli_has plan-token && ! cli_has yes; then
        rc_fail usage "Флаг --plan-token используется только вместе с --yes."
        return 1
    fi
    cli_has yes && RC_CONFIRM_YES=1
    RC_CONFIRM_TOKEN=$(cli_opt plan-token)
    RC_CONFIRM_SCOPE=$(_rc_confirm_scope "$noun" "$verb" "${rest[@]}")
    rc_error_reset
    CLI_DATA=""
    "$handler"
}

# _rc_finish RC → RC_ENVELOPE и RC_EXIT_CODE по CLI_DATA и RC_ERROR_*.
_rc_finish() {
    local rc="${1:-1}" code message extra sync=""
    if [[ "$rc" == 0 ]]; then
        [[ "${CONFIG_SOURCE:-local}" == github ]] && sync="${GITHUB_SYNC_STATUS:-clean}"
        RC_ENVELOPE=$(printf '%s' "${CLI_DATA:-null}" | jq -sc --arg s "$sync" '
            (if length == 1 then .[0] else null end) as $d
            | {ok:true, data:$d} + (if $s == "" then {} else {sync:$s} end)' 2>/dev/null) ||
            RC_ENVELOPE='{"ok":true,"data":null}'
        RC_EXIT_CODE=0
        return 0
    fi
    code="${RC_ERROR_CODE:-failed}"
    message="${RC_ERROR_MESSAGE:-}"
    if [[ -z "$message" ]]; then
        message="Операция не выполнена. Подробности выше."
        warn "$message"
    fi
    extra="${RC_ERROR_EXTRA:-}"
    printf '%s' "$extra" | jq -e 'type == "object"' >/dev/null 2>&1 || extra='{}'
    RC_ENVELOPE=$(printf '%s' "${CLI_DATA:-}" | jq -sc --arg c "$code" --arg m "$message" --argjson e "$extra" '
        {ok:false, error:({code:$c, message:$m} + $e)} + (if length == 1 then {data:.[0]} else {} end)' 2>/dev/null) ||
        RC_ENVELOPE=$(jq -cn --arg c "$code" --arg m "$message" '{ok:false, error:{code:$c, message:$m}}')
    case "$code" in
        usage|host_key_unknown|plan_changed|*_required) RC_EXIT_CODE=2 ;;
        *) RC_EXIT_CODE=1 ;;
    esac
    if [[ "$CLI_NOUN" == telegram && ( "$rc" == 3 || "$rc" == 4 ) ]]; then
        RC_EXIT_CODE="$rc"
    fi
}

# rc_dispatch ARGV… → RC_ENVELOPE, RC_EXIT_CODE; возвращает RC_EXIT_CODE.
rc_dispatch() {
    local arg var rc=0
    local -a args=()
    rc_error_reset
    CLI_DATA="" CLI_NOUN="" CLI_VERB="" CLI_SPEC=""
    CORE_PLAN_LINES=()
    CORE_PLAN_EXTRA=""
    CORE_PLAN_DATA='{}'
    RC_CONFIRM_YES=0 RC_CONFIRM_TOKEN="" RC_CONFIRM_SCOPE=""
    for var in $(compgen -A variable CLI_OPT_; compgen -A variable CLI_SET_;
                 compgen -A variable GITHUB_DECISION_; compgen -A variable GITHUB_SECRET_); do
        unset "$var"
    done
    [[ -n "${RC_REQUEST_SECRETS:-}" ]] || RC_REQUEST_SECRETS='{}'
    for arg in "$@"; do
        [[ "$arg" == --json ]] || args+=("$arg")
    done
    _rc_dispatch_run "${args[@]}" || rc=$?
    _rc_finish "$rc"
    unset RC_REQUEST_SECRETS
    for var in $(compgen -A variable GITHUB_SECRET_); do
        unset "$var"
    done
    return "$RC_EXIT_CODE"
}

# ─── Человекочитаемый вывод ──────────────────────────────────────────────────

# Конверт → три поля через NUL: признак плана, строки плана, текст.
# shellcheck disable=SC2016
_CLI_RENDER_FILTER='
def cell:
  if . == null then "—"
  elif type == "boolean" then (if . then "да" else "нет" end)
  elif type == "string" then .
  elif type == "number" then tostring
  elif type == "array" and all(.[]; type != "object" and type != "array") then
    (if length == 0 then "—"
     else map(if . == null then "—" elif type == "boolean" then (if . then "да" else "нет" end)
              elif type == "string" then . else tostring end) | join(", ") end)
  else tojson end;
def objarr: type == "array" and length > 0 and all(.[]; type == "object");
def table($ind):
  (reduce .[] as $o ([]; . + (($o | keys_unsorted) - .))) as $cols
  | ([$cols] + [.[] | . as $o | [$cols[] | . as $k | $o[$k] | cell]]) as $rows
  | [range(0; $cols | length) as $i | [$rows[] | .[$i] | length] | max] as $w
  | $rows[] | . as $r
  | $ind + ([range(0; $r | length) as $i
      | if $i == ($r | length) - 1 then $r[$i]
        else $r[$i] + (" " * ($w[$i] - ($r[$i] | length))) end] | join("  "));
def render($ind):
  if type == "array" then
    if length == 0 then empty
    elif objarr then table($ind)
    else .[] | $ind + cell end
  elif type == "object" then
    to_entries[] | .key as $k | .value as $v
    | if ($v | type) == "object" and ($v | length) > 0 then ($ind + $k + ":"), ($v | render($ind + "  "))
      elif ($v | objarr) then ($ind + $k + ":"), ($v | render($ind + "  "))
      else $ind + $k + ": " + ($v | cell) end
  else $ind + cell end;
(if .ok == false and (.error.code == "confirmation_required" or .error.code == "plan_changed")
 then "1" else "" end) as $plan
| $plan, "\u0000",
  (if $plan == "1" then ((.error.plan // []) | map(tostring + "\n") | add // "") else "" end), "\u0000",
  ([ (if .ok then empty
      else .error | to_entries[]
        | select(.key != "code" and .key != "message" and .key != "plan" and .key != "plan_token")
        | "  " + .key + ": " + (.value | cell) end),
     (if has("data") and .data != null then .data | render("  ") else empty end)
   ] | map(. + "\n") | add // "")
'

# Единственный человекочитаемый вывод разового CLI: RC_ENVELOPE → текст.
# Сообщение ошибки уже напечатал rc_fail.
cli_render_human() {
    local plan="" lines_text="" text="" line
    local -a lines=()
    {
        IFS= read -r -d '' plan
        IFS= read -r -d '' lines_text
        IFS= read -r -d '' text
    } < <(printf '%s' "$RC_ENVELOPE" | jq -j "$_CLI_RENDER_FILTER" 2>/dev/null)
    if [[ "$plan" == 1 ]]; then
        if [[ -n "$lines_text" ]]; then
            while IFS= read -r line; do
                lines+=("$line")
            done <<< "${lines_text%$'\n'}"
        fi
        review_frame "Требуется подтверждение" "${lines[@]}"
        warn "Повторите команду с --yes."
    fi
    [[ -z "$text" ]] || printf '%s' "$text"
}

# Цвета и OSC 8 только для терминала: журнал и JSON остаются чистым текстом.
_rc_plain_output() {
    RED='' GREEN='' YELLOW='' CYAN='' DIM='' NC=''
    hyperlink() {
        if [[ -n "${2:-}" && "$2" != "$1" ]]; then
            printf '%s (%s)' "$2" "$1"
        else
            printf '%s' "$1"
        fi
    }
}

# ─── Разовый CLI ─────────────────────────────────────────────────────────────

# EXIT-очистка: error() → exit не должен оставить stdout без ответа.
cli_json_fallback() {
    [[ "$CLI_JSON_PRINTED" != 1 ]] || return 0
    CLI_JSON_PRINTED=1
    printf '%s\n' '{"ok":false,"error":{"code":"failed","message":"Команда прервана."}}' >&3
}

# Чтение секретов транспорта из stdin → RC_REQUEST_SECRETS.
_cli_read_stdin_secrets() {
    local password_stdin="$1" secrets_stdin="$2" spec value=""
    shift 2
    RC_REQUEST_SECRETS='{}'
    (( password_stdin || secrets_stdin )) || return 0
    if (( password_stdin && secrets_stdin )); then
        rc_fail usage "Укажите только один из флагов: --password-stdin | --secrets-stdin."
        return 1
    fi
    if (( password_stdin )); then
        if ! spec=$(_cli_spec_for_argv "$@") || ! _cli_spec_has "$spec" '@password'; then
            rc_fail usage "Флаг --password-stdin не поддерживается командой."
            return 1
        fi
        IFS= read -r -d '' value || true
        while [[ "$value" == *$'\n' || "$value" == *$'\r' ]]; do
            value="${value%$'\n'}"
            value="${value%$'\r'}"
        done
        if [[ -z "$value" ]]; then
            rc_fail usage "Пароль из stdin пуст."
            return 1
        fi
        RC_REQUEST_SECRETS=$(printf '%s' "$value" | jq -Rsc '{password: .}') || {
            rc_fail usage "Не удалось прочитать пароль из stdin."
            return 1
        }
        return 0
    fi
    IFS= read -r -d '' value || true
    if ! RC_REQUEST_SECRETS=$(printf '%s' "$value" |
        jq -c 'if type == "object" and all(.[]; type == "string") then . else error("secrets") end' 2>/dev/null); then
        RC_REQUEST_SECRETS='{}'
        rc_fail usage "--secrets-stdin ожидает в stdin JSON-объект строк."
        return 1
    fi
}

# cli_main ARGV… — разовая команда: argv → rc_dispatch → вывод → код выхода.
cli_main() {
    local arg json=0 password_stdin=0 secrets_stdin=0 plain=0 stdin_tty=0
    local -a args=()
    if [[ "${1:-}" == serve ]]; then
        shift
        case "${1:-}" in
            "") serve_main; return $? ;;
            --help|-h|help) serve_help; return 0 ;;
            *)
                warn "Неизвестный аргумент serve: $1. Справка: remote-control-essence serve --help"
                return 2
                ;;
        esac
    fi
    for arg in "$@"; do
        case "$arg" in
            --json) json=1 ;;
            --password-stdin) password_stdin=1 ;;
            --secrets-stdin) secrets_stdin=1 ;;
            *) args+=("$arg") ;;
        esac
    done
    # Пароли из окружения забираем в неэкспортируемые переменные и убираем из
    # окружения: иначе их унаследуют все дочерние процессы (ssh, jq, git…).
    RC_SESSION_SCRIPT_PASSWORD="${RC_SCRIPT_PASSWORD:-}"
    RC_SESSION_VAULT_PASSWORD="${RC_VAULT_PASSWORD:-}"
    unset RC_SCRIPT_PASSWORD RC_VAULT_PASSWORD
    RC_SESSION_AUTO_OPEN=1
    [[ -t 1 && -t 2 ]] || plain=1
    if (( json )); then
        RC_QUIET_DECISIONS=1
        plain=1
        exec 3>&1 1>&2
    fi
    (( plain )) && _rc_plain_output
    register_exit_cleanup session_close ||
        warn "Не удалось зарегистрировать закрытие сессии."
    if (( json )); then
        register_exit_cleanup cli_json_fallback ||
            warn "Не удалось зарегистрировать резервный JSON-ответ."
    fi
    [[ -t 0 ]] && stdin_tty=1
    rc_error_reset
    CLI_DATA=""
    if _cli_read_stdin_secrets "$password_stdin" "$secrets_stdin" "${args[@]}"; then
        exec </dev/null
        RC_SESSION_TTY_PROMPT="$stdin_tty"
        rc_dispatch "${args[@]}"
    else
        exec </dev/null
        CLI_NOUN="${args[0]:-}"
        _rc_finish 1
        unset RC_REQUEST_SECRETS
    fi
    if (( json )); then
        printf '%s\n' "$RC_ENVELOPE" >&3
        CLI_JSON_PRINTED=1
    else
        cli_render_human
    fi
    return "$RC_EXIT_CODE"
}
