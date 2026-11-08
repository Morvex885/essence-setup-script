#!/bin/bash
# ─── Источник конфигурации: локальный каталог или репозиторий GitHub ─────────
#
# Открытие источника (config_source_startup), материализация снимка GitHub в
# рабочие файлы, подключение GitHub, смена аккаунта, восстановление формата.
# Вызывается ядром (session.sh, команды source) и старым TUI entrypoint.

_materialize_script_auth_from_state() {
    local logical="$1" password_hash tmp
    password_hash=$(jq -er '
        .access.script_password_hash as $hash |
        if $hash == null then "" elif ($hash | type) == "string" then $hash
        else error("invalid script password hash") end
    ' "$logical" 2>/dev/null) || {
        _github_record_error "восстановление пароля запуска" \
            "Не удалось прочитать пароль запуска из конфигурации GitHub."
        return 1
    }
    if [[ -z "$password_hash" ]]; then
        if ! rm -f "$SCRIPT_AUTH_FILE"; then
            _github_record_error "восстановление пароля запуска" \
                "Не удалось удалить локальный пароль запуска."
            return 1
        fi
        return 0
    fi
    if ! _script_password_hash_salt "$password_hash" >/dev/null; then
        _github_record_error "восстановление пароля запуска" \
            "Хеш пароля запуска в состоянии GitHub имеет некорректный формат."
        return 1
    fi
    tmp=$(umask 077; mktemp "$CONFIG_DIR/.auth.XXXXXX") || {
        _github_record_error "восстановление пароля запуска" \
            "Не удалось создать защищённый временный файл пароля запуска."
        return 1
    }
    if ! printf '%s\n' "$password_hash" > "$tmp" ||
       ! chmod 600 "$tmp" || ! mv "$tmp" "$SCRIPT_AUTH_FILE"; then
        rm -f "$tmp"
        _github_record_error "восстановление пароля запуска" \
            "Не удалось сохранить пароль запуска из конфигурации GitHub."
        return 1
    fi
}

_config_source_materialize_state() {
    local logical="${1:?logical state}" runtime="${2:-$CONFIG_DIR/github-runtime}"
    local stage publish retired="" auth_backup="" names name id
    local old_source="${CONFIG_SOURCE:-}" old_state="${STATE_DIR:-}"
    local old_config="${CONFIG_JSON:-}" old_secrets="${SECRETS_JSON:-}"
    local old_manifest="${STATE_MANIFEST:-}" old_templates="${TEMPLATES_DIR:-}"
    local old_identities="${SSH_IDENTITIES_DIR:-}" old_hosts="${SSH_KNOWN_HOSTS:-}"
    local old_auth_file="${SCRIPT_AUTH_FILE:-}" had_runtime=false had_auth=false
    local rollback_ok=true rollback_backup_preserved=false
    github_config_validate "$logical" || return 1
    stage=$(umask 077; mktemp -d "$CONFIG_DIR/.github-runtime.stage.XXXXXX") || {
        _github_record_error "подготовка рабочего состояния" \
            "Не удалось создать защищённый каталог staging."
        return 1
    }
    if ! mkdir -p "$stage/templates" "$stage/ssh/identities" ||
       ! jq -e '.config' "$logical" > "$stage/config.json" ||
       ! jq -e '.secrets' "$logical" > "$stage/.portable-secrets.json" ||
       ! chmod 600 "$stage/.portable-secrets.json" ||
       ! _state_secrets_import_portable "$stage/.portable-secrets.json" "$stage/secrets.json" ||
       ! rm -f "$stage/.portable-secrets.json" ||
       ! jq -e '{schema_version:2,minimum_remote_control_version,portability,templates,access}' \
            "$logical" > "$stage/manifest.json" ||
       ! jq -j '.ssh.known_hosts // ""' "$logical" > "$stage/ssh/known_hosts"; then
        rm -rf "$stage"
        _github_record_error "подготовка рабочего состояния" \
            "Не удалось извлечь файлы рабочего состояния из логического снимка."
        return 1
    fi
    names="$stage/.templates.list"
    if ! jq -r '.templates // {} | keys[]' "$logical" > "$names"; then
        rm -rf "$stage"
        _github_record_error "подготовка шаблонов" \
            "Не удалось прочитать список шаблонов."
        return 1
    fi
    while IFS= read -r name; do
        if [[ ! "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] ||
           ! jq -j --arg n "$name" '.templates[$n].content // ""' "$logical" \
                > "$stage/templates/$name"; then
            rm -rf "$stage"
            _github_record_error "подготовка шаблонов" \
                "Не удалось безопасно восстановить шаблон: $name"
            return 1
        fi
    done < "$names"
    if ! rm -f "$names"; then
        rm -rf "$stage"
        return 1
    fi
    names="$stage/.identities.list"
    if ! jq -r '.ssh.identities // {} | keys[]' "$logical" > "$names"; then
        rm -rf "$stage"
        _github_record_error "подготовка SSH-ключей" \
            "Не удалось прочитать список SSH-ключей."
        return 1
    fi
    while IFS= read -r id; do
        if [[ ! "$id" =~ ^[0-9a-fA-F]{32}$ ]] ||
           ! jq -j --arg n "$id" '.ssh.identities[$n].private // ""' "$logical" \
                > "$stage/ssh/identities/$id" ||
           ! jq -j --arg n "$id" '.ssh.identities[$n].public // ""' "$logical" \
                > "$stage/ssh/identities/$id.pub"; then
            rm -rf "$stage"
            _github_record_error "подготовка SSH-ключей" \
                "Не удалось безопасно восстановить SSH-ключ: $id"
            return 1
        fi
    done < "$names"
    if ! rm -f "$names" ||
       ! chmod 700 "$stage" "$stage/templates" "$stage/ssh" \
            "$stage/ssh/identities" ||
       ! chmod 600 "$stage/config.json" "$stage/secrets.json" \
            "$stage/manifest.json" "$stage/ssh/known_hosts"; then
        rm -rf "$stage"
        _github_record_error "защита рабочего состояния" \
            "Не удалось установить безопасные права доступа."
        return 1
    fi
    for name in "$stage"/templates/*.yaml; do
        [[ -e "$name" ]] || continue
        if ! chmod 644 "$name"; then
            rm -rf "$stage"
            return 1
        fi
    done
    for name in "$stage"/ssh/identities/*; do
        [[ -e "$name" ]] || continue
        case "$name" in
            *.pub) chmod 644 "$name" || { rm -rf "$stage"; return 1; } ;;
            *) chmod 600 "$name" || { rm -rf "$stage"; return 1; } ;;
        esac
    done
    CONFIG_SOURCE=github
    STATE_DIR="$stage"
    CONFIG_JSON="$stage/config.json"
    SECRETS_JSON="$stage/secrets.json"
    STATE_MANIFEST="$stage/manifest.json"
    TEMPLATES_DIR="$stage/templates"
    SSH_IDENTITIES_DIR="$stage/ssh/identities"
    SSH_KNOWN_HOSTS="$stage/ssh/known_hosts"
    SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    if ! state_validate true >/dev/null 2>&1; then
        CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
        SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
        TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_identities"
        SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth_file"
        rm -rf "$stage"
        _github_ensure_error "проверка рабочего состояния" \
            "Восстановленное состояние GitHub не прошло проверку."
        return 1
    fi
    CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
    SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
    TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_identities"
    SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth_file"
    publish=$(umask 077; mktemp -d "$CONFIG_DIR/.github-runtime.publish.XXXXXX") || {
        rm -rf "$stage"
        return 1
    }
    if ! cp -Rp "$stage/." "$publish/" || ! rm -rf "$stage"; then
        rm -rf "$stage" "$publish"
        _github_record_error "публикация рабочего состояния" \
            "Не удалось подготовить полную копию состояния к публикации."
        return 1
    fi
    if [[ -e "$runtime" || -L "$runtime" ]]; then
        if [[ ! -d "$runtime" || -L "$runtime" ]]; then
            rm -rf "$publish"
            _github_record_error "публикация рабочего состояния" \
                "Путь рабочего состояния имеет недопустимый тип."
            return 1
        fi
        had_runtime=true
        retired=$(umask 077; mktemp -d "$CONFIG_DIR/.github-runtime.retired.XXXXXX") || {
            rm -rf "$publish"
            return 1
        }
        rmdir "$retired" || { rm -rf "$publish" "$retired"; return 1; }
    fi
    if [[ -e "$CONFIG_DIR/.auth" || -L "$CONFIG_DIR/.auth" ]]; then
        if [[ ! -f "$CONFIG_DIR/.auth" || -L "$CONFIG_DIR/.auth" ]]; then
            rm -rf "$publish"
            _github_record_error "публикация пароля запуска" \
                "Локальный файл пароля имеет недопустимый тип."
            return 1
        fi
        had_auth=true
        auth_backup=$(umask 077; mktemp "$CONFIG_DIR/.auth.backup.XXXXXX") || {
            rm -rf "$publish"
            return 1
        }
        if ! cp "$CONFIG_DIR/.auth" "$auth_backup" || ! chmod 600 "$auth_backup"; then
            rm -rf "$publish"
            rm -f "$auth_backup"
            return 1
        fi
    fi
    if [[ "$had_runtime" == true ]] && ! mv "$runtime" "$retired"; then
        rm -rf "$publish" "$retired"
        rm -f "$auth_backup"
        _github_record_error "публикация рабочего состояния" \
            "Не удалось убрать прежнее рабочее состояние."
        return 1
    fi
    if ! mv "$publish" "$runtime"; then
        rollback_ok=true
        if [[ "$had_runtime" == true ]] && ! mv "$retired" "$runtime"; then
            rollback_ok=false
            rollback_backup_preserved=true
        fi
        if ! rm -rf "$publish"; then
            rollback_ok=false
        fi
        if [[ "$rollback_backup_preserved" != true && -n "$retired" ]] &&
           ! rm -rf "$retired"; then
            rollback_ok=false
        fi
        if [[ -n "$auth_backup" ]] && ! rm -f "$auth_backup"; then
            rollback_ok=false
            rollback_backup_preserved=true
        fi
        if [[ "$rollback_ok" == true ]]; then
            _github_record_error "публикация рабочего состояния" \
                "Не удалось атомарно опубликовать новое рабочее состояние."
        elif [[ "$rollback_backup_preserved" == true ]]; then
            _github_record_error "откат публикации рабочего состояния" \
                "Не удалось восстановить прежнее рабочее состояние после ошибки публикации. Резервные копии сохранены в $CONFIG_DIR."
        else
            _github_record_error "откат публикации рабочего состояния" \
                "Не удалось восстановить прежнее рабочее состояние после ошибки публикации."
        fi
        return 1
    fi
    SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    if ! _materialize_script_auth_from_state "$logical"; then
        local auth_stage="${GITHUB_LAST_STAGE:-}" auth_detail="${GITHUB_LAST_ERROR:-}"
        rollback_ok=true
        rollback_backup_preserved=false
        if ! rm -rf "$runtime"; then
            rollback_ok=false
            rollback_backup_preserved=true
        else
            if [[ "$had_runtime" == true ]] && ! mv "$retired" "$runtime"; then
                rollback_ok=false
                rollback_backup_preserved=true
            fi
        fi
        if [[ "$had_auth" == true ]]; then
            if ! mv "$auth_backup" "$SCRIPT_AUTH_FILE"; then
                rollback_ok=false
                rollback_backup_preserved=true
            fi
        elif ! rm -f "$SCRIPT_AUTH_FILE"; then
            rollback_ok=false
        fi
        if [[ "$rollback_backup_preserved" != true ]]; then
            [[ -z "$retired" ]] || { rm -rf "$retired" || rollback_ok=false; }
            [[ -z "$auth_backup" ]] || { rm -f "$auth_backup" || rollback_ok=false; }
        fi
        if [[ "$rollback_ok" == true ]]; then
            GITHUB_LAST_STAGE="$auth_stage"
            GITHUB_LAST_ERROR="$auth_detail"
        elif [[ "$rollback_backup_preserved" == true ]]; then
            _github_record_error "откат рабочего состояния и пароля" \
                "Не удалось полностью восстановить рабочее состояние после ошибки пароля запуска. Резервные копии сохранены в $CONFIG_DIR."
        else
            _github_record_error "откат рабочего состояния и пароля" \
                "Не удалось полностью восстановить рабочее состояние после ошибки пароля запуска."
        fi
        return 1
    fi
    if ! rm -rf "$retired" || ! rm -f "$auth_backup"; then
        warn "Рабочее состояние опубликовано, но резервные файлы требуют ручной очистки."
    fi
    CONFIG_SOURCE=github
    STATE_DIR="$runtime"; CONFIG_JSON="$runtime/config.json"
    SECRETS_JSON="$runtime/secrets.json"; STATE_MANIFEST="$runtime/manifest.json"
    TEMPLATES_DIR="$runtime/templates"; SSH_IDENTITIES_DIR="$runtime/ssh/identities"
    SSH_KNOWN_HOSTS="$runtime/ssh/known_hosts"; SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    export CONFIG_SOURCE STATE_DIR CONFIG_JSON SECRETS_JSON STATE_MANIFEST
    export TEMPLATES_DIR SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE
    _state_warn_missing_passwords "$CONFIG_JSON" \
        "$(jq -c '.portability.issues' "$STATE_MANIFEST")"
    return 0
}
_config_source_materialize_github() {
    local logical="$CONFIG_DIR/runtime-vault.json" rc=0
    [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] || {
        _github_record_error "подготовка рабочей копии конфигурации" \
            "Рабочая копия конфигурации GitHub недоступна."
        return 1
    }
    if ! github_config_open "$GITHUB_WORKTREE" "$logical"; then
        rm -f "$logical"
        [[ -n "${GITHUB_LAST_STAGE:-}" ]] || _github_record_error "чтение конфигурации GitHub" \
            "Не удалось проверить или расшифровать состояние репозитория."
        return 1
    fi
    _config_source_materialize_state "$logical" "$CONFIG_DIR/github-runtime" || rc=$?
    # The decrypted snapshot is not kept: github-runtime/ is the only working copy.
    rm -f "$logical"
    if (( rc != 0 )); then
        [[ -n "${GITHUB_LAST_STAGE:-}" ]] || _github_record_error "подготовка рабочего состояния" \
            "Не удалось подготовить локальное рабочее состояние из конфигурации GitHub."
        return 1
    fi
}
_config_source_create_empty_snapshot() {
    local out="${1:?snapshot}" stage
    local old_source="$CONFIG_SOURCE" old_state="$STATE_DIR" old_config="$CONFIG_JSON"
    local old_secrets="$SECRETS_JSON" old_manifest="$STATE_MANIFEST"
    local old_templates="$TEMPLATES_DIR" old_ids="$SSH_IDENTITIES_DIR"
    local old_hosts="$SSH_KNOWN_HOSTS" old_auth="$SCRIPT_AUTH_FILE"
    stage=$(umask 077; mktemp -d "$CONFIG_DIR/.account-empty.XXXXXX") || return 1
    if ! mkdir -p "$stage/templates" "$stage/ssh/identities"; then rm -rf "$stage"; return 1; fi
    CONFIG_SOURCE=github; STATE_DIR="$stage"; CONFIG_JSON="$stage/config.json"
    SECRETS_JSON="$stage/secrets.json"; STATE_MANIFEST="$stage/manifest.json"
    TEMPLATES_DIR="$stage/templates"; SSH_IDENTITIES_DIR="$stage/ssh/identities"
    SSH_KNOWN_HOSTS="$stage/ssh/known_hosts"; SCRIPT_AUTH_FILE="$stage/.auth"
    if ! _ensure_config || ! _state_ensure_secrets || ! state_checkpoint ||
       ! state_validate false >/dev/null 2>&1 ||
       ! github_config_serialize "$out" "$CONFIG_JSON"; then
        CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
        SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
        TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_ids"
        SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"; rm -rf "$stage"
        return 1
    fi
    CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
    SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
    TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_ids"
    SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"; rm -rf "$stage"
}

# _config_source_publish_logical <logical> — write the snapshot to the worktree, push, materialize.
# Returns 1 when nothing was published, 3 when GitHub was updated but the runtime was not.
# On success the plaintext snapshot is deleted; otherwise the caller removes it.
_config_source_publish_logical() {
    local logical="${1:?logical state}"
    github_config_checkpoint "$logical" || return 1
    if ! github_sync_flush; then
        _github_report_last_error "Не удалось отправить конфигурацию в GitHub"
        warn "Изменения сохранены локально и ожидают отправки."
        GITHUB_SYNC_STATUS=pending
    fi
    if ! _config_source_materialize_state "$logical"; then
        _github_ensure_error "подготовка рабочего состояния" \
            "Конфигурация GitHub обновлена, но рабочее состояние не подготовлено."
        return 3
    fi
    rm -f "$logical"
}

# _github_plaintext_review_lines — fill GITHUB_PLAINTEXT_REVIEW_LINES with the notice for
# repositories stored without encryption (empty otherwise). No mapfile: Bash 3.2 is supported.
_github_plaintext_review_lines() {
    GITHUB_PLAINTEXT_REVIEW_LINES=()
    [[ "${GITHUB_STORAGE_MODE:-}" == none ]] || return 0
    GITHUB_PLAINTEXT_REVIEW_LINES=("Пароли SSH и ключи будут храниться в GitHub без шифрования"
        "и навсегда останутся в истории Git.")
}

# Connect and account-change plan (rc_confirm_gate before any write).
# _github_plan_begin TITLE — title, target repository and the repository action
# deferred by github_sync_init. GITHUB_PLAN_RISKY=true once a line needs consent:
# privatization, deleted files, a replaced configuration, plaintext storage or
# SSH actions on nodes. Repository creation alone does not.
_github_plan_begin() {
    CORE_PLAN_LINES=("$1" "Репозиторий: $(_github_repo) (ветка ${GITHUB_BRANCH})")
    GITHUB_PLAN_RISKY=false
    case "${GITHUB_REPO_PENDING:-}" in
        create) CORE_PLAN_LINES+=("Будет создан приватный репозиторий.") ;;
        private)
            CORE_PLAN_LINES+=("Публичный репозиторий станет приватным.")
            GITHUB_PLAN_RISKY=true
            ;;
    esac
}

# _github_plan_storage — storage of the configuration that will be published.
_github_plan_storage() {
    _github_plaintext_review_lines
    if [[ ${#GITHUB_PLAINTEXT_REVIEW_LINES[@]} -gt 0 ]]; then
        CORE_PLAN_LINES+=("${GITHUB_PLAINTEXT_REVIEW_LINES[@]}")
        GITHUB_PLAN_RISKY=true
    else
        CORE_PLAN_LINES+=("Хранение: зашифровано паролем доступа (age).")
    fi
}

# _github_plan_onboarding — SSH actions on the nodes of CONFIG_JSON before they move
# to GitHub (onboarding_plan_lines, hardening.sh): new portable keys and pinned
# server key fingerprints. The --provision-keys decision is required here.
_github_plan_onboarding() {
    local before=${#CORE_PLAN_LINES[@]} nodes
    ONBOARDING_PLANNED_FPS=""
    nodes=$(jq_r '.nodes // [] | length' 2>/dev/null) || nodes=0
    [[ "$nodes" =~ ^[1-9][0-9]*$ ]] || return 0
    onboarding_plan_lines "${GITHUB_DECISION_PROVISION_KEYS:-}" || return 1
    [[ ${#CORE_PLAN_LINES[@]} -eq $before ]] || GITHUB_PLAN_RISKY=true
}

# _github_plan_confirm — rc_confirm_gate when the plan needs consent.
_github_plan_confirm() {
    [[ "${GITHUB_PLAN_RISKY:-false}" == true ]] || return 0
    rc_confirm_gate
}

# _github_counts_json_label COUNTS_JSON — label of {nodes,clients,groups} or null.
_github_counts_json_label() {
    _github_counts_label "$(jq -r 'select(type == "object") | [.nodes,.clients,.groups] | @tsv' \
        <<< "${1:-null}" 2>/dev/null)"
}

# _config_source_with_local_state FN ARGS… — FN on the device-only state in
# CONFIG_DIR as a GitHub source; the source globals are restored afterwards.
_config_source_with_local_state() {
    local rc=0
    local old_source="$CONFIG_SOURCE" old_state="$STATE_DIR" old_config="$CONFIG_JSON"
    local old_secrets="$SECRETS_JSON" old_manifest="$STATE_MANIFEST"
    local old_templates="$TEMPLATES_DIR" old_ids="$SSH_IDENTITIES_DIR"
    local old_hosts="$SSH_KNOWN_HOSTS" old_auth="$SCRIPT_AUTH_FILE"
    CONFIG_SOURCE=github; STATE_DIR="$CONFIG_DIR"
    CONFIG_JSON="${LOCAL_CONFIG_JSON:-$CONFIG_DIR/config.json}"
    SECRETS_JSON="$CONFIG_DIR/secrets.json"; STATE_MANIFEST="$CONFIG_DIR/manifest.json"
    TEMPLATES_DIR="$CONFIG_DIR/templates"; SSH_IDENTITIES_DIR="$CONFIG_DIR/ssh/identities"
    SSH_KNOWN_HOSTS="$CONFIG_DIR/ssh/known_hosts"; SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    "$@" || rc=$?
    CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
    SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
    TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_ids"
    SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"
    return "$rc"
}

_config_source_local_snapshot_build() {
    _state_ensure_dirs && state_format_migrate && _state_ensure_secrets &&
        state_checkpoint && state_validate false >/dev/null 2>&1 &&
        _github_initial_portable_onboarding "${GITHUB_DECISION_PROVISION_KEYS:-}" rollback &&
        github_config_serialize "$1" "$CONFIG_JSON"
}

# _config_source_local_snapshot <out> — vault snapshot of the device-only state in CONFIG_DIR.
_config_source_local_snapshot() {
    _config_source_with_local_state _config_source_local_snapshot_build "${1:?snapshot}"
}

# _github_counts_label <nodes\tclients\tgroups>
_github_counts_label() {
    local nodes clients groups
    if [[ -z "${1:-}" ]]; then
        printf '%s\n' "не читается"
        return 0
    fi
    IFS=$'\t' read -r nodes clients groups <<< "$1"
    printf 'нод %s, клиентов %s, групп %s\n' "$nodes" "$clients" "$groups"
}

# _github_counts_json FILE [logical] — {nodes,clients,groups} конфигурации
# (logical — снимок с полем .config) или null, если файл не читается.
_github_counts_json() {
    local file="${1:-}" root='.'
    [[ "${2:-}" == logical ]] && root='.config'
    jq -c "$root | {nodes:(.nodes//[]|length), clients:(.clients//[]|length), groups:(.groups//[]|length)}" \
        "$file" 2>/dev/null || printf 'null\n'
}

# _github_format_migrate_prepare <candidate> <from> — план преобразования и
# rc_confirm_gate; 0 — подтверждено, 1 — ошибка или нет подтверждения.
_github_format_migrate_prepare() {
    local candidate="${1:?candidate}" from="${2:-?}" names minimum
    github_config_open "$GITHUB_WORKTREE" "$candidate" migrate || return 1
    minimum=$(_github_vault_format_min_version "$GITHUB_VAULT_FORMAT") || return 1
    names=$(jq -r '[.portability.issues[] | select(.reason=="missing_secret") | .node_id] as $ids |
        [.config.nodes[] | select(.id as $i | $ids | index($i)) | .name] | join(", ")' \
        "$candidate" 2>/dev/null) || names=""
    _github_plaintext_review_lines
    _github_plan_begin "Преобразование конфигурации GitHub"
    CORE_PLAN_LINES+=("Формат: v${from} → v${GITHUB_VAULT_FORMAT}"
        "Устройства с Remote Control старше ${minimum} перестанут читать конфигурацию."
        "Предыдущая версия останется в истории Git."
        "${GITHUB_PLAINTEXT_REVIEW_LINES[@]}")
    [[ -z "$names" ]] || CORE_PLAN_LINES+=("Потребуется повторный ввод пароля: ${names}")
    if ! rc_confirm_gate; then
        rm -f "$candidate"
        return 1
    fi
}

# github_format_migrate_action <from> — 0 published, 1 error or not confirmed,
# 3 published without runtime.
github_format_migrate_action() {
    local from="${1:-?}" candidate rc=0
    candidate=$(umask 077; mktemp "$CONFIG_DIR/.vault-migrate.XXXXXX") || return 1
    _github_format_migrate_prepare "$candidate" "$from" || rc=$?
    [[ $rc -eq 0 ]] && { _config_source_publish_logical "$candidate" || rc=$?; }
    [[ $rc -eq 0 ]] || rm -f "$candidate"
    return "$rc"
}

# github_replace_with_local_action <recovery|menu> — 0 published, 1 error,
# no local data or not confirmed, 3 published without runtime.
github_replace_with_local_action() {
    local mode="${1:-menu}" candidate local_counts github_counts
    local local_config="${LOCAL_CONFIG_JSON:-$CONFIG_DIR/config.json}" local_nodes local_clients rc=0
    if [[ ! -f "$local_config" ]]; then
        rc_fail not_found "Конфигурация только этого компьютера отсутствует."
        return 1
    fi
    # Review reads the device-only config as is: nothing local or remote changes before consent.
    local_counts=$(jq -r '[(.nodes//[]|length),(.clients//[]|length),(.groups//[]|length)]|@tsv' \
        "$local_config" 2>/dev/null) || local_counts=""
    if [[ "$mode" == recovery ]]; then
        github_counts="${GITHUB_LAST_SNAPSHOT_COUNTS:-}"
    else
        github_counts=$(jq -r '[(.nodes//[]|length),(.clients//[]|length),(.groups//[]|length)]|@tsv' \
            "$CONFIG_JSON" 2>/dev/null) || github_counts=""
    fi
    _github_plaintext_review_lines
    CORE_PLAN_LINES=("Замена конфигурации GitHub"
        "Репозиторий: ${GITHUB_OWNER:-?}/${GITHUB_REPO_NAME} (ветка ${GITHUB_BRANCH})"
        "Будет опубликована конфигурация только этого компьютера."
        "Этот компьютер: $(_github_counts_label "$local_counts")"
        "GitHub: $(_github_counts_label "$github_counts")"
        "Текущая конфигурация GitHub останется только в истории Git."
        "${GITHUB_PLAINTEXT_REVIEW_LINES[@]}")
    [[ "$mode" != recovery && "${GITHUB_SYNC_STATUS:-}" == pending ]] &&
        CORE_PLAN_LINES+=("Неотправленные изменения рабочей конфигурации GitHub будут заменены.")
    IFS=$'\t' read -r local_nodes local_clients _ <<< "$local_counts"
    [[ "${local_nodes:-0}" == 0 && "${local_clients:-0}" == 0 ]] &&
        CORE_PLAN_LINES+=("Локальная конфигурация пуста.")
    # Publishing the device-only nodes onboards them first (keys, pinned host keys).
    _config_source_with_local_state _github_plan_onboarding || return 1
    rc_confirm_gate || return 1
    candidate=$(umask 077; mktemp "$CONFIG_DIR/.vault-replace.XXXXXX") || return 1
    if ! _config_source_local_snapshot "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    _config_source_publish_logical "$candidate" || rc=$?
    [[ $rc -eq 0 ]] || rm -f "$candidate"
    return "$rc"
}

github_config_snapshot_cached() {
    local out="${1:?snapshot}" expected_repo="${2:?repo}" branch="${3:?branch}"
    local origin old_store="$GITHUB_STORE" old_sessions="$GITHUB_SESSIONS_DIR"
    local old_worktree="$GITHUB_WORKTREE" old_session="$GITHUB_SESSION_ID"
    local old_remote="$GITHUB_REMOTE" old_branch="$GITHUB_BRANCH"
    local old_session_remote="$GITHUB_SESSION_REMOTE"
    local old_session_branch="$GITHUB_SESSION_BRANCH"
    local old_session_origin="$GITHUB_SESSION_ORIGIN"
    local old_identity="$GITHUB_IDENTITY" old_recipient="$GITHUB_RECIPIENT"
    local old_storage="$GITHUB_STORAGE_MODE" rc=1
    [[ -d "$old_store" && ! -L "$old_store" ]] || return 1
    origin=$(git --git-dir="$old_store" remote get-url origin 2>/dev/null) || return 1
    [[ "$origin" == "$expected_repo" ||
       "$origin" == "https://github.com/$expected_repo.git" ]] || return 1
    git --git-dir="$old_store" show-ref --verify --quiet "refs/heads/$branch" || return 1
    _github_mkdir_secure "$GITHUB_ACCOUNT_SWITCH_DIR" || return 1
    GITHUB_SESSION_ID=""
    if _github_session_open_cached "$old_store" "$GITHUB_ACCOUNT_SWITCH_DIR/cached-sessions" "$branch" &&
       github_config_open "$GITHUB_WORKTREE" "$out"; then
        rc=0
    fi
    github_config_close >/dev/null 2>&1 || true
    _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/cached-sessions" || true
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
    GITHUB_REMOTE="$old_remote"; GITHUB_BRANCH="$old_branch"
    GITHUB_SESSION_REMOTE="$old_session_remote"; GITHUB_SESSION_BRANCH="$old_session_branch"
    GITHUB_SESSION_ORIGIN="$old_session_origin"; GITHUB_IDENTITY="$old_identity"
    GITHUB_RECIPIENT="$old_recipient"; GITHUB_STORAGE_MODE="$old_storage"
    export GITHUB_STORE GITHUB_SESSIONS_DIR GITHUB_WORKTREE GITHUB_SESSION_ID
    export GITHUB_REMOTE GITHUB_BRANCH GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH
    export GITHUB_SESSION_ORIGIN GITHUB_IDENTITY GITHUB_RECIPIENT GITHUB_STORAGE_MODE
    return "$rc"
}


# original[]: 13 session globals, GITHUB_SYNC_STATUS and the GitHub profile
# path this command created (_github_profile_new_root), removed on rollback.
_github_change_rollback() {
    local rc=0
    github_account_switch_rollback || rc=$?
    GITHUB_STORE="$1"; GITHUB_SESSIONS_DIR="$2"
    GITHUB_WORKTREE="$3"; GITHUB_SESSION_ID="$4"
    GITHUB_REMOTE="$5"; GITHUB_BRANCH="$6"; GITHUB_OWNER="$7"
    GITHUB_IDENTITY="$8"; GITHUB_RECIPIENT="$9"
    GITHUB_SESSION_REMOTE="${10}"; GITHUB_SESSION_BRANCH="${11}"
    GITHUB_SESSION_ORIGIN="${12}"; GITHUB_STORAGE_MODE="${13}"
    GITHUB_SYNC_STATUS="${14:-${GITHUB_SYNC_STATUS:-clean}}"
    [[ -z "${15:-}" ]] || rm -rf -- "${15}" || rc=1
    export GITHUB_STORE GITHUB_SESSIONS_DIR GITHUB_WORKTREE GITHUB_SESSION_ID
    export GITHUB_REMOTE GITHUB_BRANCH GITHUB_OWNER GITHUB_IDENTITY GITHUB_RECIPIENT
    export GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH GITHUB_SESSION_ORIGIN GITHUB_STORAGE_MODE
    export GITHUB_SYNC_STATUS
    return "$rc"
}

# First missing level of credentials/gh/<login>, or nothing: a refused or
# rolled-back change-account removes the profile it created.
_github_profile_new_root() {
    local profile path
    profile=$(_github_profile_dir "${1:-}") || return 0
    for path in "$GITHUB_CREDENTIALS_DIR" "$GITHUB_CREDENTIALS_DIR/gh" "$profile"; do
        [[ -e "$path" || -L "$path" ]] || { printf '%s\n' "$path"; return 0; }
    done
}

# Failure before the switch is committed: roll back (marker prepared). After
# target_committed the switch can only go forward: suspend the session.
_github_change_abort() {
    local committed="$1" stage="${GITHUB_LAST_STAGE:-}" detail="${GITHUB_LAST_ERROR:-}"
    local hint="${GITHUB_LAST_HINT:-}" auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
    shift
    if [[ "$committed" == true ]]; then
        _github_account_switch_suspend "$@"
        return 0
    fi
    _github_change_rollback "$@" >/dev/null 2>&1 || true
    GITHUB_LAST_STAGE="$stage"; GITHUB_LAST_ERROR="$detail"
    GITHUB_LAST_HINT="$hint"; GITHUB_LAST_AUTH_RELEVANT="$auth"
}

# Push outcome is unknown, or the switch is committed but not finished
# locally: keep the marker for github_account_switch_recover and close both
# sessions. Without a worktree, flush and config writes fail, so nothing
# reaches either repository until F or the next start verifies the push and
# finishes or rolls back the switch.
_github_account_switch_suspend() {
    local stage="${GITHUB_LAST_STAGE:-}" detail="${GITHUB_LAST_ERROR:-}"
    local hint="${GITHUB_LAST_HINT:-}" auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
    github_config_close >/dev/null 2>&1 || true
    GITHUB_STORE="$1"; GITHUB_SESSIONS_DIR="$2"
    GITHUB_WORKTREE="$3"; GITHUB_SESSION_ID="$4"
    GITHUB_REMOTE="$5"; GITHUB_BRANCH="$6"; GITHUB_OWNER="$7"
    GITHUB_IDENTITY="$8"; GITHUB_RECIPIENT="$9"
    GITHUB_SESSION_REMOTE="${10}"; GITHUB_SESSION_BRANCH="${11}"
    GITHUB_SESSION_ORIGIN="${12}"; GITHUB_STORAGE_MODE="${13}"
    if [[ -n "$GITHUB_WORKTREE" || -n "$GITHUB_SESSION_ID" ]]; then
        github_config_close >/dev/null 2>&1 || true
    fi
    GITHUB_WORKTREE=""; GITHUB_SESSION_ID=""
    GITHUB_SESSION_REMOTE=""; GITHUB_SESSION_BRANCH=""; GITHUB_SESSION_ORIGIN=""
    GITHUB_SYNC_STATUS=pending
    export GITHUB_STORE GITHUB_SESSIONS_DIR GITHUB_WORKTREE GITHUB_SESSION_ID
    export GITHUB_REMOTE GITHUB_BRANCH GITHUB_OWNER GITHUB_IDENTITY GITHUB_RECIPIENT
    export GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH GITHUB_SESSION_ORIGIN
    export GITHUB_STORAGE_MODE GITHUB_SYNC_STATUS
    if [[ "$(jq -r '.phase' "$GITHUB_ACCOUNT_SWITCH_MARKER" 2>/dev/null)" == push_unknown ]]; then
        warn "Результат отправки в новый репозиторий не подтверждён. Синхронизация и изменения приостановлены."
    else
        warn "Смена аккаунта GitHub не завершена. Синхронизация и изменения приостановлены."
    fi
    info "Выполните source github-fetch или откройте сессию заново: смена аккаунта будет проверена и завершена или отменена."
    GITHUB_LAST_STAGE="$stage"; GITHUB_LAST_ERROR="$detail"
    GITHUB_LAST_HINT="$hint"; GITHUB_LAST_AUTH_RELEVANT="$auth"
}

github_source_change_account() {
    local initial_login
    local old_repo old_name branch old_store old_sessions new_repo old_storage
    local old_worktree old_remote old_branch old_owner old_session
    local old_identity old_recipient old_session_remote old_session_branch old_session_origin
    local target_owner logical="$CONFIG_DIR/account-switch/old-state.json"
    local target_state="$CONFIG_DIR/account-switch/target-state.json"
    local tracked target_valid=false target_needs_replace=false
    local old_state_available=false desired_state="" push_required=false
    local expected_head="" action profile_root
    GITHUB_OLD_REPO_SETTINGS_URL=""
    [[ "$CONFIG_SOURCE" == github ]] || return 1
    old_repo=$(jq -er '.repo' "$CONFIG_DIR/source.json") || return 1
    branch=$(jq -er '.branch' "$CONFIG_DIR/source.json") || return 1
    old_name="${old_repo#*/}"
    old_store="$GITHUB_STORE"; old_sessions="$GITHUB_SESSIONS_DIR"
    old_worktree="$GITHUB_WORKTREE"; old_session="$GITHUB_SESSION_ID"
    old_remote="$GITHUB_REMOTE"; old_branch="$GITHUB_BRANCH"; old_owner="$GITHUB_OWNER"
    old_identity="$GITHUB_IDENTITY"; old_recipient="$GITHUB_RECIPIENT"
    old_session_remote="$GITHUB_SESSION_REMOTE"; old_session_branch="$GITHUB_SESSION_BRANCH"
    old_session_origin="$GITHUB_SESSION_ORIGIN"; old_storage="$GITHUB_STORAGE_MODE"
    profile_root=$(_github_profile_new_root "${GITHUB_DECISION_LOGIN:-}")
    local -a original=("$old_store" "$old_sessions" "$old_worktree" "$old_session"
        "$old_remote" "$old_branch" "$old_owner" "$old_identity" "$old_recipient"
        "$old_session_remote" "$old_session_branch" "$old_session_origin" "$old_storage"
        "${GITHUB_SYNC_STATUS:-clean}" "$profile_root")

    initial_login="${old_repo%%/*}"
    if ! _github_select_account; then
        [[ -z "$profile_root" ]] || rm -rf -- "$profile_root"
        GITHUB_OWNER="$initial_login"
        export GITHUB_OWNER
        return 1
    fi
    target_owner="$GITHUB_OWNER"
    new_repo="$target_owner/$old_name"
    [[ "$new_repo" != "$old_repo" ]] || {
        info "Уже используется аккаунт $target_owner."
        return 0
    }

    if ! _github_mkdir_secure "$GITHUB_ACCOUNT_SWITCH_DIR"; then
        [[ -z "$profile_root" ]] || rm -rf -- "$profile_root"
        GITHUB_OWNER="$old_owner"
        return 1
    fi
    if [[ -f "$CONFIG_JSON" && -f "$SECRETS_JSON" && -f "$STATE_MANIFEST" ]] &&
       github_config_serialize "$logical" "$CONFIG_JSON"; then
        old_state_available=true
    elif github_config_snapshot_cached "$logical" "$old_repo" "$branch"; then
        old_state_available=true
    fi
    if [[ "$old_state_available" != true && "${GITHUB_DECISION_WITHOUT_CACHE:-0}" != 1 ]]; then
        _github_account_switch_remove_file "$logical" || true
        _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR" || true
        _github_record_error "выбор данных смены аккаунта" \
            "Последний локальный кэш прежнего аккаунта недоступен."
        rc_fail cache_skip_required \
            "Последний локальный кэш прежнего аккаунта недоступен: продолжить можно флагом --without-cache."
        [[ -z "$profile_root" ]] || rm -rf -- "$profile_root"
        GITHUB_OWNER="$old_owner"
        return 1
    fi
    [[ "$old_state_available" == true ]] || warn "Последний локальный кэш прежнего аккаунта недоступен."
    if ! github_account_switch_begin "$old_repo" "$new_repo" "$branch" "$initial_login"; then
        [[ -z "$profile_root" ]] || rm -rf -- "$profile_root"
        GITHUB_OWNER="$old_owner"
        return 1
    fi
    if ! cp "$CONFIG_DIR/source.json" "$GITHUB_ACCOUNT_SWITCH_DIR/old-source.json" ||
       ! chmod 600 "$GITHUB_ACCOUNT_SWITCH_DIR/old-source.json" ||
       ! _github_account_switch_write_marker prepared "" "$old_state_available" false false; then
        _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
        return 1
    fi

    GITHUB_OWNER="$target_owner"; GITHUB_REPO_NAME="$old_name"; GITHUB_BRANCH="$branch"
    GITHUB_REMOTE="$new_repo"; GITHUB_STORE="$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git"
    GITHUB_SESSIONS_DIR="$GITHUB_ACCOUNT_SWITCH_DIR/target-sessions"
    GITHUB_SESSION_ID=""; GITHUB_WORKTREE=""
    if ! github_sync_init true onboarding true; then
        _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
        return 1
    fi
    tracked=$(git -C "$GITHUB_WORKTREE" ls-files 2>/dev/null) || {
        _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
        return 1
    }
    if [[ -n "$tracked" ]]; then
        if github_config_open "$GITHUB_WORKTREE" "$target_state"; then
            target_valid=true
        elif [[ "${RC_ERROR_CODE:-}" == vault_password_required || "${RC_ERROR_CODE:-}" == vault_password_invalid ]]; then
            github_config_close >/dev/null 2>&1 || true
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        elif [[ "${GITHUB_LAST_FORMAT:-}" == outdated || "${GITHUB_LAST_FORMAT:-}" == newer ]]; then
            local switch_stage="$GITHUB_LAST_STAGE" switch_error="$GITHUB_LAST_ERROR" switch_hint=""
            if [[ "$GITHUB_LAST_FORMAT" == outdated ]]; then
                switch_stage="проверка формата конфигурации GitHub"
                switch_error="Репозиторий ${new_repo} содержит конфигурацию формата v${GITHUB_LAST_FORMAT_VERSION}. Смена аккаунта прервана."
                switch_hint="Выполните source github-switch-local и подключите GitHub заново под новым аккаунтом (source github-connect --existing migrate)."
            fi
            github_config_close >/dev/null 2>&1 || true
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            _github_record_error "$switch_stage" "$switch_error" false "$switch_hint"
            return 1
        else
            target_needs_replace=true
        fi
    fi
    if [[ "$target_valid" == true ]]; then
        local local_counts=null
        [[ "$old_state_available" != true ]] || local_counts=$(_github_counts_json "$logical" logical)
        if ! _github_decide_existing_action "$old_state_available" false \
            "$(_github_counts_json "$target_state" logical)" "$local_counts"; then
            github_config_close >/dev/null 2>&1 || true
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        fi
        action="$GITHUB_EXISTING_ACTION"
        if [[ "$action" == remote ]]; then
            desired_state="$target_state"
            push_required=false
        else
            desired_state="$logical"
            push_required=true
        fi
    else
        if [[ "$target_needs_replace" == true && "${GITHUB_DECISION_REPLACE_TARGET:-0}" != 1 ]]; then
            github_config_close >/dev/null 2>&1 || true
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            _github_record_error "проверка целевого репозитория" \
                "В репозитории $new_repo нет корректной конфигурации Essence."
            rc_fail target_replace_required \
                "Репозиторий $new_repo содержит посторонние файлы: заменить их можно флагом --replace-target." \
                "$(printf '%s\n' "$tracked" | jq -Rsc --arg r "$new_repo" '{repo:$r, tracked_files:(split("\n") | map(select(length > 0)) | length)}')"
            return 1
        fi
        # Decisions first: storage and the new access password are needed before consent.
        if ! _github_decide_storage_mode ||
           { [[ "$GITHUB_STORAGE_MODE" == age ]] && ! github_config_new_master; }; then
            unset GITHUB_MASTER_PASSWORD
            [[ -z "$tracked" ]] || github_config_close >/dev/null 2>&1 || true
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        fi
        unset GITHUB_MASTER_PASSWORD
        desired_state="$logical"
        push_required=true
    fi
    _github_plan_begin "Смена аккаунта GitHub"
    CORE_PLAN_LINES+=("Прежний репозиторий $old_repo не изменится; синхронизация с ним прекратится.")
    if [[ "$target_valid" == true && "$action" == remote ]]; then
        CORE_PLAN_LINES+=("Будет использована конфигурация из $new_repo: $(_github_counts_json_label "$(_github_counts_json "$target_state" logical)").")
    elif [[ "$target_valid" == true ]]; then
        CORE_PLAN_LINES+=("Конфигурация в $new_repo ($(_github_counts_json_label "$(_github_counts_json "$target_state" logical)")) будет заменена текущей ($(_github_counts_json_label "$(_github_counts_json "$logical" logical)")) и останется только в истории Git.")
        _github_plan_storage
        GITHUB_PLAN_RISKY=true
    else
        if [[ "$target_needs_replace" == true ]]; then
            CORE_PLAN_LINES+=("Из $new_repo будут удалены все файлы ($(printf '%s\n' "$tracked" | grep -c .)); они останутся только в истории Git.")
            GITHUB_PLAN_RISKY=true
        fi
        if [[ "$old_state_available" == true ]]; then
            CORE_PLAN_LINES+=("В $new_repo будет отправлена текущая конфигурация: $(_github_counts_json_label "$(_github_counts_json "$logical" logical)").")
        else
            CORE_PLAN_LINES+=("В $new_repo будет отправлена пустая конфигурация: кэш прежнего аккаунта недоступен.")
        fi
        _github_plan_storage
    fi
    if ! _github_plan_confirm; then
        [[ -z "$tracked" ]] || github_config_close >/dev/null 2>&1 || true
        _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! github_repo_apply_pending; then
        local pending_stage="$GITHUB_LAST_STAGE" pending_error="$GITHUB_LAST_ERROR"
        local pending_auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
        [[ -z "$tracked" ]] || github_config_close >/dev/null 2>&1 || true
        _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
        _github_record_error "$pending_stage" "$pending_error" "$pending_auth"
        return 1
    fi
    if [[ "$target_valid" != true ]]; then
        if [[ "$target_needs_replace" == true ]] &&
           ! git -C "$GITHUB_WORKTREE" rm -r -f -- . >/dev/null 2>&1; then
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        fi
        if [[ "$old_state_available" != true ]] &&
           ! _config_source_create_empty_snapshot "$desired_state"; then
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        fi
        if [[ "$GITHUB_STORAGE_MODE" == age ]] && ! github_config_age_init; then
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    if [[ "$desired_state" != "$target_state" ]] &&
       { ! cp "$desired_state" "$target_state" || ! chmod 600 "$target_state" ||
         ! github_config_validate "$target_state"; }; then
        local target_state_error="${GITHUB_LAST_ERROR:-Снимок целевой конфигурации не прошёл проверку.}"
        _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
        _github_record_error "подготовка целевой конфигурации" "$target_state_error"
        return 1
    fi
    if [[ "$push_required" == true ]]; then
        if ! github_config_checkpoint "$desired_state" || ! _github_sync_commit; then
            local failure_stage="${GITHUB_LAST_STAGE:-сохранение новой конфигурации}"
            local failure_detail="${GITHUB_LAST_ERROR:-Не удалось подготовить новую конфигурацию.}"
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            _github_record_error "$failure_stage" "$failure_detail"
            return 1
        fi
        expected_head="${GITHUB_LAST_COMMIT_HEAD:-}"
        [[ "$expected_head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || {
            _github_record_error "подготовка отправки новой конфигурации" \
                "Не удалось определить commit новой конфигурации."
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        }
        if ! _github_account_switch_write_marker push_unknown "$expected_head" \
            "$old_state_available" "${GITHUB_ACCOUNT_SWITCH_REPO_CREATED:-false}" \
            "${GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED:-false}"; then
            _github_record_error "подготовка отправки новой конфигурации" \
                "Не удалось записать защищённый маркер перед отправкой."
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            return 1
        fi
        if ! _github_sync_push "$expected_head"; then
            _github_account_switch_suspend "${original[@]}"
            return 1
        fi
        _github_account_switch_write_marker target_committed "$expected_head" \
            "$old_state_available" "${GITHUB_ACCOUNT_SWITCH_REPO_CREATED:-false}" \
            "${GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED:-false}" || {
            _github_record_error "фиксация отправленной конфигурации" \
                "Не удалось записать состояние завершённой отправки."
            _github_account_switch_suspend "${original[@]}"
            return 1
        }
    else
        expected_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>/dev/null) || {
            github_config_close >/dev/null 2>&1 || true
            _github_change_rollback "${original[@]}" >/dev/null 2>&1 || true
            _github_record_error "чтение удалённой конфигурации" \
                "Не удалось определить commit выбранной конфигурации GitHub."
            return 1
        }
    fi
    if ! github_config_close; then
        _github_ensure_error "закрытие рабочей копии новой конфигурации" \
            "Не удалось закрыть рабочую копию нового репозитория."
        _github_change_abort "$push_required" "${original[@]}"
        return 1
    fi
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
    GITHUB_REMOTE="$old_remote"; GITHUB_BRANCH="$old_branch"
    GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
    GITHUB_SESSION_REMOTE="$old_session_remote"; GITHUB_SESSION_BRANCH="$old_session_branch"
    GITHUB_SESSION_ORIGIN="$old_session_origin"; GITHUB_STORAGE_MODE="$old_storage"
    if [[ -n "$old_worktree" || -n "$old_session" ]]; then
        github_config_close || {
            _github_ensure_error "закрытие прежней рабочей копии" \
                "Не удалось закрыть рабочую копию прежнего репозитория."
            _github_change_abort "$push_required" "${original[@]}"
            return 1
        }
    fi
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_WORKTREE=""; GITHUB_SESSION_ID=""
    # Finalize moves the old store away and rollback never restores it: the
    # chosen remote configuration commits the switch here, so a later failure
    # (or the next start) finishes it instead of rolling back.
    if [[ "$push_required" != true ]] &&
       ! _github_account_switch_write_marker target_committed "$expected_head" \
           "$old_state_available" "${GITHUB_ACCOUNT_SWITCH_REPO_CREATED:-false}" \
           "${GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED:-false}"; then
        _github_record_error "фиксация выбранной конфигурации" \
            "Не удалось записать состояние выбранной конфигурации GitHub."
        _github_account_switch_suspend "${original[@]}"
        return 1
    fi
    github_account_switch_finalize "$target_state" false "$expected_head" || {
        _github_ensure_error "локальная финализация смены аккаунта" \
            "Не удалось установить новое локальное хранилище GitHub."
        _github_account_switch_suspend "${original[@]}"
        return 1
    }
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_REMOTE="https://github.com/$new_repo.git"; GITHUB_BRANCH="$branch"
    GITHUB_OWNER="$target_owner"; GITHUB_REPO_NAME="$old_name"
    GITHUB_SESSION_ID=""; GITHUB_WORKTREE=""
    _github_session_open_cached "$old_store" "$old_sessions" "$branch" || {
        _github_record_error "открытие новой рабочей копии" \
            "Не удалось открыть новое локальное хранилище GitHub без повторной сети."
        _github_account_switch_suspend "${original[@]}"
        return 1
    }
    if ! _config_source_materialize_state "$target_state" ||
       ! github_source_metadata_write; then
        _github_ensure_error "применение новой конфигурации" \
            "Не удалось применить конфигурацию нового аккаунта."
        _github_account_switch_suspend "${original[@]}"
        return 1
    fi
    github_account_switch_commit_local || {
        _github_record_error "запись завершения смены аккаунта GitHub" \
            "Не удалось зафиксировать обновлённое локальное состояние."
        _github_account_switch_suspend "${original[@]}"
        return 1
    }
    github_account_switch_recover || return 1
    GITHUB_OLD_REPO_SETTINGS_URL="https://github.com/$old_repo/settings"
    success "Аккаунт GitHub изменён: $target_owner."
    return 0
}

config_source_startup() {
    _github_clear_error
    # github-runtime/ общий для процессов: GitHub-режим держит лок весь сеанс.
    # Повторное открытие (fetch, неудачный session open) лок не наращивает.
    if [[ -e "${GITHUB_ACCOUNT_SWITCH_MARKER:-$CONFIG_DIR/account-switch/transaction.json}" ]] ||
       jq -e '.type=="github"' "$CONFIG_DIR/source.json" >/dev/null 2>&1; then
        if [[ "${_RC_LOCK_SESSION:-0}" != 1 ]] && ! rc_lock_acquire session github-session; then
            _github_record_error "блокировка конфигурации" "$RC_ERROR_MESSAGE"
            return 1
        fi
    fi
    if [[ -e "${GITHUB_ACCOUNT_SWITCH_MARKER:-$CONFIG_DIR/account-switch/transaction.json}" ]] &&
       ! github_account_switch_recover; then
        return 1
    fi
    if github_source_metadata_valid "$CONFIG_DIR/source.json"; then
        local source_repo source_branch source_owner
        source_repo=$(jq -er '.repo' "$CONFIG_DIR/source.json") || {
            _github_record_error "проверка настроек источника GitHub" "source.json не содержит репозиторий GitHub."
            return 1
        }
        source_branch=$(jq -er '.branch' "$CONFIG_DIR/source.json") || {
            _github_record_error "проверка настроек источника GitHub" "source.json не содержит ветку GitHub."
            return 1
        }
        source_owner="${source_repo%%/*}"
        # The saved repository owns this session; global gh selection is only
        # a first-connect hint and must never trigger a migration on startup.
        CONFIG_SOURCE=github
        GITHUB_OWNER="$source_owner"
        GITHUB_BRANCH="$source_branch"
        if [[ -n "${GITHUB_WORKTREE:-}" && -n "${GITHUB_SESSION_REMOTE:-}" ]]; then
            GITHUB_REMOTE="$GITHUB_SESSION_REMOTE"
        else
            GITHUB_REMOTE="$source_repo"
        fi
        if ! github_sync_init; then
            if declare -F _github_ensure_error >/dev/null 2>&1; then
                _github_ensure_error "подготовка источника GitHub" \
                    "Не удалось подготовить локальную рабочую копию репозитория."
            else
                _github_record_error "подготовка источника GitHub" \
                    "Не удалось подготовить локальную рабочую копию репозитория."
            fi
            return 1
        fi
        _config_source_materialize_github || return 1
    elif legacy_local_source_metadata_valid "$CONFIG_DIR/source.json"; then
        rc_locked open-local state_open_local || return 1
        if ! rm -f "$CONFIG_DIR/source.json"; then
            warn "Не удалось удалить устаревший локальный source.json."
            return 1
        fi
        CONFIG_SOURCE=local
    elif [[ -f "$CONFIG_DIR/source.json" ]] &&
          jq -e 'type=="object" and .type=="github"' "$CONFIG_DIR/source.json" >/dev/null 2>&1; then
        CONFIG_SOURCE=github
        _github_record_error "проверка настроек источника GitHub" \
            "source.json содержит неполные или некорректные параметры GitHub."
        return 1
    elif [[ -f "$CONFIG_DIR/source.json" ]]; then
        warn "source.json содержит неподдерживаемый или неполный источник GitHub."
        return 1
    else
        rc_locked open-local state_open_local || return 1
        CONFIG_SOURCE=local
    fi
    export CONFIG_SOURCE CONFIG_JSON SECRETS_JSON STATE_MANIFEST TEMPLATES_DIR
    export SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE STATE_DIR
}

# Connect transaction. github_enable_local changes local files before it is done:
# onboarding rewrites config.json, manifest.json and ssh/known_hosts and installs
# portable keys on the nodes, materialize rewrites .auth, github_sync_init and the
# account profile create cache paths. _github_enable_snapshot records them first;
# _github_enable_rollback returns them. After success the snapshot is kept until the
# caller finishes: the state_action steps after github_enable_local can still fail
# (github_enable_abort) or succeed (github_enable_commit).
GITHUB_ENABLE_BACKUP=""
GITHUB_ENABLE_SOURCE_HAD=false
GITHUB_ENABLE_KNOWN_HAD=false
GITHUB_ENABLE_AUTH_HAD=false
GITHUB_ENABLE_CONFIG=""
GITHUB_ENABLE_CREATED=""
GITHUB_ENABLE_STORE_REFS=""
GITHUB_ENABLE_STORE_ORIGIN=""
GITHUB_ENABLE_ONBOARDED=""
GITHUB_ENABLE_NEW_VAULT=false

_github_enable_snapshot() {
    local backup path
    GITHUB_ENABLE_SOURCE_HAD=false GITHUB_ENABLE_KNOWN_HAD=false GITHUB_ENABLE_AUTH_HAD=false
    GITHUB_ENABLE_CONFIG="$CONFIG_JSON" GITHUB_ENABLE_CREATED="" GITHUB_ENABLE_ONBOARDED=""
    GITHUB_ENABLE_STORE_REFS="" GITHUB_ENABLE_STORE_ORIGIN="" GITHUB_ENABLE_NEW_VAULT=false
    backup=$(umask 077; mktemp -d "$CONFIG_DIR/.github-enable.XXXXXX") || return 1
    GITHUB_ENABLE_BACKUP="$backup"
    if [[ -f "$CONFIG_DIR/source.json" ]]; then
        GITHUB_ENABLE_SOURCE_HAD=true
        cp "$CONFIG_DIR/source.json" "$backup/source.json" || return 1
    fi
    cp -p "$CONFIG_JSON" "$backup/config.json" || return 1
    cp -p "$STATE_MANIFEST" "$backup/manifest.json" || return 1
    if [[ -f "$SSH_KNOWN_HOSTS" ]]; then
        GITHUB_ENABLE_KNOWN_HAD=true
        cp -p "$SSH_KNOWN_HOSTS" "$backup/known_hosts" || return 1
    fi
    if [[ -f "$SCRIPT_AUTH_FILE" ]]; then
        GITHUB_ENABLE_AUTH_HAD=true
        cp -p "$SCRIPT_AUTH_FILE" "$backup/auth" || return 1
    fi
    for path in "$GITHUB_STORE" "$GITHUB_SESSIONS_DIR" "$CONFIG_DIR/github-runtime"; do
        [[ -e "$path" || -L "$path" ]] || GITHUB_ENABLE_CREATED+="$path"$'\n'
    done
    path=$(_github_profile_new_root "${GITHUB_DECISION_LOGIN:-}")
    [[ -z "$path" ]] || GITHUB_ENABLE_CREATED+="$path"$'\n'
    if [[ -d "$GITHUB_STORE/objects" ]]; then
        GITHUB_ENABLE_STORE_REFS=$(git --git-dir="$GITHUB_STORE" for-each-ref \
            --format='%(objectname) %(refname)') || return 1
        GITHUB_ENABLE_STORE_ORIGIN=$(git --git-dir="$GITHUB_STORE" remote get-url origin 2>/dev/null) ||
            GITHUB_ENABLE_STORE_ORIGIN=""
    fi
}

# Node ids that got a new portable key from the onboarding that just succeeded.
_github_enable_note_onboarding() {
    local name id
    for name in "${ONBOARDING_INSTALLED[@]}"; do
        id=$(jq_r --arg n "$name" '.nodes[] | select(.name == $n) | .id') || continue
        [[ -z "$id" ]] || GITHUB_ENABLE_ONBOARDED+="$id"$'\n'
    done
}

# A cache store that existed before the command gets its refs and origin back:
# refs created here (onboarding archives, a new empty branch) are removed.
_github_enable_restore_store() {
    local oid ref
    [[ -d "$GITHUB_STORE/objects" ]] || return 0
    case $'\n'"$GITHUB_ENABLE_CREATED" in
        *$'\n'"$GITHUB_STORE"$'\n'*) return 0 ;;
    esac
    if [[ -n "$GITHUB_ENABLE_STORE_ORIGIN" ]]; then
        git --git-dir="$GITHUB_STORE" remote set-url origin "$GITHUB_ENABLE_STORE_ORIGIN" >/dev/null 2>&1 ||
            return 1
    else
        git --git-dir="$GITHUB_STORE" remote remove origin >/dev/null 2>&1 || true
    fi
    while IFS= read -r ref; do
        case $'\n'"$GITHUB_ENABLE_STORE_REFS"$'\n' in
            *" $ref"$'\n'*) ;;
            *) git --git-dir="$GITHUB_STORE" update-ref -d "$ref" >/dev/null 2>&1 || return 1 ;;
        esac
    done < <(git --git-dir="$GITHUB_STORE" for-each-ref --format='%(refname)')
    while read -r oid ref; do
        [[ -z "$ref" ]] || git --git-dir="$GITHUB_STORE" update-ref "$ref" "$oid" >/dev/null 2>&1 || return 1
    done <<< "$GITHUB_ENABLE_STORE_REFS"
}

# Local files of the snapshot, after state_open_local: config.json and .auth first,
# then keys installed by onboarding are revoked and known_hosts and the manifest
# come back (_onboarding_rollback, hardening.sh).
_github_enable_restore_local() {
    local backup="$GITHUB_ENABLE_BACKUP" ok=true id
    local -a ids=()
    while IFS= read -r id; do
        [[ -z "$id" ]] || ids+=("$id")
    done <<< "$GITHUB_ENABLE_ONBOARDED"
    if (( ${#ids[@]} > 0 )); then
        _onboarding_rollback "$GITHUB_ENABLE_KNOWN_HAD" "$backup/known_hosts" "$backup/manifest.json" "${ids[@]}"
        [[ ! -e "$backup/manifest.json" ]] || ok=false
    else
        cp -p "$backup/manifest.json" "$STATE_MANIFEST" || ok=false
        if [[ "$GITHUB_ENABLE_KNOWN_HAD" == true ]]; then
            cp -p "$backup/known_hosts" "$SSH_KNOWN_HOSTS" || ok=false
        else
            rm -f "$SSH_KNOWN_HOSTS" || ok=false
        fi
    fi
    [[ "$ok" == true ]]
}

_github_enable_rollback() {
    local source_backup="$1" source_had_file="$2" serialized_state="${3:-}"
    local restore_ok=true backup="$GITHUB_ENABLE_BACKUP" path
    local failure_stage="${GITHUB_LAST_STAGE:-}" failure_detail="${GITHUB_LAST_ERROR:-}"
    local failure_hint="${GITHUB_LAST_HINT:-}" failure_auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
    [[ -z "$serialized_state" ]] || rm -f "$serialized_state"
    github_config_close >/dev/null 2>&1 || restore_ok=false
    if [[ "$source_had_file" == true ]]; then
        _github_atomic_private_copy "$source_backup" "$CONFIG_DIR/source.json" ||
            restore_ok=false
    else
        rm -f "$CONFIG_DIR/source.json" || restore_ok=false
    fi
    rm -f "$source_backup" || restore_ok=false
    if [[ -n "$backup" ]]; then
        cp -p "$backup/config.json" "$GITHUB_ENABLE_CONFIG" || restore_ok=false
        if [[ "$GITHUB_ENABLE_AUTH_HAD" == true ]]; then
            cp -p "$backup/auth" "$CONFIG_DIR/.auth" || restore_ok=false
        else
            rm -f "$CONFIG_DIR/.auth" || restore_ok=false
        fi
    fi
    if ! state_open_local; then
        restore_ok=false
    fi
    if [[ -n "$backup" ]]; then
        _github_enable_restore_local || restore_ok=false
        _github_enable_restore_store || restore_ok=false
        while IFS= read -r path; do
            [[ -z "$path" ]] || rm -rf -- "$path" || restore_ok=false
        done <<< "$GITHUB_ENABLE_CREATED"
        if [[ "$restore_ok" == true ]]; then
            rm -rf "$backup" || restore_ok=false
        else
            warn "Копия локальной конфигурации до подключения GitHub оставлена: $backup"
        fi
    fi
    GITHUB_ENABLE_BACKUP="" GITHUB_ENABLE_ONBOARDED="" GITHUB_ENABLE_NEW_VAULT=false
    GITHUB_LAST_STAGE="$failure_stage"
    GITHUB_LAST_ERROR="$failure_detail"
    GITHUB_LAST_HINT="$failure_hint"
    GITHUB_LAST_AUTH_RELEVANT="$failure_auth"
    if [[ "$restore_ok" != true ]]; then
        warn "Не удалось полностью восстановить локальный источник конфигурации."
    fi
    return 1
}

# github_enable_abort — a step after a successful github_enable_local failed (the
# state_action post-steps): the same rollback as a failure inside it.
github_enable_abort() {
    [[ -n "$GITHUB_ENABLE_BACKUP" ]] || return 0
    _github_enable_rollback "$GITHUB_ENABLE_BACKUP/source.json" "$GITHUB_ENABLE_SOURCE_HAD" || true
}

# github_enable_commit — the connection is complete: drop the snapshot and keep the
# key of a new vault on this device when --remember-key asked for it.
github_enable_commit() {
    local backup="$GITHUB_ENABLE_BACKUP"
    GITHUB_ENABLE_BACKUP="" GITHUB_ENABLE_ONBOARDED=""
    if [[ -n "$backup" ]] && ! rm -rf "$backup"; then
        warn "Копия локальной конфигурации до подключения GitHub требует ручной очистки: $backup"
    fi
    if [[ "$GITHUB_ENABLE_NEW_VAULT" == true && "${GITHUB_DECISION_REMEMBER_KEY:-0}" == 1 ]] &&
       ! github_config_remember "${GITHUB_IDENTITY:-}"; then
        warn "Не удалось сохранить ключ расшифровки на этом устройстве; следующий запуск попросит пароль доступа."
        _github_clear_error
    fi
    GITHUB_ENABLE_NEW_VAULT=false
}


# _github_connect_new_consent — first publish into an empty repository: the access
# password (age) and --provision-keys are decided before the plan, consent when the
# plan needs it, then the deferred repository creation.
_github_connect_new_consent() {
    if [[ $GITHUB_STORAGE_MODE == age ]]; then
        if ! _github_ensure_deps age; then
            _github_ensure_error "настройка шифрования конфигурации" \
                "Не удалось подготовить ключи шифрования."
            return 1
        fi
        github_config_new_master || return 1
        unset GITHUB_MASTER_PASSWORD
    fi
    _github_plan_begin "Подключение GitHub"
    CORE_PLAN_LINES+=("В GitHub будет отправлена конфигурация этого компьютера: $(_github_counts_json_label "$(_github_counts_json "$CONFIG_JSON")").")
    _github_plan_storage
    _github_plan_onboarding || return 1
    _github_plan_confirm || return 1
    github_repo_apply_pending
}

# _github_connect_replace_consent REMOTE_COUNTS — --existing local always needs
# consent: the GitHub configuration is replaced by this computer's.
_github_connect_replace_consent() {
    _github_plan_begin "Подключение GitHub с заменой конфигурации"
    CORE_PLAN_LINES+=("Конфигурация GitHub ($(_github_counts_json_label "$1")) будет заменена конфигурацией этого компьютера ($(_github_counts_json_label "$(_github_counts_json "$CONFIG_JSON")")).")
    CORE_PLAN_LINES+=("Текущая конфигурация GitHub останется только в истории Git.")
    _github_plan_storage
    _github_plan_onboarding || return 1
    GITHUB_PLAN_RISKY=true
    _github_plan_confirm
}

github_enable_local() {
    [[ $CONFIG_SOURCE == local ]] || return 0
    GITHUB_ENABLE_BACKUP=""
    _github_clear_error
    if ! state_open_local; then
        _github_ensure_error "подготовка локальной конфигурации" \
            "Не удалось открыть или создать локальную конфигурацию перед подключением GitHub."
        return 1
    fi
    local source_backup source_had_file tmp_state="" tracked
    if ! _github_enable_snapshot; then
        [[ -z "$GITHUB_ENABLE_BACKUP" ]] || rm -rf "$GITHUB_ENABLE_BACKUP"
        GITHUB_ENABLE_BACKUP=""
        _github_record_error "резервное копирование локальной конфигурации" \
            "Не удалось сохранить копию локальной конфигурации перед подключением GitHub."
        return 1
    fi
    source_backup="$GITHUB_ENABLE_BACKUP/source.json"
    source_had_file="$GITHUB_ENABLE_SOURCE_HAD"
    if ! _github_select_account; then
        _github_enable_rollback "$source_backup" "$source_had_file"
        return 1
    fi
    github_sync_init true onboarding true || {
        _github_enable_rollback "$source_backup" "$source_had_file"
        return 1
    }
    tracked=$(git -C "$GITHUB_WORKTREE" ls-files) || {
        _github_record_error "проверка существующего репозитория GitHub" \
            "Не удалось проверить содержимое репозитория GitHub. Репозиторий не изменён."
        _github_enable_rollback "$source_backup" "$source_had_file"
        return 1
    }

    if [[ -z "$tracked" ]]; then
        if ! _github_decide_storage_mode || ! _github_connect_new_consent; then
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        if [[ $GITHUB_STORAGE_MODE == age ]]; then
            if ! github_config_age_init; then
                _github_ensure_error "настройка шифрования конфигурации" \
                    "Не удалось подготовить ключи шифрования."
                _github_enable_rollback "$source_backup" "$source_had_file"
                return 1
            fi
            GITHUB_ENABLE_NEW_VAULT=true
        fi
        CONFIG_SOURCE=github
        if ! _github_initial_portable_onboarding "${GITHUB_DECISION_PROVISION_KEYS:-}" rollback; then
            _github_ensure_error "подготовка переносимой конфигурации" \
                "Не удалось подготовить локальные файлы для хранения в GitHub."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        _github_enable_note_onboarding
        tmp_state=$(umask 077; mktemp "$CONFIG_DIR/.vault.XXXXXX") || {
            _github_record_error "подготовка конфигурации к отправке" \
                "Не удалось создать защищённый временный файл."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        }
        if ! github_config_serialize "$tmp_state" "$CONFIG_JSON" ||
           ! github_config_checkpoint "$tmp_state"; then
            _github_ensure_error "подготовка конфигурации к отправке" \
                "Не удалось собрать конфигурацию для репозитория GitHub."
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        if ! github_sync_flush; then
            GITHUB_SYNC_STATUS=pending
            _github_report_last_error "Не удалось отправить начальную конфигурацию в GitHub"
            warn "Изменения сохранены локально и не отправлены."
        fi
    else
        case $'\n'"$tracked"$'\n' in
            *$'\nstorage.json\n'*) ;;
            *)
                _github_record_error "проверка существующего репозитория GitHub" \
                    "В репозитории есть данные, но отсутствует корректная конфигурация Essence. Репозиторий не изменён."
                _github_enable_rollback "$source_backup" "$source_had_file"
                return 1
                ;;
        esac
        if ! _github_storage_read ||
           { [[ $GITHUB_STORAGE_MODE == age ]] && ! _github_ensure_deps age; }; then
            _github_ensure_error "чтение существующей конфигурации GitHub" \
                "Не удалось проверить или расшифровать существующую конфигурацию. Репозиторий не изменён."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        tmp_state=$(umask 077; mktemp "$CONFIG_DIR/.vault.XXXXXX") || {
            _github_record_error "чтение существующей конфигурации GitHub" \
                "Не удалось проверить или расшифровать существующую конфигурацию. Репозиторий не изменён."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        }
        local connect_outdated=false connect_from="" remote_counts=null
        if ! github_config_open "$GITHUB_WORKTREE" "$tmp_state"; then
            if [[ "${GITHUB_LAST_FORMAT:-}" == outdated ]]; then
                connect_outdated=true
                connect_from="$GITHUB_LAST_FORMAT_VERSION"
                _github_clear_error
            else
                _github_ensure_error "чтение существующей конфигурации GitHub" \
                    "Не удалось проверить или расшифровать существующую конфигурацию. Репозиторий не изменён."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
        fi
        [[ "$connect_outdated" == true ]] || remote_counts=$(_github_counts_json "$tmp_state" logical)
        if ! _github_decide_existing_action true "$connect_outdated" \
            "$remote_counts" "$(_github_counts_json "$CONFIG_JSON")"; then
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        if [[ "$GITHUB_EXISTING_ACTION" == local ]] &&
           ! _github_connect_replace_consent "$remote_counts"; then
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        # Migration and any pending privacy change share one complete plan before
        # the first remote write; the prepared candidate is published below.
        if [[ "$GITHUB_EXISTING_ACTION" == migrate ]]; then
            if ! _github_format_migrate_prepare "$tmp_state" "$connect_from"; then
                _github_ensure_error "преобразование конфигурации GitHub" \
                    "Не удалось преобразовать конфигурацию GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
        elif [[ "$GITHUB_EXISTING_ACTION" == remote && -n "${GITHUB_REPO_PENDING:-}" ]]; then
            _github_plan_begin "Подключение GitHub"
            CORE_PLAN_LINES+=("Будет использована конфигурация GitHub: $(_github_counts_json_label "$remote_counts").")
            if ! _github_plan_confirm; then
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
        fi
        if ! github_repo_apply_pending; then
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        if [[ "$GITHUB_EXISTING_ACTION" == migrate ]]; then
            CONFIG_SOURCE=github
            if ! github_config_checkpoint "$tmp_state"; then
                _github_ensure_error "подготовка конфигурации к отправке" \
                    "Не удалось собрать конфигурацию для репозитория GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            if ! github_sync_flush; then
                GITHUB_SYNC_STATUS=pending
                _github_report_last_error "Не удалось отправить преобразованную конфигурацию в GitHub"
                warn "Изменения сохранены локально и не отправлены."
            fi
        fi
        CONFIG_SOURCE=github
        if [[ "$GITHUB_EXISTING_ACTION" == local ]]; then
            if ! _github_initial_portable_onboarding "${GITHUB_DECISION_PROVISION_KEYS:-}" rollback; then
                _github_ensure_error "подготовка переносимой конфигурации" \
                    "Не удалось подготовить локальные файлы для хранения в GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            _github_enable_note_onboarding
            if ! github_config_serialize "$tmp_state" "$CONFIG_JSON" ||
               ! github_config_checkpoint "$tmp_state"; then
                _github_ensure_error "подготовка конфигурации к отправке" \
                    "Не удалось собрать конфигурацию для репозитория GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            if ! github_sync_flush; then
                GITHUB_SYNC_STATUS=pending
                _github_report_last_error "Не удалось отправить начальную конфигурацию в GitHub"
                warn "Изменения сохранены локально и не отправлены."
            fi
        fi
    fi
    if ! github_source_metadata_write ||
       ! github_source_metadata_valid "$CONFIG_DIR/source.json"; then
        _github_ensure_error "сохранение настроек источника" \
            "Не удалось сохранить или проверить настройки источника GitHub."
        _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
        return 1
    fi
    if ! _config_source_materialize_state "$tmp_state"; then
        _github_ensure_error "проверка подключённого источника" \
            "Не удалось открыть конфигурацию из репозитория GitHub после подключения."
        _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
        return 1
    fi
    export CONFIG_SOURCE CONFIG_JSON SECRETS_JSON STATE_MANIFEST TEMPLATES_DIR
    export SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE STATE_DIR
    rm -f "$tmp_state" ||
        warn "Не удалось удалить временный файл завершённого подключения GitHub."
}
