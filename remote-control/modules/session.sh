#!/bin/bash
# ─── Сессия ядра: источник конфигурации и пароль запуска ─────────────────────
#
# RC_SESSION_OPEN — источник открыт (config_source_startup выполнен),
# RC_SESSION_AUTHORIZED — пароль запуска проверен. Команды без !nosession
# требуют обоих; разовый CLI открывает сессию сам (session_open_from_transport),
# serve — только запросом session open.

RC_SESSION_OPEN=0
RC_SESSION_AUTHORIZED=0
RC_SESSION_TTY_PROMPT=0
RC_SESSION_SCRIPT_PASSWORD=""
RC_SESSION_VAULT_PASSWORD=""

_session_configured() {
    [[ -f "$CONFIG_DIR/source.json" || -f "$CONFIG_DIR/config.json" ]]
}

# Есть ли непустой хеш пароля запуска.
_session_script_password_set() {
    local passfile
    passfile=$(_script_pass_file)
    [[ -f "$passfile" && -n "$(tr -d '\r\n' < "$passfile")" ]]
}

# {"configured","source","open","authorized"} — без открытия источника.
session_status_json() {
    local configured=false source=""
    if _session_configured; then
        configured=true
        if github_source_metadata_valid "$CONFIG_DIR/source.json" ||
           jq -e 'type == "object" and .type == "github"' "$CONFIG_DIR/source.json" >/dev/null 2>&1; then
            source=github
        else
            source=local
        fi
    fi
    jq -cn --argjson c "$configured" --arg s "$source" \
        --argjson o "$([[ "$RC_SESSION_OPEN" == 1 ]] && echo true || echo false)" \
        --argjson a "$([[ "$RC_SESSION_AUTHORIZED" == 1 ]] && echo true || echo false)" \
        '{configured:$c, source:(if $s == "" then null else $s end), open:$o, authorized:$a}'
}

# {"source","repo","sync"} открытой сессии.
session_data_json() {
    local repo="" sync=""
    if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
        repo=$(jq -r '.repo // empty' "$CONFIG_DIR/source.json" 2>/dev/null) || repo=""
        sync="${GITHUB_SYNC_STATUS:-clean}"
    fi
    jq -cn --arg src "${CONFIG_SOURCE:-local}" --arg r "$repo" --arg s "$sync" \
        '{source:$src, repo:(if $r == "" then null else $r end), sync:(if $s == "" then null else $s end)}'
}

# session_open [REMEMBER_KEY] — секреты vault-password и script-password из
# RC_REQUEST_SECRETS. Решения вместо вопросов: *_required, *_invalid, auth_*.
session_open() {
    local remember="${1:-0}" stored passfile pw format extra
    if ! _session_configured; then
        rc_fail not_configured "Конфигурация не создана: source init-local или source github-connect."
        return 1
    fi
    if [[ "$RC_SESSION_OPEN" != 1 ]]; then
        GITHUB_SECRET_VAULT_PASSWORD=$(rc_secret vault-password) || GITHUB_SECRET_VAULT_PASSWORD=""
        GITHUB_DECISION_REMEMBER_KEY="$remember"
        rc_error_reset
        if ! config_source_startup; then
            unset GITHUB_SECRET_VAULT_PASSWORD
            [[ -n "$RC_ERROR_CODE" ]] && return 1
            format="${GITHUB_LAST_FORMAT:-}"
            if [[ -n "$format" ]]; then
                extra=$(jq -cn --arg v "${GITHUB_LAST_FORMAT_VERSION:-}" --arg r "${GITHUB_LAST_FORMAT_REQUIRED:-}" \
                    '{version:(if $v == "" then null else $v end), required:(if $r == "" then null else $r end)}')
                rc_fail "github_format_$format" "${GITHUB_LAST_ERROR:-Конфигурация GitHub требует восстановления.}" "$extra"
            else
                [[ -z "${GITHUB_LAST_STAGE:-}" ]] ||
                    _github_report_last_error "Не удалось открыть источник GitHub"
                rc_fail source_failed "${GITHUB_LAST_ERROR:-Не удалось открыть источник конфигурации.}"
            fi
            return 1
        fi
        unset GITHUB_SECRET_VAULT_PASSWORD
        RC_SESSION_OPEN=1
    fi
    if [[ "$RC_SESSION_AUTHORIZED" != 1 ]]; then
        passfile=$(_script_pass_file)
        stored=""
        [[ -f "$passfile" ]] && stored=$(tr -d '\r\n' < "$passfile")
        if [[ -n "$stored" ]]; then
            if ! pw=$(rc_secret script-password); then
                rc_fail auth_required "Требуется пароль запуска."
                return 1
            fi
            if ! _verify_pass "$stored" "$pw"; then
                rc_fail auth_failed "Неверный пароль запуска."
                return 1
            fi
        fi
        RC_SESSION_AUTHORIZED=1
    fi
    return 0
}

# Только разовый CLI: секреты сессии — из RC_SESSION_SCRIPT_PASSWORD/
# RC_SESSION_VAULT_PASSWORD (cli_main забирает их из RC_SCRIPT_PASSWORD/
# RC_VAULT_PASSWORD и убирает из окружения),
# а если stdin был терминалом — скрытым вводом с /dev/tty (до 3 попыток).
# Секреты команды на время вызова подменяются и затем восстанавливаются.
session_open_from_transport() {
    local remember="${1:-0}" saved="${RC_REQUEST_SECRETS:-}" secrets='{}' rc pw
    local script_tries=0 vault_tries=0
    [[ -z "$RC_SESSION_SCRIPT_PASSWORD" ]] ||
        secrets=$(_rc_secrets_add "$secrets" script-password "$RC_SESSION_SCRIPT_PASSWORD")
    [[ -z "$RC_SESSION_VAULT_PASSWORD" ]] ||
        secrets=$(_rc_secrets_add "$secrets" vault-password "$RC_SESSION_VAULT_PASSWORD")
    while :; do
        RC_REQUEST_SECRETS="$secrets"
        rc=0
        session_open "$remember" || rc=$?
        RC_REQUEST_SECRETS="$saved"
        (( rc == 0 )) && return 0
        [[ "$RC_SESSION_TTY_PROMPT" == 1 ]] && _rc_tty_available || return 1
        pw=""
        case "$RC_ERROR_CODE" in
            auth_required|auth_failed)
                (( script_tries < 3 )) || return 1
                script_tries=$((script_tries + 1))
                IFS= read -rsp "  Введите пароль: " pw </dev/tty || { printf '\n' >&2; return 1; }
                printf '\n' >&2
                secrets=$(_rc_secrets_add "$secrets" script-password "$pw")
                ;;
            vault_password_required|vault_password_invalid)
                (( vault_tries < 3 )) || return 1
                vault_tries=$((vault_tries + 1))
                IFS= read -rsp "  Пароль доступа к конфигурации GitHub: " pw </dev/tty ||
                    { printf '\n' >&2; return 1; }
                printf '\n' >&2
                secrets=$(_rc_secrets_add "$secrets" vault-password "$pw")
                ;;
            *) return 1 ;;
        esac
    done
}

# EXIT-очистка транспорта: отправить отложенное, закрыть GitHub, снять блокировку.
session_close() {
    if [[ "$RC_SESSION_OPEN" == 1 && "${CONFIG_SOURCE:-}" == github &&
          "${GITHUB_SYNC_STATUS:-}" == pending ]]; then
        github_sync_flush >/dev/null 2>&1 || true
    fi
    github_config_close >/dev/null 2>&1 || true
    rc_lock_release_all
    RC_SESSION_OPEN=0
    RC_SESSION_AUTHORIZED=0
}
