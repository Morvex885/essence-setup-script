#!/bin/bash
# ─── Хранилище нод (config.json → .nodes[]) ────────────────────────────────

nodes_count() { jq_r '.nodes | length'; }

_pass_key() {
    local mid
    mid=$(cat /etc/machine-id 2>/dev/null || hostname)
    printf '%s' "rcm-${mid}" | openssl dgst -sha256 -r | cut -d' ' -f1
}

node_pass_decode() (
    set -o pipefail
    local key
    key=$(_pass_key) || return 1
    printf '%s' "$1" | base64 -d 2>/dev/null \
        | openssl enc -aes-256-cbc -d -pbkdf2 -pass fd:3 3<<< "$key" 2>/dev/null
)

node_pass_encode() (
    set -o pipefail
    local key
    key=$(_pass_key) || return 1
    printf '%s' "$1" \
        | openssl enc -aes-256-cbc -pbkdf2 -pass fd:3 3<<< "$key" 2>/dev/null \
        | base64 | tr -d '\n'
)

node_load() {
    local index="${1:-}" count idx
    count=$(nodes_count) || return 1
    menu_index_valid "$index" "$count" || return 1
    idx=$((index - 1))
    # Логин, адрес и ссылка на ключ попадают в argv ssh и пути файлов:
    # запись с недопустимыми значениями не загружается (rc 1).
    jq -e --argjson i "$idx" --arg ure "$NODE_SSH_USER_RE" --arg hre "$NODE_SSH_HOST_RE" '
        .nodes[$i] | type=="object" and
        (.id | type=="string" and test("^[a-f0-9]{32}$")) and
        (.name | type=="string" and length>0) and
        '"$NODE_SSH_FIELDS_JQ"' and
        (.port | type=="number" and .>=1 and .<=65535 and floor==.) and
        (.auth=="key" or (.auth=="password" and .secret_id==("node:"+.id+":ssh-password")))
    ' "$CONFIG_JSON" >/dev/null 2>&1 || return 1
    local id name ip port user auth identity tag password="" rc
    id=$(jq_r --argjson i "$idx" '.nodes[$i].id') || return 1
    name=$(jq_r --argjson i "$idx" '.nodes[$i].name') || return 1
    ip=$(jq_r --argjson i "$idx" '.nodes[$i].ip') || return 1
    port=$(jq_r --argjson i "$idx" '.nodes[$i].port') || return 1
    user=$(jq_r --argjson i "$idx" '.nodes[$i].user') || return 1
    auth=$(jq_r --argjson i "$idx" '.nodes[$i].auth // "password"') || return 1
    identity=$(jq_r --argjson i "$idx" '.nodes[$i].identity // ""') || return 1
    tag=$(jq_r --argjson i "$idx" '.nodes[$i].tag // ""') || return 1
    [[ -n "$id" && "$id" != null && -n "$name" && "$name" != null ]] || return 1
    case "$auth" in
        key) ;;
        password)
            if password=$(node_secret_get "$id"; rc=$?; printf '.'; exit "$rc"); then
                password="${password%.}"
            else
                rc=$?
                if [[ $rc -eq 2 ]]; then
                    warn "Пароль SSH для ноды '${name}' отсутствует или не расшифровывается."
                    return 2
                fi
                warn "Не удалось получить пароль SSH для ноды '${name}'."
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    NODE_ID="$id" NODE_NAME="$name" NODE_IDENTITY="$identity" NODE_TAG="$tag"
    SERVER_IP="$ip" SERVER_PORT="$port" SERVER_USER="$user" SERVER_AUTH="$auth"
    SERVER_PASS="$password" CURRENT_NODE_INDEX="$index"
    return 0
}

node_load_by_name() {
    local target="$1" idx
    idx=$(jq_r --arg n "$target" '.nodes | to_entries[] | select(.value.name==$n) | .key') || return 1
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    node_load "$((idx + 1))"
}

node_save_password() {
    local id="${1:-}" password="${2:-}" backup manifest_existed=false
    [[ -n "$id" && -n "$password" ]] || return 1
    jq -e --arg id "$id" 'any(.nodes[]; .id==$id and .auth=="password")' \
        "$CONFIG_JSON" >/dev/null 2>&1 || return 1
    backup=$(umask 077; mktemp -d "${CONFIG_DIR:-/tmp}/.password-backup.XXXXXX") || return 1
    if ! cp "$SECRETS_JSON" "$backup/secrets" || ! chmod 600 "$backup/secrets"; then
        rm -rf "$backup"
        return 1
    fi
    if [[ -f "$STATE_MANIFEST" ]]; then
        manifest_existed=true
        if ! cp "$STATE_MANIFEST" "$backup/manifest" || ! chmod 600 "$backup/manifest"; then
            rm -rf "$backup"
            return 1
        fi
    fi
    if ! node_secret_set "$id" "$password" ||
       ! state_portability_remove_issue "$id" missing_secret ||
       ! state_checkpoint; then
        local restored=true
        _state_write_atomic "$backup/secrets" "$SECRETS_JSON" || restored=false
        if [[ "$manifest_existed" == true ]]; then
            _state_write_atomic "$backup/manifest" "$STATE_MANIFEST" || restored=false
        else
            rm -f "$STATE_MANIFEST" || restored=false
        fi
        if [[ "$restored" == true ]]; then
            rm -rf "$backup"
        else
            warn "Не удалось восстановить локальное состояние. Резервная копия: $backup"
        fi
        warn "Не удалось сохранить пароль SSH."
        return 1
    fi
    rm -rf "$backup"
    return 0
}

# ─── Добавление ноды ─────────────────────────────────────────────────────────
_github_add_abort() {
    local node_id="${1:-}" managed="${2:-false}" known_backup="${3:-}" manifest_backup="${4:-}"
    local existing_name rollback_status=0
    existing_name=$(jq_r --arg id "$node_id" '.nodes[] | select(.id==$id) | .name' 2>/dev/null || true)
    if [[ -n "$existing_name" ]]; then
        jq_w --arg id "$node_id" --arg n "$existing_name" '
            .nodes |= [.[] | select(.id != $id)] |
            .connections |= [.[] | select(.node != $n)] |
            .clients |= map(
                (if .nodes then .nodes |= [.[] | select(. != $n)] else . end) |
                (if .connections then .connections |= [.[] | select(.node != $n)] else . end)
            )' || rollback_status=$?
        if [[ "$rollback_status" -ne 0 ]]; then
            warn "Откат ноды не сохранён; SSH-ключи, секреты и резервные копии оставлены."
            return 1
        fi
    fi
    if [[ "$managed" == true && -n "$node_id" ]] && declare -F _revoke_managed_remote_key >/dev/null 2>&1; then
        _revoke_managed_remote_key "$node_id" >/dev/null 2>&1 ||
            warn "Не удалось отозвать переносимый SSH-ключ ноды «${node_id}»."
    fi
    if { [[ -n "$node_id" ]] &&
         { ! rm -f "${SSH_IDENTITIES_DIR:-}/$node_id" "${SSH_IDENTITIES_DIR:-}/$node_id.pub" ||
           ! node_secret_delete "$node_id"; }; } ||
       { [[ -n "$known_backup" ]] &&
         { [[ ! -f "$known_backup" ]] || ! cp "$known_backup" "$SSH_KNOWN_HOSTS"; }; } ||
       { [[ -z "$known_backup" && -n "${SSH_KNOWN_HOSTS:-}" ]] &&
         ! rm -f "$SSH_KNOWN_HOSTS"; } ||
       { [[ -n "$manifest_backup" ]] &&
         { [[ ! -f "$manifest_backup" ]] || ! cp "$manifest_backup" "$STATE_MANIFEST"; }; }; then
        warn "Восстановление ресурсов ноды не завершено. Резервные копии оставлены: $known_backup $manifest_backup"
        return 1
    fi
    rm -f "$known_backup" "$manifest_backup"
}

# _local_add_abort NODE_ID KNOWN_BACKUP KNOWN_EXISTED — откат локального node
# add: запись ноды, её пароль и ~/.ssh/known_hosts до закрепления ключа
# сервера (KNOWN_BACKUP пусто — known_hosts не менялся). При сбое копия
# known_hosts остаётся для ручного восстановления.
_local_add_abort() {
    local node_id="${1:-}" known_backup="${2:-}" known_existed="${3:-false}" known_file present
    if [[ -n "$node_id" ]]; then
        present=$(jq_r --arg id "$node_id" 'any(.nodes[]?; .id==$id)' 2>/dev/null) || present=unknown
        if [[ "$present" != false ]] &&
           ! jq_w --arg id "$node_id" '.nodes |= [.[] | select(.id != $id)]'; then
            warn "Откат ноды не сохранён: запись ноды осталась в конфигурации."
            return 1
        fi
        if ! node_secret_delete "$node_id"; then
            warn "Откат ноды не завершён: пароль SSH ноды не удалён."
            return 1
        fi
    fi
    [[ -n "$known_backup" ]] || return 0
    known_file=$(_node_known_hosts_file)
    if [[ "$known_existed" == true ]]; then
        if ! cat "$known_backup" > "$known_file"; then
            warn "Не удалось вернуть прежний список ключей серверов. Копия: $known_backup"
            return 1
        fi
    elif ! rm -f "$known_file"; then
        warn "Не удалось удалить добавленный список ключей серверов: $known_file"
        return 1
    fi
    rm -f "$known_backup"
}

# Имя ноды — то же правило, что для имён клиентов и групп
# (_validate_client_name): попадает в пути, файлы и удалённые команды.
# Проверяются только новые значения (add, rename).
_node_name_valid() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9._-]+$ && ! "$1" =~ ^\.+$ ]]
}

# Тег ноды — префикс имён прокси: пусто допустимо, Unicode и флаги-эмодзи
# допустимы; не длиннее 32 символов, без управляющих символов и без
# ; " ' ` $ \ | & < > { } [ ] # , : /. Проверяются только новые значения.
_node_tag_valid() {
    local tag="${1:-}" bad=';"'\''`$\|&<>{}[]#,:/' i
    [[ -n "$tag" ]] || return 0
    (( ${#tag} <= 32 )) || return 1
    [[ ! "$tag" =~ [[:cntrl:]] ]] || return 1
    for (( i = 0; i < ${#bad}; i++ )); do
        [[ "$tag" != *"${bad:i:1}"* ]] || return 1
    done
}

_node_exists() {
    [[ -n "${1:-}" && "$(jq_r --arg n "$1" 'any(.nodes[]?; .name==$n)')" == true ]]
}

# ─── Ключ сервера при добавлении ─────────────────────────────────────────────
_node_known_hosts_file() {
    if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
        printf '%s' "${SSH_KNOWN_HOSTS:-}"
    else
        printf '%s' "$HOME/.ssh/known_hosts"
    fi
}

_node_hostkey_known() {
    local host="$1" file
    file=$(_node_known_hosts_file)
    [[ -n "$file" && -f "$file" ]] || return 1
    ssh-keygen -F "$host" -f "$file" >/dev/null 2>&1
}

# Сканирует ключи сервера в приватный файл NODE_HOSTKEY_SCAN и заполняет
# NODE_HOSTKEY_FPS SHA256-отпечатками в стабильном порядке (sort -u): порядок
# строк ssh-keyscan меняется от запуска к запуску, а отпечатки входят в план.
# Вызывающий удаляет файл.
_node_hostkey_scan() {
    local ip="$1" port="$2" file out
    NODE_HOSTKEY_SCAN="" NODE_HOSTKEY_FPS=()
    file=$(umask 077; mktemp "${TMPDIR:-/tmp}/essence-hostkey.XXXXXX") || return 1
    if ! ssh-keyscan -p "$port" "$ip" > "$file" 2>/dev/null || [[ ! -s "$file" ]]; then
        rm -f "$file"
        return 1
    fi
    out=$(ssh-keygen -lf "$file" 2>/dev/null) || out=""
    if [[ "$out" != *SHA256:* ]]; then
        out=$(ssh-keygen -E sha256 -lf "$file" 2>/dev/null) || out=""
    fi
    mapfile -t NODE_HOSTKEY_FPS < <(awk '$2 ~ /^SHA256:/ { print $2 }' <<< "$out" | LC_ALL=C sort -u)
    if [[ ${#NODE_HOSTKEY_FPS[@]} -eq 0 ]]; then
        rm -f "$file"
        return 1
    fi
    NODE_HOSTKEY_SCAN="$file"
}

# _node_hostkey_scan_match IP PORT FP — скан (NODE_HOSTKEY_SCAN, удаляет
# вызывающий), если среди ключей сервера есть FP; иначе remote_failed или
# host_key_mismatch с {"fingerprints":[…]} и файл скана удалён.
_node_hostkey_scan_match() {
    local ip="$1" port="$2" want="$3" fp
    if ! _node_hostkey_scan "$ip" "$port"; then
        rc_fail remote_failed "Не удалось получить ключ сервера ${ip}:${port}."
        return 1
    fi
    for fp in "${NODE_HOSTKEY_FPS[@]}"; do
        [[ "$fp" == "$want" ]] && return 0
    done
    rm -f "$NODE_HOSTKEY_SCAN"
    NODE_HOSTKEY_SCAN=""
    rc_fail host_key_mismatch "Отпечаток ключа сервера не совпадает. Получено: ${NODE_HOSTKEY_FPS[*]}" \
        "$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}" | jq -R . | jq -sc '{fingerprints:.}')"
}

# _node_hostkey_known_fps HOST — SHA256-отпечатки записей HOST в known_hosts,
# по одному в строке; пусто, если узел неизвестен.
_node_hostkey_known_fps() {
    local host="$1" file entries
    file=$(_node_known_hosts_file)
    [[ -n "$file" && -f "$file" ]] || return 0
    entries=$(ssh-keygen -F "$host" -f "$file" 2>/dev/null) || return 0
    [[ -n "$entries" ]] || return 0
    printf '%s\n' "$entries" | ssh-keygen -E sha256 -lf - 2>/dev/null |
        awk '$2 ~ /^SHA256:/ && !seen[$2]++ {print $2}'
}

# _node_hostkey_filter SCAN OUT FP… — копирует в OUT только строки скана с
# отпечатком из списка FP; rc 1, если таких нет. Остальные ключи сервера
# (другого типа, подставленные по пути) пользователь не проверял.
_node_hostkey_filter() {
    local scan="$1" out="$2" line fp want kept=1
    shift 2
    : > "$out" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        fp=$(printf '%s\n' "$line" | ssh-keygen -E sha256 -lf - 2>/dev/null) || continue
        read -r _ fp _ <<< "$fp"
        for want in "$@"; do
            [[ "$fp" == "$want" ]] || continue
            printf '%s\n' "$line" >> "$out" || return 1
            kept=0
            break
        done
    done < "$scan"
    return "$kept"
}

# _node_hostkey_pin HOST SCAN FP — заменяет ключи HOST в known_hosts строками
# скана с подтверждённым отпечатком FP.
_node_hostkey_pin() {
    local host="$1" scan="$2" fp="${3:-}" file filtered
    file=$(_node_known_hosts_file)
    [[ -n "$file" && "$fp" == SHA256:?* ]] || return 1
    filtered=$(umask 077; mktemp "${TMPDIR:-/tmp}/essence-hostkey.XXXXXX") || return 1
    if ! _node_hostkey_filter "$scan" "$filtered" "$fp" ||
       ! (umask 077; mkdir -p "$(dirname "$file")"); then
        rm -f "$filtered"
        return 1
    fi
    if [[ -f "$file" ]]; then
        ssh-keygen -R "$host" -f "$file" >/dev/null 2>&1 || true
    fi
    if ! (umask 077; cat "$filtered" >> "$file"); then
        rm -f "$filtered"
        return 1
    fi
    rm -f "$filtered"
    chmod 600 "$file"
}

# core_node_add_replace_plan NAME IP PORT FP — проверка отпечатка по скану и
# CORE_PLAN_LINES замены ключа узла (прежние и новый отпечатки) для
# node add --replace-host-key. Ничего не записывает.
core_node_add_replace_plan() {
    local name="${1:-}" ip="${2:-}" port="${3:-}" fp="${4:-}" host known
    CORE_PLAN_LINES=()
    if ! _node_name_valid "$name"; then
        rc_fail invalid "Недопустимое имя ноды '${name}': латиница, цифры, «.», «_», «-»."
        return 1
    fi
    if _node_exists "$name"; then
        rc_fail conflict "Нода с именем '${name}' уже существует."
        return 1
    fi
    if ! node_ssh_host_valid "$ip"; then
        rc_fail invalid "Адрес сервера должен быть IP или именем хоста: латиница, цифры, «.», «:», «_», «-»; первый символ не «-»."
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        rc_fail invalid "Порт SSH должен быть числом от 1 до 65535."
        return 1
    fi
    port=$((10#$port))
    _node_hostkey_scan_match "$ip" "$port" "$fp" || return 1
    rm -f "$NODE_HOSTKEY_SCAN"
    NODE_HOSTKEY_SCAN=""
    host="$ip"
    [[ "$port" != 22 ]] && host="[$ip]:$port"
    known=$(_node_hostkey_known_fps "$host" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
    CORE_PLAN_LINES=("Нода: $name $ip:$port" "Прежние отпечатки: ${known:-нет}"
        "Новый отпечаток: $fp" "Прежние записи known_hosts для узла будут удалены.")
}

# ─── Добавление ноды ─────────────────────────────────────────────────────────
# core_node_add NAME IP PORT USER AUTH PASSWORD TAG HOSTKEY_MODE DEFER
# HOSTKEY_MODE: accept-new | known-only | SHA256:<отпечаток> (узел неизвестен
# или уже закреплён с этим ключом, иначе host_key_changed) |
# replace:SHA256:<отпечаток> (замена ключа узла; подтверждение — план
# core_node_add_replace_plan до вызова); DEFER: true|false.
# Результат: CORE_NODE_ADD_ID, CORE_NODE_ADD_NEEDS_SETUP (true|false).
core_node_add() {
    local _name="${1:-}" _ip="${2:-}" _port="${3:-}" _user="${4:-}" _auth="${5:-}"
    local _pass="${6:-}" _tag="${7:-}" _hk_mode="${8:-known-only}" _defer="${9:-false}"
    # Согласованные отпечатки онбординга относятся к другому запросу.
    local ONBOARDING_PLANNED_FPS=""
    CORE_NODE_ADD_ID="" CORE_NODE_ADD_NEEDS_SETUP=false

    if [[ -z "$_name" ]]; then
        rc_fail invalid "Имя ноды не может быть пустым."
        return 1
    fi
    if ! _node_name_valid "$_name"; then
        rc_fail invalid "Недопустимое имя ноды '${_name}': латиница, цифры, «.», «_», «-»."
        return 1
    fi
    if _node_exists "$_name"; then
        rc_fail conflict "Нода с именем '${_name}' уже существует."
        return 1
    fi
    if [[ -z "$_ip" ]]; then
        rc_fail invalid "IP не может быть пустым."
        return 1
    fi
    if ! node_ssh_host_valid "$_ip"; then
        rc_fail invalid "Адрес сервера должен быть IP или именем хоста: латиница, цифры, «.», «:», «_», «-»; первый символ не «-»."
        return 1
    fi
    if [[ ! "$_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$_port < 1 || 10#$_port > 65535 )); then
        rc_fail invalid "Порт SSH должен быть числом от 1 до 65535."
        return 1
    fi
    _port=$((10#$_port))
    if [[ -z "$_user" ]]; then
        rc_fail invalid "Логин не может быть пустым."
        return 1
    fi
    if ! node_ssh_user_valid "$_user"; then
        rc_fail invalid "Логин SSH: до 32 символов — латиница, цифры, «.», «_», «-»; первый символ — буква или «_»."
        return 1
    fi
    case "$_auth" in
        key) _pass="" ;;
        password)
            if [[ -z "$_pass" ]]; then
                rc_fail invalid "Пароль не может быть пустым."
                return 1
            fi
            ;;
        *) rc_fail invalid "Способ авторизации должен быть key или password."; return 1 ;;
    esac
    if [[ -z "$_tag" ]]; then
        rc_fail invalid "Тег обязателен — он различает прокси разных нод."
        return 1
    fi
    if ! _node_tag_valid "$_tag"; then
        rc_fail invalid "Недопустимый тег '${_tag}': до 32 символов, без управляющих символов и ;\"'\`\$\\|&<>{}[]#,:/."
        return 1
    fi
    case "$_hk_mode" in
        accept-new|known-only|SHA256:?*|replace:SHA256:?*) ;;
        *) rc_fail invalid "Неверный режим проверки ключа сервера: ${_hk_mode}."; return 1 ;;
    esac
    case "$_defer" in
        false) ;;
        true)
            if [[ "${CONFIG_SOURCE:-local}" != github ]]; then
                rc_fail invalid "Отложенная SSH-настройка доступна только в режиме GitHub."
                return 1
            fi
            ;;
        *) rc_fail invalid "Неверное значение DEFER: ${_defer}."; return 1 ;;
    esac

    # Host key: read-only checks before any state change.
    local _hk_host="$_ip" _hk_scan="" _hk_fp="" _known
    [[ "$_port" != 22 ]] && _hk_host="[$_ip]:$_port"
    case "$_hk_mode" in
        known-only)
            if ! _node_hostkey_known "$_hk_host"; then
                if ! _node_hostkey_scan "$_ip" "$_port"; then
                    rc_fail remote_failed "Не удалось получить ключ сервера ${_ip}:${_port}."
                    return 1
                fi
                rm -f "$NODE_HOSTKEY_SCAN"
                local _fps_json
                _fps_json=$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}" | jq -R . | jq -sc '{fingerprints:.}')
                info "Отпечатки ключа сервера ${_ip}:${_port}: ${NODE_HOSTKEY_FPS[*]}"
                rc_fail host_key_unknown "Ключ сервера не закреплён. Проверьте отпечаток и повторите с --host-key <SHA256:…> или --accept-new-host-key." "$_fps_json"
                return 1
            fi
            ;;
        SHA256:*|replace:SHA256:*)
            _hk_fp="${_hk_mode#replace:}"
            _node_hostkey_scan_match "$_ip" "$_port" "$_hk_fp" || return 1
            _hk_scan="$NODE_HOSTKEY_SCAN"
            _known=$(_node_hostkey_known_fps "$_hk_host")
            if [[ -n "$_known" ]] && printf '%s\n' "$_known" | grep -qxF -- "$_hk_fp"; then
                # Ключ уже закреплён: known_hosts не меняется.
                rm -f "$_hk_scan"
                _hk_scan=""
            elif [[ -n "$_known" && "$_hk_mode" != replace:* ]]; then
                rm -f "$_hk_scan"
                rc_fail host_key_changed "Ключ сервера ${_ip}:${_port} уже известен и отличается от указанного. Проверьте отпечаток и повторите с --replace-host-key <SHA256:…>." \
                    "$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}" | jq -R . |
                        jq -sc --arg h "$_ip" --argjson p "$_port" '{host:$h, port:$p, fingerprints:.}')"
                return 1
            fi
            ;;
    esac

    local _node_id
    if ! _node_id=$(openssl rand -hex 16 2>/dev/null) || [[ ! "$_node_id" =~ ^[0-9a-f]{32}$ ]]; then
        [[ -n "$_hk_scan" ]] && rm -f "$_hk_scan"
        rc_fail failed "Не удалось создать стабильный идентификатор ноды."
        return 1
    fi
    local _identity="system"
    [[ "$_auth" == password ]] && _identity=""

    # Stable ID is allocated before connection testing and never changes on rename.
    NODE_ID="$_node_id"; NODE_IDENTITY="$_identity"; NODE_TAG="$_tag"
    NODE_NAME="$_name"; SERVER_IP="$_ip"; SERVER_PORT="$_port"
    SERVER_USER="$_user"; SERVER_PASS="$_pass"; SERVER_AUTH="$_auth"

    local _needs_setup=false _managed_identity=false _known_backup="" _manifest_backup=""
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        if [[ -f "${SSH_KNOWN_HOSTS:-}" ]]; then
            if ! _known_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.known-hosts.XXXXXX") ||
               ! cp "$SSH_KNOWN_HOSTS" "$_known_backup"; then
                rm -f "$_known_backup" "$_hk_scan"
                rc_fail failed "Не удалось сохранить резервную копию известных SSH-ключей."
                return 1
            fi
        fi
        if [[ -f "${STATE_MANIFEST:-}" ]]; then
            if ! _manifest_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.manifest.XXXXXX") ||
               ! cp "$STATE_MANIFEST" "$_manifest_backup"; then
                rm -f "$_known_backup" "$_manifest_backup" "$_hk_scan"
                rc_fail failed "Не удалось сохранить резервную копию манифеста."
                return 1
            fi
        fi
    fi
    # Локальный режим: копия ~/.ssh/known_hosts до закрепления ключа сервера,
    # чтобы неудачное добавление не оставило в нём изменений.
    local _local_known_backup="" _local_known_existed=false _local_known_file
    if [[ "${CONFIG_SOURCE:-local}" != github && -n "$_hk_scan" ]]; then
        _local_known_file=$(_node_known_hosts_file)
        [[ -f "$_local_known_file" ]] && _local_known_existed=true
        if ! _local_known_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.known-hosts.XXXXXX") ||
           { [[ "$_local_known_existed" == true ]] && ! cp "$_local_known_file" "$_local_known_backup"; }; then
            rm -f "$_local_known_backup" "$_hk_scan"
            rc_fail failed "Не удалось сохранить резервную копию известных SSH-ключей."
            return 1
        fi
    fi

    if [[ -n "$_hk_scan" ]]; then
        if ! _node_hostkey_pin "$_hk_host" "$_hk_scan" "$_hk_fp"; then
            rm -f "$_hk_scan"
            if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
                _github_add_abort "$_node_id" false "$_known_backup" "$_manifest_backup"
            else
                _local_add_abort "" "$_local_known_backup" "$_local_known_existed"
            fi
            rc_fail failed "Не удалось записать ключ сервера ${_ip}:${_port}."
            return 1
        fi
        rm -f "$_hk_scan"
        success "Ключ сервера ${_ip}:${_port} закреплён (${_hk_fp})"
    fi

    if [[ "${CONFIG_SOURCE:-local}" == "github" && "$_auth" == "key" ]]; then
        local _previous_defer="${PORTABLE_IDENTITY_DEFER_CONFIG:-0}"
        local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
        PORTABLE_IDENTITY_DEFER_CONFIG=1
        SSH_ALLOW_PORTABLE_ONBOARDING=1
        _provision_portable_identity "$_node_id"
        local _provision_rc=$?
        PORTABLE_IDENTITY_DEFER_CONFIG="$_previous_defer"
        SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
        if [[ $_provision_rc -eq 0 ]]; then
            _managed_identity=true
            _identity="$_node_id"
            NODE_IDENTITY="$_node_id"
        elif [[ "$_defer" == true ]]; then
            _needs_setup=true
        else
            _github_add_abort "$_node_id" false "$_known_backup" "$_manifest_backup"
            rc_fail onboarding_failed "Не удалось настроить переносимый SSH-ключ. Изменения отменены."
            return 1
        fi
    fi

    info "Проверяем подключение..."
    local _ssh_err _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
    [[ "${CONFIG_SOURCE:-local}" == "github" ]] && SSH_ALLOW_PORTABLE_ONBOARDING=1
    _ssh_err=$(ssh_run -- "echo ok" 2>&1)
    SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
    if echo "$_ssh_err" | grep -q "^ok$"; then
        success "Подключение успешно"
    elif echo "$_ssh_err" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        else
            _local_add_abort "" "$_local_known_backup" "$_local_known_existed"
        fi
        local _changed_fps='[]'
        if _node_hostkey_scan "$_ip" "$_port"; then
            rm -f "$NODE_HOSTKEY_SCAN"
            _changed_fps=$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}" | jq -R . | jq -sc .)
        fi
        rc_fail host_key_changed "Ключ сервера изменился. Проверьте отпечаток и повторите с --replace-host-key <SHA256:…>." \
            "$(jq -cn --arg h "$_ip" --argjson p "$_port" --argjson f "$_changed_fps" '{host:$h, port:$p, fingerprints:$f}')"
        return 1
    else
        local _reason _hint=""
        _reason=$(echo "$_ssh_err" | grep -iE "refused|denied|closed|timed out|No route|resolve|reset" | head -1 | tr -d '\r')
        if [[ "${CONFIG_SOURCE:-local}" == "github" && "$_defer" == true ]]; then
            warn "Не удалось подключиться к '${_name}'${_reason:+: $_reason}. SSH-настройка отложена."
            _needs_setup=true
        else
            if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            else
                _local_add_abort "" "$_local_known_backup" "$_local_known_existed"
            fi
            if [[ "$_auth" == "key" && "${CONFIG_SOURCE:-local}" != "github" ]]; then
                _hint="ssh-copy-id ${_user}@${_ip}"
                warn "Добавьте SSH-ключ на сервер командой: $_hint"
            fi
            rc_fail remote_failed "Не удалось подключиться к ${_name}.${_reason:+ Причина: $_reason}" \
                "$(jq -cn --arg r "$_reason" --arg h "$_hint" \
                    '{reason:(if $r == "" then null else $r end)} + (if $h == "" then {} else {hint:$h} end)')"
            return 1
        fi
    fi
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]] && ! _ssh_known_host_present; then
        local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
        SSH_ALLOW_PORTABLE_ONBOARDING=1
        _ssh_pin_host_key
        local _pin_rc=$?
        SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
        if [[ $_pin_rc -ne 0 ]]; then
            if [[ "$_defer" == true ]]; then
                warn "Не удалось закрепить SSH-ключ ноды '${_name}'. SSH-настройка отложена."
                _needs_setup=true
            else
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
                rc_fail onboarding_failed "Не удалось закрепить SSH-ключ ноды '${_name}'. Изменения отменены."
                return 1
            fi
        fi
    fi

    # Explicit hardening may have provisioned a managed identity.
    _auth="$SERVER_AUTH"
    _port="$SERVER_PORT"
    _pass="$SERVER_PASS"
    [[ "$_auth" == "key" ]] && _identity="${NODE_IDENTITY:-system}" || _identity=""

    local _secret_id=""
    [[ "$_auth" == "password" ]] && _secret_id="node:${_node_id}:ssh-password"
    # Persist the secret first: GitHub's jq_w hook validates the candidate
    # against the complete state and must see the password it references.
    if [[ "$_auth" == "password" ]] && ! node_secret_set "$_node_id" "$_pass"; then
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        else
            _local_add_abort "" "$_local_known_backup" "$_local_known_existed"
        fi
        rc_fail failed "Не удалось сохранить пароль SSH для ноды."
        return 1
    fi
    # GitHub's jq_w hook requires manifest issues to match the candidate's
    # missing resources; _github_add_abort restores the manifest backup.
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        if [[ "$_auth" == "key" &&
              ( "$_identity" == "system" || ! -f "$SSH_IDENTITIES_DIR/$_node_id" ) ]]; then
            _needs_setup=true
            state_portability_add_issue "$_node_id" missing_identity || {
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
                rc_fail failed "Не удалось записать отметку об отложенной SSH-настройке."
                return 1
            }
        fi
        if ! _ssh_known_host_present; then
            _needs_setup=true
            state_portability_add_issue "$_node_id" missing_host_key || {
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
                rc_fail failed "Не удалось записать отметку об отложенной SSH-настройке."
                return 1
            }
        fi
    fi
    if ! jq_w --arg id "$_node_id" --arg n "$_name" --arg ip "$_ip" \
        --argjson port "$_port" --arg u "$_user" --arg a "$_auth" \
        --arg identity "$_identity" --arg secret_id "$_secret_id" --arg t "$_tag" '
        .nodes += [{
            id:$id, name:$n, ip:$ip, port:$port, user:$u, auth:$a,
            identity:(if $a=="key" then ($identity // "system") else null end),
            secret_id:(if $a=="password" then $secret_id else null end),
            tag:$t, aliases:{}
        }]'; then
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        else
            _local_add_abort "$_node_id" "$_local_known_backup" "$_local_known_existed"
        fi
        rc_fail failed "Не удалось сохранить ноду '${_name}'."
        return 1
    fi
    if ! state_checkpoint >/dev/null 2>&1; then
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        elif ! _local_add_abort "$_node_id" "$_local_known_backup" "$_local_known_existed" &&
             _node_exists "$_name"; then
            # Запись ноды убрать не удалось: нода сохранена — partial с её данными.
            CORE_NODE_ADD_ID="$_node_id"
            CORE_NODE_ADD_NEEDS_SETUP="$_needs_setup"
            rc_fail partial "Нода '${_name}' сохранена, но локальную точку восстановления сохранить не удалось."
            return 1
        fi
        rc_fail failed "Не удалось сохранить локальную точку восстановления. Изменения отменены."
        return 1
    fi
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        if declare -F github_config_checkpoint >/dev/null 2>&1 &&
           ! github_config_checkpoint; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            rc_fail failed "Не удалось обновить снимок конфигурации GitHub."
            return 1
        fi
    fi
    rm -f "$_known_backup" "$_manifest_backup" "$_local_known_backup"
    NODE_ID="$_node_id"
    NODE_IDENTITY="${_identity:-}"
    CORE_NODE_ADD_ID="$_node_id"
    CORE_NODE_ADD_NEEDS_SETUP="$_needs_setup"
    success "Нода '${_name}' сохранена"
}

# ─── Переименование ноды ─────────────────────────────────────────────────────
core_node_rename() {
    local old="${1:-}" new="${2:-}"
    if ! _node_exists "$old"; then
        rc_fail not_found "Нода '${old}' не найдена."
        return 1
    fi
    if [[ -z "$new" ]]; then
        rc_fail invalid "Новое имя ноды не может быть пустым."
        return 1
    fi
    if ! _node_name_valid "$new"; then
        rc_fail invalid "Недопустимое имя ноды '${new}': латиница, цифры, «.», «_», «-»."
        return 1
    fi
    [[ "$new" == "$old" ]] && return 0
    if _node_exists "$new"; then
        rc_fail conflict "Нода с именем '${new}' уже существует."
        return 1
    fi
    # Обновляем имя во всех местах: nodes, connections[].node, clients.nodes, clients.connections[].node
    jq_w --arg old "$old" --arg new "$new" '
        .nodes |= map(if .name==$old then .name=$new else . end) |
        .connections |= map(if .node==$old then .node=$new else . end) |
        .clients |= map(
            (if .nodes then .nodes |= map(if .==$old then $new else . end) else . end) |
            (if .connections then .connections |= map(if .node==$old then .node=$new else . end) else . end)
        )
    ' || return 1
    success "Нода '${old}' переименована в '${new}'"
}

# ─── Тег ноды ───────────────────────────────────────────────────────────────
core_node_set_tag() {
    local name="${1:-}" tag="${2:-}"
    if ! _node_exists "$name"; then
        rc_fail not_found "Нода '${name}' не найдена."
        return 1
    fi
    if ! _node_tag_valid "$tag"; then
        rc_fail invalid "Недопустимый тег '${tag}': до 32 символов, без управляющих символов и ;\"'\`\$\\|&<>{}[]#,:/."
        return 1
    fi
    jq_w --arg n "$name" --arg t "$tag" \
        '.nodes |= map(if .name==$n then .tag=$t else . end)' || return 1
    success "Тег ноды '$name' сохранён"
}

# ─── Псевдонимы подключений ноды ───────────────────────────────────────────────
# core_node_set_aliases NAME ALIASES_JSON — объект «исходное имя → псевдоним».
core_node_set_aliases() {
    local name="${1:-}" aliases="${2:-}"
    if ! _node_exists "$name"; then
        rc_fail not_found "Нода '${name}' не найдена."
        return 1
    fi
    if ! jq -e 'type=="object" and all(.[]; type=="string")' <<< "$aliases" >/dev/null 2>&1; then
        rc_fail invalid "Псевдонимы должны быть JSON-объектом строк."
        return 1
    fi
    jq_w --arg n "$name" --argjson a "$aliases" \
        '(.nodes[] | select(.name==$n)).aliases = $a' || return 1
    success "Псевдонимы для $name сохранены"
}

# ─── Удаление ноды ───────────────────────────────────────────────────────────
_node_delete_restore() {
    local config_backup="$1" secrets_backup="$2" manifest_backup="$3"
    cp -p "$config_backup" "$CONFIG_JSON" || return 1
    cp -p "$secrets_backup" "$SECRETS_JSON" || return 1
    if [[ -n "$manifest_backup" && -f "$manifest_backup" ]]; then
        cp -p "$manifest_backup" "$STATE_MANIFEST" || return 1
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
        github_config_checkpoint || return 1
        github_sync_flush || return 1
    fi
}

# Never fall back to a fresh login after revoking its only accepted key.
# The private ControlMaster socket keeps the authenticated transport alive
# until both the local checkpoint and GitHub commit have completed.
_node_delete_key_run() {
    local socket="$1"
    shift
    ssh_run -S "$socket" -o ControlMaster=no -o ProxyCommand=false -- "$@"
}

_node_delete_key_restore() {
    local socket="$1" pubkey="$2" quoted
    printf -v quoted %q "$pubkey"
    _node_delete_key_run "$socket" "key=$quoted
mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys &&
{ grep -qxF -- \"\$key\" ~/.ssh/authorized_keys ||
  printf '%s\n' \"\$key\" >> ~/.ssh/authorized_keys; } &&
grep -qxF -- \"\$key\" ~/.ssh/authorized_keys" || return 1
    # Verify a new login, not just the still-authenticated master session.
    ssh_run -S none -o ControlMaster=no -o BatchMode=yes \
        -i "$SSH_IDENTITIES_DIR/$NODE_IDENTITY" -o IdentitiesOnly=yes -- "true"
}

_node_delete_rollback() {
    local backup="$1" socket="$2" revoked="$3" pubkey="$4" restored=true
    if [[ "$revoked" == true ]] && ! _node_delete_key_restore "$socket" "$pubkey"; then
        warn "Не удалось подтвердить восстановление SSH-доступа. Резервные копии: $backup; сокет SSH-соединения: $socket"
        restored=false
    fi
    _node_delete_restore "$backup/config" "$backup/secrets" \
        "$([[ -f "$backup/manifest" ]] && printf '%s' "$backup/manifest")" || {
        warn "Не удалось полностью восстановить локальное состояние и GitHub. Резервные копии сохранены: $backup"
        restored=false
    }
    [[ "$restored" == true ]] || return 1
    if [[ -n "$socket" ]]; then
        ssh_run -S "$socket" -O exit -- >/dev/null 2>&1 || true
        rm -rf "${socket%/*}"
    fi
    rm -rf "$backup"
}

_node_delete_scope_label() {
    case "${1:-}:${2:-}" in
        local:false) printf '%s' "Удалить только из remote-control; сервер и SSH-ключ оставить" ;;
        local:true) printf '%s' "Удалить из remote-control и отозвать управляемый SSH-ключ" ;;
        server:false) printf '%s' "Удалить из remote-control и все компоненты Essence на сервере" ;;
        server:true) printf '%s' "Удалить из remote-control, все компоненты Essence и отозвать SSH-ключ" ;;
        *) return 1 ;;
    esac
}

# _node_delete_options_json NAME — варианты удаления [{scope,revoke_key,label}]:
# local; local+отзыв при управляемом ключе; server; server+отзыв.
_node_delete_options_json() {
    local name="${1:-}" id identity managed=false scope revoke items=()
    id=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .id')
    identity=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .identity // ""')
    [[ "${CONFIG_SOURCE:-local}" == github && -n "$id" && "$identity" == "$id" ]] && managed=true
    for scope in local server; do
        for revoke in false true; do
            [[ "$revoke" == false || "$managed" == true ]] || continue
            items+=("$(jq -cn --arg s "$scope" --argjson r "$revoke" \
                --arg l "$(_node_delete_scope_label "$scope" "$revoke")" \
                '{scope:$s, revoke_key:$r, label:$l}')")
        done
    done
    printf '%s\n' "${items[@]}" | jq -sc .
}

# ─── Доверие новому ключу сервера ────────────────────────────────────────────
# core_node_trust_host_key_plan NAME FP — снимок ключей ноды (NODE_HOSTKEY_SCAN,
# удаляет вызывающий) и CORE_PLAN_LINES; host_key_mismatch, если FP нет в снимке.
core_node_trust_host_key_plan() {
    local name="${1:-}" fp="${2:-}" ip port host known
    CORE_PLAN_LINES=()
    NODE_HOSTKEY_SCAN=""
    if ! _node_exists "$name"; then
        rc_fail not_found "Нода '${name}' не найдена."
        return 1
    fi
    if [[ "$fp" != SHA256:?* ]]; then
        rc_fail usage "Отпечаток ключа ожидается в виде SHA256:…"
        return 1
    fi
    ip=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .ip')
    port=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .port')
    if ! node_ssh_host_valid "$ip" || [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then
        rc_fail invalid "Запись ноды '${name}' повреждена или неполна."
        return 1
    fi
    _node_hostkey_scan_match "$ip" "$port" "$fp" || return 1
    host="$ip"
    [[ "$port" != 22 ]] && host="[$ip]:$port"
    known=$(_node_hostkey_known_fps "$host" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
    CORE_PLAN_LINES=("Нода: $name $ip:$port" "Прежние отпечатки: ${known:-нет}"
        "Новый отпечаток: $fp" "Прежние записи known_hosts для узла будут удалены.")
}

# core_node_trust_host_key NAME SCAN FP — удалить прежние записи узла и
# закрепить из снимка только ключ с согласованным отпечатком FP.
core_node_trust_host_key() {
    local name="${1:-}" scan="${2:-}" fp="${3:-}" ip port file host
    [[ -n "$scan" && -s "$scan" ]] || { rc_fail failed "Снимок ключа сервера недоступен."; return 1; }
    ip=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .ip')
    port=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .port')
    host="$ip"
    [[ "$port" != 22 ]] && host="[$ip]:$port"
    file=$(_node_known_hosts_file)
    # Проверить снимок до удаления прежних записей.
    local check
    check=$(umask 077; mktemp "${TMPDIR:-/tmp}/essence-hostkey.XXXXXX") || {
        rc_fail failed "Не удалось записать новый ключ сервера ${ip}:${port}."
        return 1
    }
    if ! _node_hostkey_filter "$scan" "$check" "$fp"; then
        rm -f "$check"
        rc_fail host_key_mismatch "В снимке ключей сервера ${ip}:${port} нет ключа с отпечатком ${fp}."
        return 1
    fi
    rm -f "$check"
    if [[ -n "$file" && -f "$file" ]]; then
        ssh-keygen -R "$ip" -f "$file" >/dev/null 2>&1 || true
        [[ "$port" != 22 ]] && { ssh-keygen -R "[$ip]:$port" -f "$file" >/dev/null 2>&1 || true; }
    fi
    if ! _node_hostkey_pin "$host" "$scan" "$fp"; then
        rc_fail failed "Не удалось записать новый ключ сервера ${ip}:${port}."
        return 1
    fi
    success "Новый ключ сервера ноды '${name}' закреплён"
}

# Validates delete arguments and loads the node record into _NODE_DEL_* globals.
_node_delete_validate() {
    local name="${1:-}" scope="${2:-}" revoke="${3:-}" idx
    idx=$(jq_r --arg n "$name" '[.nodes[]?.name] | index($n) // empty')
    if [[ -z "$name" || ! "$idx" =~ ^[0-9]+$ ]]; then
        rc_fail not_found "Нода '${name}' не найдена."
        return 1
    fi
    case "$scope" in
        local|server) ;;
        *) rc_fail invalid "Объём удаления должен быть local или server."; return 1 ;;
    esac
    case "$revoke" in
        true|false) ;;
        *) rc_fail invalid "Неверное значение отзыва ключа: ${revoke}."; return 1 ;;
    esac
    _NODE_DEL_INDEX=$((idx + 1))
    _NODE_DEL_ID=$(jq_r --argjson i "$idx" '.nodes[$i].id')
    _NODE_DEL_IP=$(jq_r --argjson i "$idx" '.nodes[$i].ip')
    _NODE_DEL_PORT=$(jq_r --argjson i "$idx" '.nodes[$i].port')
    _NODE_DEL_IDENTITY=$(jq_r --argjson i "$idx" '.nodes[$i].identity // ""')
    _NODE_DEL_USER=$(jq_r --argjson i "$idx" '.nodes[$i].user')
    # Удаление стирает файл ключа по .identity: допустим только собственный id.
    if [[ ! "$_NODE_DEL_ID" =~ ^[0-9a-fA-F]{32}$ ]] ||
       [[ -n "$_NODE_DEL_IDENTITY" && "$_NODE_DEL_IDENTITY" != system &&
          "$_NODE_DEL_IDENTITY" != "$_NODE_DEL_ID" ]]; then
        rc_fail invalid "Запись ноды '${name}' повреждена: недопустимая ссылка на SSH-ключ."
        return 1
    fi
    if [[ "$revoke" == true ]] &&
       ! [[ "${CONFIG_SOURCE:-local}" == github && -n "$_NODE_DEL_ID" &&
            "$_NODE_DEL_IDENTITY" == "$_NODE_DEL_ID" ]]; then
        rc_fail invalid "Отзыв ключа доступен только для управляемого ключа в режиме GitHub."
        return 1
    fi
    # Удаление компонентов на сервере при отложенной SSH-настройке GitHub
    # невозможно: needs_setup до подтверждения планом.
    if [[ "$scope" == server ]] && node_load "$_NODE_DEL_INDEX" >/dev/null 2>&1; then
        ssh_require_portable || return 1
    fi
}

# core_node_delete_plan NAME SCOPE REVOKE → CORE_PLAN_LINES.
core_node_delete_plan() {
    local name="${1:-}" scope="${2:-}" revoke="${3:-}" client
    CORE_PLAN_LINES=()
    _node_delete_validate "$name" "$scope" "$revoke" || return 1
    local affected=()
    while IFS= read -r client; do
        [[ -n "$client" ]] && affected+=("$client")
    done < <(jq_r --arg n "$name" '
        . as $config | .clients[] | . as $client |
        select((.nodes // [] | index($n)) != null or
               ([.connections[]?.node] | index($n)) != null or
               (.inherit_nodes_from_group != false and
                ([ $config.connections[] | select(.node==$n) | .groups[]?.name ] | index($client.group)) != null)) |
        .name')
    CORE_PLAN_LINES=("Нода: $name  $_NODE_DEL_IP:$_NODE_DEL_PORT" "Пользователь: $_NODE_DEL_USER"
        "Объём: $(_node_delete_scope_label "$scope" "$revoke")"
        "Затронутые клиенты: ${affected[*]:-нет}")
    if [[ "$scope" == server ]]; then
        CORE_PLAN_LINES+=("Mihomo: бинарь, служба, конфигурация и клиентские записи."
            "AmneziaWG: служба, конфигурация, ключи и все клиенты."
            "WARP: /root/wgcf и профиль."
            "Сайты nginx Essence, webroot и /etc/nginx/ssl целиком."
            "Хостинг подписок, Telegram Proxy и acme.sh."
            "/etc/sysctl.d/99-vpn-speedup.conf; IPv6 будет восстановлен."
            "Пакеты nginx и AmneziaWG не удаляются."
            "Правила UFW будут сброшены. Настройки SSH сохранятся.")
        if [[ "$_NODE_DEL_PORT" == 22 ]]; then
            CORE_PLAN_LINES+=("UFW будет отключён.")
        else
            CORE_PLAN_LINES+=("UFW останется включён: открыт только SSH TCP/$_NODE_DEL_PORT.")
        fi
    fi
    if [[ "$revoke" == true ]]; then
        CORE_PLAN_LINES+=("Управляемый SSH-ключ будет отозван на ноде.")
    else
        CORE_PLAN_LINES+=("SSH-ключ на ноде сохранится.")
    fi
}

# _node_delete_fail CODE MESSAGE — ошибка core_node_delete: после удаления
# компонентов на сервере (CORE_NODE_DELETE_REMOTE_REMOVED) — partial, иначе CODE.
_node_delete_fail() {
    if [[ "${CORE_NODE_DELETE_REMOTE_REMOVED:-false}" == true ]]; then
        rc_fail partial "Компоненты на сервере удалены. $2"
    else
        rc_fail "$1" "$2"
    fi
}

# core_node_delete NAME SCOPE REVOKE — SCOPE: local|server; REVOKE: true|false.
# Результат для partial: CORE_NODE_DELETE_REMOTE_REMOVED (компоненты на сервере
# удалены) и CORE_NODE_DELETE_DELETED (нода удалена из remote-control).
core_node_delete() {
    local _name="${1:-}" scope="${2:-}" _revoke_requested="${3:-}"
    CORE_NODE_DELETE_REMOTE_REMOVED=false CORE_NODE_DELETE_DELETED=false
    _node_delete_validate "$_name" "$scope" "$_revoke_requested" || return 1
    local _idx="$_NODE_DEL_INDEX" _id="$_NODE_DEL_ID" _ip="$_NODE_DEL_IP"
    local _port="$_NODE_DEL_PORT" _identity="$_NODE_DEL_IDENTITY" _load_rc
    if [[ "$scope" == server ]]; then
        local entry
        node_load "$_idx"
        _load_rc=$?
        if [[ $_load_rc -eq 2 ]]; then
            rc_fail missing_secret "Пароль SSH ноды '${_name}' недоступен. Нода сохранена в remote-control."
            return 1
        fi
        if [[ $_load_rc -ne 0 ]] || ! ensure_remote_scripts_current; then
            rc_fail remote_failed "Удаление компонентов на сервере не завершено. Нода сохранена в remote-control."
            return 1
        fi
        printf -v entry %q "$REMOTE_DIR/setup-essence.sh"
        if ! SSH_RUN_TIMEOUT=900 ssh_run -- "bash $entry uninstall --force"; then
            rc_fail remote_failed "Удаление компонентов на сервере не завершено. Нода сохранена в remote-control."
            return 1
        fi
        CORE_NODE_DELETE_REMOTE_REMOVED=true
    fi
    # Prepare every rollback artifact before revoking remote authorization.
    local backup socket="" pubkey="" key_present="" revoked=false quoted
    backup=$(umask 077; mktemp -d "${CONFIG_DIR:-/tmp}/.node-delete.XXXXXX") || {
        _node_delete_fail failed "Не удалось подготовить резервную копию. Нода сохранена в remote-control."
        return 1
    }
    if ! cp -p "$CONFIG_JSON" "$backup/config" ||
       ! cp -p "$SECRETS_JSON" "$backup/secrets" ||
       { [[ -f "${STATE_MANIFEST:-}" ]] && ! cp -p "$STATE_MANIFEST" "$backup/manifest"; }; then
        rm -rf "$backup"
        _node_delete_fail failed "Не удалось подготовить резервную копию. Нода сохранена в remote-control."
        return 1
    fi
    if [[ "$_revoke_requested" == true ]]; then
        if ! node_load "$_idx" ||
           ! cp -p "$SSH_IDENTITIES_DIR/$_id.pub" "$backup/key.pub" ||
           ! pubkey=$(cat "$backup/key.pub") || [[ -z "$pubkey" ]]; then
            rm -rf "$backup"
            _node_delete_fail failed "Не удалось подготовить отзыв SSH-ключа. Нода сохранена в remote-control."
            return 1
        fi
        # Unix-domain paths are limited to ~104 bytes; CONFIG_DIR may be longer.
        socket=$(umask 077; mktemp -d /tmp/essence-ssh.XXXXXX) || {
            rm -rf "$backup"
            _node_delete_fail failed "Не удалось подготовить временный сокет SSH. Ключ не отозван."
            return 1
        }
        socket="$socket/control"
        # Мастер уходит в фон (-f): его stdio не должен держать журнал serve.
        if ! ssh_run -M -N -f -S "$socket" -o ControlPersist=no -- </dev/null >/dev/null 2>/dev/null; then
            ssh_run -S "$socket" -O exit -- >/dev/null 2>&1 || true
            rm -rf "$backup" "${socket%/*}"
            _node_delete_fail remote_failed "Не удалось сохранить SSH-соединение для восстановления доступа. Ключ не отозван."
            return 1
        fi
        printf -v quoted %q "$pubkey"
        key_present=$(_node_delete_key_run "$socket" "key=$quoted
if [ ! -f ~/.ssh/authorized_keys ]; then printf absent
elif grep -qxF -- \"\$key\" ~/.ssh/authorized_keys; then printf present
elif [ \"\$?\" -eq 1 ]; then printf absent
else exit 1; fi") || key_present=""
        case "$key_present" in
            present)
                # Mark before sending: a lost reply may follow successful revocation.
                revoked=true
                if ! _node_delete_key_run "$socket" "key=$quoted
umask 077
tmp=\$(mktemp ~/.ssh/authorized_keys.XXXXXX) || exit 1
if awk -v key=\"\$key\" '\$0 != key' ~/.ssh/authorized_keys > \"\$tmp\" &&
   mv \"\$tmp\" ~/.ssh/authorized_keys; then
    grep -qxF -- \"\$key\" ~/.ssh/authorized_keys
    [ \"\$?\" -eq 1 ]
else rm -f \"\$tmp\"; exit 1; fi"; then
                    _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
                    _node_delete_fail remote_failed "SSH-ключ не отозван. Нода сохранена в remote-control."
                    return 1
                fi
                ;;
            absent) ;;
            *)
                _node_delete_rollback "$backup" "$socket" false "$pubkey" || true
                _node_delete_fail remote_failed "Не удалось проверить SSH-ключ. Нода сохранена в remote-control."
                return 1
                ;;
        esac
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github ]] &&
       ! state_portability_remove_node "$_id"; then
        _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
        _node_delete_fail failed "Удаление ноды отменено: манифест не удалось обновить."
        return 1
    fi
    if ! jq_w --arg id "$_id" --arg n "$_name" '
        .nodes |= [.[] | select(.id != $id)] |
        .connections |= [.[] | select(.node!=$n)] |
        .clients |= map(
            (if .nodes then .nodes |= [.[] | select(.!=$n)] else . end) |
            (if .connections then .connections |= [.[] | select(.node!=$n)] else . end)
        )
    ' ||
       ! node_secret_delete "$_id" ||
       ! state_checkpoint; then
        _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
        _node_delete_fail failed "Удаление ноды отменено: локальное состояние не удалось сохранить."
        return 1
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github ]] &&
       { ! github_config_checkpoint || ! github_sync_flush; }; then
        _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
        _node_delete_fail failed "Удаление ноды отменено: состояние GitHub не удалось сохранить."
        return 1
    fi
    # Удаление зафиксировано: копия с секретами больше не нужна.
    CORE_NODE_DELETE_DELETED=true
    rm -rf "$backup"
    if [[ -n "$socket" ]]; then
        ssh_run -S "$socket" -O exit -- >/dev/null 2>&1 || true
        rm -rf "${socket%/*}"
    fi
    if [[ -n "$_identity" && "$_identity" == "$_id" ]]; then
        if ! rm -f "$SSH_IDENTITIES_DIR/$_identity" "$SSH_IDENTITIES_DIR/$_identity.pub"; then
            rc_fail partial "Нода удалена, но очистка локального SSH-ключа не завершена: $SSH_IDENTITIES_DIR/$_identity"
            return 1
        fi
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github && -f "${SSH_KNOWN_HOSTS:-}" ]]; then
        if ! ssh-keygen -R "$_ip" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
            rc_fail partial "Нода удалена, но очистка известных SSH-ключей не завершена: $SSH_KNOWN_HOSTS"
            return 1
        fi
        if [[ "$_port" != "22" ]]; then
            if ! ssh-keygen -R "[$_ip]:$_port" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
                rc_fail partial "Нода удалена, но очистка известных SSH-ключей не завершена: $SSH_KNOWN_HOSTS"
                return 1
            fi
        fi
        if ! github_config_checkpoint; then
            GITHUB_SYNC_STATUS=pending
            _github_report_last_error "Очистка SSH-данных не сохранена в GitHub"
            rc_fail partial "Нода удалена, но очистка SSH-данных не сохранена в GitHub."
            return 1
        fi
        github_sync_flush || GITHUB_SYNC_STATUS=pending
    fi
    success "Нода '${_name}' удалена"
    return 0
}

# ─── Проверка доступности ноды ─────────────────────────────────────────────────
# core_node_check NAME — без лока конфигурации.
core_node_check() {
    local name="${1:-}" rc=0
    if ! _node_exists "$name"; then
        rc_fail not_found "Нода '${name}' не найдена."
        return 1
    fi
    node_load_by_name "$name" >/dev/null || rc=$?
    if [[ $rc -eq 2 ]]; then
        rc_fail missing_secret "Пароль SSH ноды '${name}' недоступен."
        return 1
    elif [[ $rc -ne 0 ]]; then
        rc_fail invalid "Запись ноды '${name}' повреждена или неполна."
        return 1
    fi
    ssh_probe || return 1
    success "Нода '${name}' доступна"
}
