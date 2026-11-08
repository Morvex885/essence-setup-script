#!/bin/bash
# ─── Команды ядра: status, session, source ───────────────────────────────────
# Спецификации, справка и обработчики по существительным (см. modules/cli.sh).

# ─── status ──────────────────────────────────────────────────────────────────

cli_spec_status() {
    case "$1" in
        "") printf '' ;;
        *) return 1 ;;
    esac
}

_cli_help_status() {
    cat <<'EOF'
status|Сводка: версия, источник, счётчики, проблемы
EOF
}

cli_cmd_status() {
    local counts missing=() id name pending=false host source_json script_pw=false latest available=false
    counts=$(jq_r -c '{nodes:(.nodes|length),groups:(.groups|length),clients:(.clients|length)}')
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] || continue
        [[ "$(_cli_node_password_state "$id")" == ok ]] || missing+=("$name")
    done < <(jq_r '.nodes[] | select(.auth=="password") | [.id,.name] | @tsv')
    source_json=$(session_data_json | jq -c '{type:.source, repo:.repo, sync:.sync}')
    [[ "$CONFIG_SOURCE" != github ]] || ! state_actionable_ssh_setup_pending || pending=true
    host=$(jq_r '.subscription_host.node // null | tojson')
    [[ -n "$host" ]] || host=null
    latest=$(latest_version)
    has_update "${CURRENT_VERSION:-none}" && available=true
    _self_password_installed && script_pw=true
    CLI_DATA=$(jq -cn --arg v "${CURRENT_VERSION:-}" --arg latest "$latest" --argjson avail "$available" \
        --argjson src "$source_json" --argjson c "$counts" --argjson sp "$script_pw" \
        --argjson pm "$(_cli_json_array "${missing[@]}")" --argjson p "$pending" \
        --argjson h "$host" \
        '{version:$v,
          update:{current:$v, latest:(if $latest == "" then null else $latest end), available:$avail},
          script_password:$sp, source:$src, counts:$c, password_missing:$pm,
          ssh_setup_pending:$p, subscription_host:$h}')
}

# ─── session ─────────────────────────────────────────────────────────────────

cli_spec_session() {
    case "$1" in
        status) printf '!nosession' ;;
        open)   printf 'remember-key @vault-password @script-password !nosession' ;;
        *) return 1 ;;
    esac
}

_cli_help_session() {
    cat <<'EOF'
session status|Состояние: создана ли конфигурация, открыта ли сессия
session open [--remember-key]|Открыть источник и проверить пароль запуска (секреты script-password, vault-password)
EOF
}

cli_cmd_session_status() {
    CLI_DATA=$(session_status_json)
}

cli_cmd_session_open() {
    local remember=0
    cli_has remember-key && remember=1
    # Разовый CLI без секретов команды берёт их, как при любой команде: из
    # окружения или скрытым вводом с терминала.
    if [[ "${RC_SESSION_AUTO_OPEN:-0}" == 1 && "${RC_REQUEST_SECRETS:-{\}}" == "{}" ]]; then
        session_open_from_transport "$remember" || return 1
    else
        session_open "$remember" || return 1
    fi
    CLI_DATA=$(session_data_json)
}

# ─── source ──────────────────────────────────────────────────────────────────

cli_spec_source() {
    case "$1" in
        init-local)                 printf '!nosession' ;;
        status)                     printf '' ;;
        github-accounts)            printf '!nosession' ;;
        github-login)               printf 'login= !nosession' ;;
        github-connect)             printf 'login= create-repo make-private storage= existing= provision-keys= remember-key @vault-password @new-vault-password !nosession' ;;
        github-fetch|github-push)   printf '' ;;
        github-change-account)      printf 'login= create-repo make-private storage= existing= without-cache replace-target @vault-password @new-vault-password' ;;
        github-rewrap-password)     printf '@vault-password @new-vault-password' ;;
        github-rotate-key)          printf '@new-vault-password' ;;
        github-import-recovery-key) printf 'file=' ;;
        github-switch-local)        printf '' ;;
        github-replace-with-local)  printf 'provision-keys= @vault-password @script-password !nosession' ;;
        github-migrate-format)      printf '@vault-password @script-password !nosession' ;;
        github-delete-repo)         printf '' ;;
        *) return 1 ;;
    esac
}

_cli_help_source() {
    cat <<'EOF'
source init-local|Создать локальную конфигурацию
source status|Источник: тип, репозиторий, ветка, хранение, синхронизация
source github-accounts|Сохранённые аккаунты GitHub и глобальный вход gh
source github-login --login L|Войти в GitHub через браузер (код устройства — в журнале)
source github-connect --login L [--create-repo] [--make-private] [--storage age|none] [--existing remote|local|migrate] [--provision-keys yes|no] [--remember-key] [--yes]|Подключить GitHub (секреты vault-password, new-vault-password)
source github-fetch|Загрузить конфигурацию из GitHub
source github-push|Отправить конфигурацию в GitHub
source github-change-account --login L [--create-repo] [--make-private] [--storage age|none] [--existing remote|local] [--without-cache] [--replace-target] [--yes]|Сменить аккаунт GitHub (секреты vault-password, new-vault-password)
source github-rewrap-password|Сменить пароль доступа (секреты vault-password, new-vault-password)
source github-rotate-key [--yes]|Новый ключ шифрования (секрет new-vault-password)
source github-import-recovery-key --file PATH|Импортировать ключ восстановления для текущего сеанса
source github-switch-local|Работать локально без синхронизации с GitHub
source github-replace-with-local [--provision-keys yes|no] [--yes]|Заменить конфигурацию GitHub конфигурацией этого компьютера (секреты script-password, vault-password)
source github-migrate-format [--yes]|Преобразовать конфигурацию GitHub в текущий формат (секреты script-password, vault-password)
source github-delete-repo [--yes]|Удалить репозиторий GitHub (конфигурация останется локально)
EOF
}

# Первая настройка (конфигурации ещё нет): при любом сбое команда удаляет всё,
# что создала в CONFIG_DIR, снимает свои блокировки и возвращает глобалы сессии,
# чтобы следующий запуск снова начался с первой настройки. Пути, существовавшие
# до команды (например, профиль из source github-login), не трогаются.
_CLI_FRESH_DIR_EXISTED=false
_CLI_FRESH_PATHS=""
_CLI_FRESH_LOCK_DEPTH=0
_CLI_FRESH_SESSION_OPEN=0
_CLI_FRESH_SESSION_AUTHORIZED=0

# До захвата блокировки (она сама создаёт CONFIG_DIR).
_cli_source_fresh_begin() {
    _CLI_FRESH_DIR_EXISTED=false
    [[ -d "$CONFIG_DIR" ]] && _CLI_FRESH_DIR_EXISTED=true
    _CLI_FRESH_PATHS=""
    _CLI_FRESH_LOCK_DEPTH="$_RC_LOCK_DEPTH"
    _CLI_FRESH_SESSION_OPEN="${RC_SESSION_OPEN:-0}"
    _CLI_FRESH_SESSION_AUTHORIZED="${RC_SESSION_AUTHORIZED:-0}"
}

# Под блокировкой: конфигурация могла появиться в другом процессе, пока мы ждали;
# снимок путей берётся только после этой проверки.
_cli_source_fresh_locked() {
    if _session_configured; then
        (( _CLI_FRESH_LOCK_DEPTH > 0 )) || rc_lock_release_all
        rc_fail conflict "Конфигурация уже создана другим процессом."
        return 1
    fi
    _CLI_FRESH_PATHS=$(find "${CONFIG_DIR%/}" -mindepth 1 -print 2>/dev/null)
}

# _cli_source_fresh_prune DIR — удалить в DIR пути, которых не было в снимке.
_cli_source_fresh_prune() {
    local entry ok=0
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case $'\n'"$_CLI_FRESH_PATHS"$'\n' in
            *$'\n'"$entry"$'\n'*)
                if [[ -d "$entry" && ! -L "$entry" ]]; then
                    _cli_source_fresh_prune "$entry" || ok=1
                fi
                ;;
            *) rm -rf -- "$entry" || ok=1 ;;
        esac
    done
    return "$ok"
}

# Удаление идёт под своей блокировкой (её каталог есть в снимке), затем снимается.
_cli_source_fresh_rollback() {
    local root="${CONFIG_DIR%/}"
    if [[ -n "$root" && -d "$root" ]] && ! _cli_source_fresh_prune "$root"; then
        warn "Не удалось полностью удалить незавершённую конфигурацию: $CONFIG_DIR"
    fi
    (( _CLI_FRESH_LOCK_DEPTH > 0 )) || rc_lock_release_all
    [[ "$_CLI_FRESH_DIR_EXISTED" == true || -z "$root" ]] || rmdir "$root" 2>/dev/null || true
    RC_SESSION_OPEN="$_CLI_FRESH_SESSION_OPEN"
    RC_SESSION_AUTHORIZED="$_CLI_FRESH_SESSION_AUTHORIZED"
    CONFIG_SOURCE=local
    _CLI_FRESH_PATHS=""
}

cli_cmd_source_init_local() {
    if _session_configured; then
        rc_fail conflict "Конфигурация уже создана."
        return 1
    fi
    _cli_source_fresh_begin
    rc_lock_acquire mutation open-local || return 1
    _cli_source_fresh_locked || return 1
    if ! state_open_local; then
        _cli_source_fresh_rollback
        return 1
    fi
    rc_lock_release
    _CLI_FRESH_PATHS=""
    CONFIG_SOURCE=local
    RC_SESSION_OPEN=1
    _session_script_password_set || RC_SESSION_AUTHORIZED=1
    CLI_DATA=$(jq -cn --arg d "$CONFIG_DIR" '{source:"local",config_dir:$d}')
    success "Локальная конфигурация создана: $CONFIG_DIR"
}

# Флаги команды → решения ядра GITHUB_DECISION_* (таблица шага 2.8), секреты →
# GITHUB_SECRET_*. Сбрасываются диспетчером перед каждой командой.
_cli_source_decisions() {
    local value
    cli_has login && GITHUB_DECISION_LOGIN=$(cli_opt login)
    cli_has create-repo && GITHUB_DECISION_CREATE_REPO=1
    cli_has make-private && GITHUB_DECISION_MAKE_PRIVATE=1
    cli_has remember-key && GITHUB_DECISION_REMEMBER_KEY=1
    cli_has without-cache && GITHUB_DECISION_WITHOUT_CACHE=1
    cli_has replace-target && GITHUB_DECISION_REPLACE_TARGET=1
    if cli_has storage; then
        value=$(cli_opt storage)
        case "$value" in
            age|none) GITHUB_DECISION_STORAGE="$value" ;;
            *) rc_fail usage "Флаг --storage принимает age или none."; return 1 ;;
        esac
    fi
    if cli_has existing; then
        value=$(cli_opt existing)
        case "$value" in
            remote|local|migrate) GITHUB_DECISION_EXISTING="$value" ;;
            *) rc_fail usage "Флаг --existing принимает remote, local или migrate."; return 1 ;;
        esac
    fi
    if cli_has provision-keys; then
        value=$(cli_opt provision-keys)
        case "$value" in
            yes|no) GITHUB_DECISION_PROVISION_KEYS="$value" ;;
            *) rc_fail usage "Флаг --provision-keys принимает yes или no."; return 1 ;;
        esac
    fi
    GITHUB_SECRET_VAULT_PASSWORD=$(rc_secret vault-password) || GITHUB_SECRET_VAULT_PASSWORD=""
    GITHUB_SECRET_NEW_VAULT_PASSWORD=$(rc_secret new-vault-password) || GITHUB_SECRET_NEW_VAULT_PASSWORD=""
}

# Сбой операции GitHub: решение или код уже выставлены ядром, иначе CODE
# (по умолчанию source_failed) с последней ошибкой GitHub.
_cli_source_fail() {
    local prefix="$1" code="${2:-source_failed}"
    [[ -n "${RC_ERROR_CODE:-}" ]] && return 1
    [[ -z "${GITHUB_LAST_HINT:-}" ]] || warn "$GITHUB_LAST_HINT"
    rc_fail "$code" "${prefix} (этап: ${GITHUB_LAST_STAGE:-неизвестный этап}): ${GITHUB_LAST_ERROR:-причина не указана}"
    return 1
}

_cli_source_require_github() {
    [[ "${CONFIG_SOURCE:-local}" == github ]] && return 0
    rc_fail not_ready "Источник GitHub не подключён: source github-connect --login LOGIN."
    return 1
}

_cli_source_require_age() {
    _cli_source_require_github || return 1
    [[ "${GITHUB_STORAGE_MODE:-none}" == age ]] && return 0
    rc_fail not_ready "Конфигурация GitHub хранится без шифрования."
    return 1
}

_cli_source_sync_data() {
    CLI_DATA=$(jq -cn --arg s "${GITHUB_SYNC_STATUS:-clean}" '{sync:$s}')
}

cli_cmd_source_status() {
    local type="${CONFIG_SOURCE:-local}" repo="" branch="" storage="" sync="" key=null
    if [[ "$type" == github ]]; then
        repo=$(jq -r '.repo // empty' "$CONFIG_DIR/source.json" 2>/dev/null) || repo=""
        branch=$(jq -r '.branch // empty' "$CONFIG_DIR/source.json" 2>/dev/null) || branch=""
        storage="${GITHUB_STORAGE_MODE:-}"
        sync="${GITHUB_SYNC_STATUS:-clean}"
        if [[ "$storage" == age ]]; then
            key=false
            [[ -f "$GITHUB_UNLOCK_FILE" && ! -L "$GITHUB_UNLOCK_FILE" ]] && key=true
        fi
    fi
    CLI_DATA=$(jq -cn --arg t "$type" --arg r "$repo" --arg b "$branch" --arg st "$storage" \
        --arg s "$sync" --argjson k "$key" '
        def opt: if . == "" then null else . end;
        {type:$t, repo:($r|opt), branch:($b|opt), storage:($st|opt), sync:($s|opt), key_saved:$k}')
}

cli_cmd_source_github_accounts() {
    local dir name global=""
    local -a accounts=()
    for dir in "$GITHUB_CREDENTIALS_DIR"/gh/*; do
        [[ -d "$dir" && ! -L "$dir" && -f "$dir/hosts.yml" ]] || continue
        name="${dir##*/}"
        [[ "$name" =~ ^[A-Za-z0-9-]+$ ]] && accounts+=("$name")
    done
    _github_load_global_login && global="$GITHUB_GLOBAL_LOGIN"
    CLI_DATA=$(jq -cn --argjson a "$(_cli_json_array "${accounts[@]}")" --arg g "$global" \
        '{accounts:$a, global_login:(if $g == "" then null else $g end)}')
}

cli_cmd_source_github_login() {
    local login
    cli_require_value login || return 1
    login=$(cli_opt login)
    github_login_web "$login" || { _cli_source_fail "Не удалось войти в GitHub" github_auth_required; return 1; }
    CLI_DATA=$(jq -cn --arg l "$login" '{login:$l}')
    success "Вход в GitHub выполнен: $login."
}

cli_cmd_source_github_connect() {
    local rc=0 fresh=false lock_depth="$_RC_LOCK_DEPTH"
    # Host keys approved in this command's plan only (serve keeps globals).
    local ONBOARDING_PLANNED_FPS=""
    cli_require_value login || return 1
    if _session_configured; then
        if [[ "${RC_SESSION_AUTHORIZED:-0}" != 1 ]]; then
            if [[ "${RC_SESSION_AUTO_OPEN:-0}" == 1 ]]; then
                session_open_from_transport || return 1
            else
                rc_fail session_closed "Сначала откройте сессию: session open."
                return 1
            fi
        fi
        if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
            rc_fail conflict "Источник GitHub уже подключён."
            return 1
        fi
        lock_depth="$_RC_LOCK_DEPTH"
    else
        fresh=true
    fi
    # После открытия сессии: session_open выставляет свои GITHUB_SECRET_*/DECISION_*.
    _cli_source_decisions || return 1
    [[ "$fresh" != true ]] || _cli_source_fresh_begin
    rc_lock_acquire session github-session || return 1
    if [[ "$fresh" == true ]]; then
        _cli_source_fresh_locked || return 1
    fi
    CONFIG_SOURCE=local
    state_action github_enable github_enable_local || rc=$?
    unset GITHUB_SECRET_VAULT_PASSWORD GITHUB_SECRET_NEW_VAULT_PASSWORD
    if (( rc != 0 )); then
        _cli_source_fail "Не удалось подключить GitHub"
        # github_enable_local откатывает свои сбои сам; если он прошёл, а следующий
        # шаг state_action — нет, откат тот же (github_enable_abort).
        github_enable_abort
        # Первое подключение не оставляет конфигурацию: повтор и следующий запуск
        # начинаются с первой настройки. Иначе остаётся прежняя локальная сессия.
        if [[ "$fresh" == true ]]; then
            _cli_source_fresh_rollback
        else
            (( lock_depth > 0 )) || rc_lock_release_all
        fi
        return 1
    fi
    github_enable_commit
    _CLI_FRESH_PATHS=""
    RC_SESSION_OPEN=1
    # Пароль запуска из конфигурации GitHub спросит следующий session open.
    if [[ "$fresh" == true ]]; then
        RC_SESSION_AUTHORIZED=1
        ! _session_script_password_set || RC_SESSION_AUTHORIZED=0
    fi
    CLI_DATA=$(jq -cn --arg r "$(_github_repo)" --arg st "${GITHUB_STORAGE_MODE:-}" \
        --arg s "${GITHUB_SYNC_STATUS:-clean}" '{repo:$r, storage:$st, sync:$s}')
    success "Источник GitHub подключён."
}

cli_cmd_source_github_fetch() {
    _cli_source_require_github || return 1
    if ! github_sync_fetch; then
        _cli_source_fail "Не удалось загрузить конфигурацию из GitHub" remote_failed
        return 1
    fi
    _cli_source_sync_data
    success "Конфигурация загружена из GitHub."
}

cli_cmd_source_github_push() {
    _cli_source_require_github || return 1
    if ! github_sync_flush; then
        GITHUB_SYNC_STATUS=pending
        warn "Изменения сохранены локально и ожидают отправки."
        _cli_source_fail "Не удалось отправить конфигурацию в GitHub" remote_failed
        return 1
    fi
    _cli_source_sync_data
    success "Локальная конфигурация отправлена в GitHub."
}

cli_cmd_source_github_change_account() {
    local rc=0
    _cli_source_require_github || return 1
    cli_require_value login || return 1
    _cli_source_decisions || return 1
    github_source_change_account || rc=$?
    unset GITHUB_SECRET_VAULT_PASSWORD GITHUB_SECRET_NEW_VAULT_PASSWORD
    (( rc == 0 )) || { _cli_source_fail "Не удалось сменить аккаунт GitHub"; return 1; }
    CLI_DATA=$(jq -cn --arg r "$(_github_repo)" --arg s "${GITHUB_SYNC_STATUS:-clean}" \
        --arg u "${GITHUB_OLD_REPO_SETTINGS_URL:-}" \
        '{repo:$r, sync:$s, old_repo_settings_url:(if $u == "" then null else $u end)}')
}

cli_cmd_source_github_rewrap_password() {
    local rc=0
    _cli_source_require_age || return 1
    _cli_source_decisions || return 1
    github_config_rewrap_master || rc=$?
    unset GITHUB_SECRET_VAULT_PASSWORD GITHUB_SECRET_NEW_VAULT_PASSWORD
    (( rc == 0 )) || { _cli_source_fail "Не удалось изменить пароль доступа"; return 1; }
    _cli_source_sync_data
    success "Пароль доступа изменён; ключ шифрования остался прежним."
}

cli_cmd_source_github_rotate_key() {
    local rc=0
    _cli_source_require_age || return 1
    _cli_source_decisions || return 1
    github_config_rotate_vault_key || rc=$?
    unset GITHUB_SECRET_VAULT_PASSWORD GITHUB_SECRET_NEW_VAULT_PASSWORD
    (( rc == 0 )) || { _cli_source_fail "Не удалось создать новый ключ шифрования"; return 1; }
    _cli_source_sync_data
    success "Новый ключ создан; текущая конфигурация зашифрована заново."
}

cli_cmd_source_github_import_recovery_key() {
    _cli_source_require_age || return 1
    cli_require_value file || return 1
    if ! github_config_import_recovery "$(cli_opt file)"; then
        _cli_source_fail "Не удалось импортировать ключ восстановления" invalid
        return 1
    fi
    CLI_DATA='{}'
    success "Ключ восстановления импортирован для текущего сеанса."
}

cli_cmd_source_github_switch_local() {
    local rc=0
    _cli_source_require_github || return 1
    github_config_switch_local || rc=$?
    # Local mode keeps no session lock: other processes wait per mutation.
    [[ "${CONFIG_SOURCE:-}" != local ]] || rc_lock_release_all
    if (( rc != 0 )); then
        _cli_source_fail "Не удалось перейти на локальную конфигурацию"
        return 1
    fi
    CLI_DATA='{"source":"local"}'
    success "Используется локальная конфигурация; синхронизация с GitHub отключена."
}

cli_cmd_source_github_delete_repo() {
    local repo url rc=0
    _cli_source_require_github || return 1
    repo=$(_github_repo)
    CORE_PLAN_LINES=("Будет удалён репозиторий GitHub: $repo."
        "Конфигурация останется локально, синхронизация будет отключена.")
    rc_confirm_gate || return 1
    github_repository_delete "$repo" || rc=$?
    # The local switch precedes the remote delete: drop the session lock either way.
    [[ "${CONFIG_SOURCE:-}" != local ]] || rc_lock_release_all
    if (( rc != 0 )); then
        if [[ "${GITHUB_LAST_STAGE:-}" == "удаление репозитория GitHub" ]]; then
            url="https://github.com/$repo/settings"
            rc_fail remote_failed \
                "Не удалось удалить репозиторий $repo (${GITHUB_LAST_ERROR:-причина не указана}): завершите удаление в Danger Zone: $url" \
                "$(jq -cn --arg u "$url" '{settings_url:$u}')"
            return 1
        fi
        _cli_source_fail "Не удалось удалить репозиторий GitHub"
        return 1
    fi
    CLI_DATA=$(jq -cn --arg r "$repo" '{repo:$r, deleted:true}')
    success "Репозиторий $repo удалён. Конфигурация сохранена локально, синхронизация отключена."
}

# Команды восстановления (!nosession): свой пароль запуска (секрет
# script-password), затем источник открывается как обычно; при ошибке формата
# GitHub остаётся SOURCE_RECOVERY_MODE=recovery и GITHUB_LAST_FORMAT*.
_cli_source_recovery_open() {
    local stored pw
    SOURCE_RECOVERY_MODE=menu
    if ! _session_configured; then
        rc_fail not_configured "Конфигурация не создана: source init-local или source github-connect."
        return 1
    fi
    if [[ "${RC_SESSION_AUTHORIZED:-0}" != 1 ]] && _session_script_password_set; then
        stored=$(tr -d '\r\n' < "$(_script_pass_file)")
        if ! pw=$(rc_secret script-password); then
            rc_fail auth_required "Требуется пароль запуска (секрет script-password)."
            return 1
        fi
        if ! _verify_pass "$stored" "$pw"; then
            rc_fail auth_failed "Неверный пароль запуска."
            return 1
        fi
        RC_SESSION_AUTHORIZED=1
    fi
    [[ "${RC_SESSION_OPEN:-0}" == 1 ]] && return 0
    rc_error_reset
    if config_source_startup; then
        RC_SESSION_OPEN=1
        return 0
    fi
    [[ -n "${RC_ERROR_CODE:-}" ]] && return 1
    if [[ "${CONFIG_SOURCE:-local}" == github && -n "${GITHUB_LAST_FORMAT:-}" ]]; then
        SOURCE_RECOVERY_MODE=recovery
        return 0
    fi
    rc_fail source_failed "${GITHUB_LAST_ERROR:-Не удалось открыть источник конфигурации.}"
    return 1
}

# Итог публикации восстановления: rc 0 — рабочее состояние обновлено, 3 —
# опубликовано без него. Пароль запуска из опубликованной конфигурации
# проверит следующий session open.
_cli_source_recovery_done() {
    local rc="$1" auth_before="$2" refreshed=true
    if (( rc == 3 )); then
        refreshed=false
        # Прежнее рабочее состояние не должно попасть в GitHub следующей командой:
        # до session open команды отвечают session_closed, а открытие готовит
        # состояние заново. Рабочая копия с неотправленным commit остаётся.
        RC_SESSION_OPEN=0
        [[ "${GITHUB_SYNC_STATUS:-}" == pending ]] || github_config_close >/dev/null 2>&1 || true
        warn "Конфигурация GitHub опубликована, но рабочее состояние не обновилось: откройте сессию заново (session open)."
    else
        RC_SESSION_OPEN=1
    fi
    [[ "$(cat "$(_script_pass_file)" 2>/dev/null || true)" == "$auth_before" ]] || RC_SESSION_AUTHORIZED=0
    CLI_DATA=$(jq -cn --argjson r "$refreshed" '{published:true, refreshed:$r}')
}

cli_cmd_source_github_replace_with_local() {
    local rc=0 auth_before ONBOARDING_PLANNED_FPS=""
    _cli_source_decisions || return 1
    _cli_source_recovery_open || return 1
    _cli_source_require_github || return 1
    if [[ "$SOURCE_RECOVERY_MODE" == recovery && "$GITHUB_LAST_FORMAT" == newer ]]; then
        rc_fail not_ready "Конфигурация GitHub создана более новой версией remote-control: обновите remote-control (self update)."
        return 1
    fi
    auth_before=$(cat "$(_script_pass_file)" 2>/dev/null || true)
    github_replace_with_local_action "$SOURCE_RECOVERY_MODE" || rc=$?
    unset GITHUB_SECRET_VAULT_PASSWORD GITHUB_SECRET_NEW_VAULT_PASSWORD
    if (( rc != 0 && rc != 3 )); then
        _cli_source_fail "Не удалось заменить конфигурацию GitHub"
        return 1
    fi
    _cli_source_recovery_done "$rc" "$auth_before"
    success "Конфигурация GitHub заменена конфигурацией только этого компьютера."
}

cli_cmd_source_github_migrate_format() {
    local rc=0 auth_before from
    _cli_source_decisions || return 1
    _cli_source_recovery_open || return 1
    if [[ "$SOURCE_RECOVERY_MODE" != recovery || "${GITHUB_LAST_FORMAT:-}" != outdated ]]; then
        rc_fail not_ready "Конфигурация GitHub не требует преобразования формата."
        return 1
    fi
    from="$GITHUB_LAST_FORMAT_VERSION"
    auth_before=$(cat "$(_script_pass_file)" 2>/dev/null || true)
    github_format_migrate_action "$from" || rc=$?
    unset GITHUB_SECRET_VAULT_PASSWORD GITHUB_SECRET_NEW_VAULT_PASSWORD
    if (( rc != 0 && rc != 3 )); then
        _cli_source_fail "Не удалось преобразовать конфигурацию GitHub"
        return 1
    fi
    _cli_source_recovery_done "$rc" "$auth_before"
    success "Конфигурация GitHub преобразована в формат v${GITHUB_VAULT_FORMAT}."
}

# ─── self ────────────────────────────────────────────────────────────────────

cli_spec_self() {
    case "$1" in
        version)         printf '!nosession' ;;
        update)          printf '' ;;
        uninstall)       printf 'remove-data' ;;
        password-set)    printf '@password @current-password' ;;
        password-remove) printf '@current-password' ;;
        *) return 1 ;;
    esac
}

_cli_help_self() {
    cat <<'EOF'
self version|Текущая и последняя версия
self update [--yes]|Обновить remote-control до последней версии
self uninstall [--remove-data] [--yes]|Удалить remote-control (данные сохраняются без --remove-data)
self password-set|Установить или сменить пароль запуска (секреты password, current-password)
self password-remove [--yes]|Убрать пароль запуска (секрет current-password)
EOF
}

cli_cmd_self_version() {
    local checked=false available=false
    core_self_version_fetch && checked=true
    if [[ "$checked" == true ]] && _ver_gt "${SELF_LATEST_VERSION#v}" "${CURRENT_VERSION#v}"; then
        available=true
    fi
    CLI_DATA=$(jq -cn --arg c "${CURRENT_VERSION:-}" --arg l "$SELF_LATEST_VERSION" \
        --argjson a "$available" --argjson k "$checked" \
        '{current:$c, latest:(if $l == "" then null else $l end), update_available:$a, checked:$k}')
}

cli_cmd_self_update() {
    core_self_update_plan || return 1
    rc_confirm_gate || return 1
    core_self_update || return 1
    CLI_DATA=$(jq -cn --arg f "${CURRENT_VERSION:-}" '{from:$f, restart_required:true}')
}

cli_cmd_self_uninstall() {
    local remove=0
    cli_has remove-data && remove=1
    core_self_uninstall_plan "$remove" || return 1
    rc_confirm_gate || return 1
    core_self_uninstall "$remove" || return 1
    CLI_DATA=$(jq -cn --argjson r "$(_cli_json_array "${SELF_REMOVED[@]}")" \
        --argjson kept "$([[ $remove == 1 ]] && echo false || echo true)" --arg p "$SELF_DATA_PATH" \
        '{removed:$r, data_kept:$kept, data_path:$p}')
}

cli_cmd_self_password_set() {
    local new
    core_self_password_check_current || return 1
    new=$(rc_secret password) || new=""
    core_self_password_set "$new" || return 1
    CLI_DATA=$(jq -cn '{password_set:true}')
}

cli_cmd_self_password_remove() {
    core_self_password_check_current || return 1
    CORE_PLAN_LINES=("Пароль запуска remote-control будет удалён." "Локальные данные и SSH-ключи сохранятся.")
    rc_confirm_gate || return 1
    core_self_password_remove || return 1
    CLI_DATA=$(jq -cn '{password_set:false}')
}
