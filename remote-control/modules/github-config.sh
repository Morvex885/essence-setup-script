#!/bin/bash
# GitHub-backed portable configuration vault. This module is deliberately
# self-contained: state.sh owns logical state, while this file owns layout and
# transport boundaries.

GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-essence-remote-control-config}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_STORE="${GITHUB_STORE:-${CONFIG_DIR:-.}/github-store.git}"
GITHUB_SESSIONS_DIR="${GITHUB_SESSIONS_DIR:-${CONFIG_DIR:-.}/github-sessions}"
GITHUB_CREDENTIALS_DIR="${GITHUB_CREDENTIALS_DIR:-${CONFIG_DIR:-.}/credentials}"
GITHUB_UNLOCK_FILE="${GITHUB_CREDENTIALS_DIR}/github-config.agekey"
AGE_BIN="${AGE_BIN:-age}"
AGE_KEYGEN_BIN="${AGE_KEYGEN_BIN:-age-keygen}"
GITHUB_SYNC_STATUS="${GITHUB_SYNC_STATUS:-clean}"
GITHUB_SESSION_ID="${GITHUB_SESSION_ID:-}"
GITHUB_WORKTREE="${GITHUB_WORKTREE:-}"
GITHUB_REMOTE="${GITHUB_REMOTE:-}"
GITHUB_LAST_STAGE="${GITHUB_LAST_STAGE:-}"
GITHUB_LAST_ERROR="${GITHUB_LAST_ERROR:-}"
GITHUB_LAST_AUTH_RELEVANT="${GITHUB_LAST_AUTH_RELEVANT:-false}"

_github_clear_error() {
    GITHUB_LAST_STAGE=""
    GITHUB_LAST_ERROR=""
    GITHUB_LAST_AUTH_RELEVANT=false
}

_github_safe_error() {
    local message="${1:-}"
    message=$(printf '%s' "$message" |
        LC_ALL=C tr -cd '\11\12\15\40-\176\200-\377' |
        tr '\r\n' '  ' |
        sed -E \
            -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[скрыто]@#g' \
            -e 's/(github_pat_|gh[pousr]_)[A-Za-z0-9_]+/[скрыто]/g' \
            -e 's/([Aa]uthorization:[[:space:]]*(Bearer|token)[[:space:]]+)[^[:space:]]+/\1[скрыто]/g' \
            -e 's/([Tt]oken|[Pp]assword|[Pp]asswd|[Ss]ecret)([=:][[:space:]]*)[^[:space:]]+/\1\2[скрыто]/g')
    message="${message:0:500}"
    printf '%s\n' "${message:-операция завершилась с ошибкой без дополнительного сообщения}"
}

_github_record_error() {
    GITHUB_LAST_STAGE="$1"
    GITHUB_LAST_ERROR=$(_github_safe_error "${2:-}")
    GITHUB_LAST_AUTH_RELEVANT="${3:-false}"
}

_github_auth_failure_confirmed() {
    local gh="${GH_BIN:-gh}" output
    command -v "$gh" >/dev/null 2>&1 || return 1
    if output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" auth status \
        --hostname github.com 2>&1); then
        return 1
    fi
    printf '%s' "$output" |
        grep -Eiq '(not logged|not authenticated|authentication|log in|login|token.*(invalid|expired))'
}
_github_should_show_auth_hint() {
    [[ ${GITHUB_LAST_AUTH_RELEVANT:-false} == true ]] || return 1
    _github_auth_failure_confirmed
}


_github_die() { warn "$*" 2>/dev/null || printf '%s\n' "$*" >&2; return 1; }
_github_require() { command -v "$1" >/dev/null 2>&1 || { _github_die "Не найдено: $1"; return 1; }; }
_github_mkdir_secure() { umask 077; local dir; for dir in "$@"; do mkdir -p "$dir"; chmod 700 "$dir"; done; }
_github_ensure_deps() {
    local mode="${1:-}" remote="${2:-${GITHUB_REMOTE:-}}"
    if declare -F ensure_dep >/dev/null 2>&1; then
        ensure_dep git gh || return 1
        if [[ "$mode" == age ]]; then ensure_dep age || return 1; fi
    else
        _github_require git || return 1
        if [[ "$remote" != /* && "$remote" != *.git && "$remote" != file://* ]]; then
            _github_require gh || return 1
        fi
        [[ "$mode" != age ]] || _github_require "$AGE_BIN"
    fi
}

_github_run_with_timeout() {
    run_with_timeout "$@"
}

_github_validate_tree() {
    local root="$1" mode="$2" path rel name
    while IFS= read -r path; do
        [[ "$path" == "$root/.git" || "$path" == "$root/.git/"* ]] && continue
        rel="${path#"$root"/}"
        case "$mode:$rel" in
            age:storage.json|age:recipient.txt|age:unlock.age|age:state.json.age)
                ;;
            none:storage.json|none:config.json|none:secrets.json|none:manifest.json|none:ssh/known_hosts)
                ;;
            none:templates/*.yaml)
                name="${rel#templates/}"
                [[ "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || return 1
                ;;
            none:ssh/identities/*|none:ssh/identities/*.pub)
                name="${rel#ssh/identities/}"
                [[ "$name" =~ ^[0-9a-fA-F]{32}(\.pub)?$ ]] || return 1
                ;;
            *)
                return 1
                ;;
        esac
    done < <(find "$root" -type f -print 2>/dev/null)
}

_github_prompt_storage_mode() {
    local answer
    while :; do
        echo -e "  ${GREEN}1)${NC} Зашифровать паролем"
        echo -e "  ${CYAN}2)${NC} Хранить без шифрования"
        read -rp "  Выберите 1 или 2: " answer
        case "$answer" in 1) GITHUB_STORAGE_MODE=age; return 0;; 2) GITHUB_STORAGE_MODE=none; return 0;; esac
    done
}
_github_prompt_remember_unlock() {
    local answer
    while :; do
        printf 'Сохранить ключ расшифровки на этом устройстве? (y/n): '
        IFS= read -r answer || return 1
        case "$answer" in y|Y) return 0;; n|N) return 1;; esac
    done
}

_github_storage_init() {
    local mode=${1:-${GITHUB_STORAGE_MODE:-}}
    [[ $mode == age || $mode == none ]] || return 1
    GITHUB_STORAGE_MODE=$mode
    printf '{"storage_version":1,"encryption":"%s"}\n' "$mode" > "$GITHUB_WORKTREE/storage.json"
    chmod 644 "$GITHUB_WORKTREE/storage.json"
}
_github_storage_read() {
    [[ -s "$GITHUB_WORKTREE/storage.json" ]] || return 1
    GITHUB_STORAGE_MODE=$(jq -er '
        select(type=="object" and .storage_version == 1 and
            (.encryption == "age" or .encryption == "none")) | .encryption
    ' "$GITHUB_WORKTREE/storage.json" 2>/dev/null) || return 1
}
github_config_prompt_master() {
    local first second
    read -rsp "Введите пароль доступа к зашифрованной конфигурации: " first; printf '\n'
    [[ -n "$first" ]] || return 1
    read -rsp "Повторите пароль доступа: " second; printf '\n'
    [[ "$first" == "$second" ]] || return 1
    GITHUB_MASTER_PASSWORD="$first"
}
github_config_age_init() {
    _github_require "$AGE_BIN" || return 1
    github_config_prompt_master || return 1
    if ! _github_mkdir_secure "$GITHUB_CREDENTIALS_DIR"; then
        unset GITHUB_MASTER_PASSWORD
        return 1
    fi
    local identity="$CONFIG_DIR/github-identity.tmp" recipient
    rm -f "$identity"
    umask 077
    if command -v "$AGE_KEYGEN_BIN" >/dev/null 2>&1; then
        "$AGE_KEYGEN_BIN" > "$identity" 2>/dev/null || {
            rm -f "$identity"
            unset GITHUB_MASTER_PASSWORD
            return 1
        }
    elif ! "$AGE_BIN" -gen-key > "$identity" 2>/dev/null &&
         ! "$AGE_BIN" -keygen > "$identity" 2>/dev/null; then
        rm -f "$identity"
        unset GITHUB_MASTER_PASSWORD
        return 1
    fi
    recipient=$(sed -n 's/^# public key: *//p' "$identity" | tr -d '\r\n')
    [[ -n "$recipient" ]] || {
        rm -f "$identity"
        unset GITHUB_MASTER_PASSWORD
        return 1
    }
    GITHUB_RECIPIENT="$recipient"; export GITHUB_RECIPIENT GITHUB_IDENTITY="$identity"
    if ! printf '%s\n' "$recipient" > "$GITHUB_WORKTREE/recipient.txt" ||
       ! chmod 644 "$GITHUB_WORKTREE/recipient.txt"; then
        rm -f "$identity" "$GITHUB_WORKTREE/recipient.txt"
        unset GITHUB_MASTER_PASSWORD
        return 1
    fi
    if ! printf '%s\n%s\n' "$GITHUB_MASTER_PASSWORD" "$GITHUB_MASTER_PASSWORD" |
        "$AGE_BIN" -p -o "$GITHUB_WORKTREE/unlock.age" "$identity"; then
        rm -f "$identity" "$GITHUB_WORKTREE/unlock.age" "$GITHUB_WORKTREE/recipient.txt"
        unset GITHUB_MASTER_PASSWORD
        return 1
    fi
    unset GITHUB_MASTER_PASSWORD
    chmod 600 "$GITHUB_WORKTREE/unlock.age" "$identity"
}
github_config_unlock() {
    local attempts=3 pass id="${GITHUB_UNLOCK_FILE:-}" check
    if [[ -s "${GITHUB_IDENTITY:-}" ]]; then
        local imported="$GITHUB_IDENTITY"
        "$AGE_KEYGEN_BIN" -y "$imported" >/dev/null 2>&1 || {
            rm -f "$imported"; unset GITHUB_IDENTITY
        }
        if [[ -s "${GITHUB_IDENTITY:-}" ]]; then
            check=$(umask 077; mktemp "$CONFIG_DIR/.unlock-check.XXXXXX") || return 1
            if "$AGE_BIN" -d -i "$GITHUB_IDENTITY" -o "$check" "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1; then
                rm -f "$check"
                if _github_prompt_remember_unlock; then github_config_remember "$GITHUB_IDENTITY"; fi
                return 0
            fi
            rm -f "$check" "$imported"; unset GITHUB_IDENTITY
        fi
    fi
    if [[ -s "$id" ]]; then
        check=$(umask 077; mktemp "$CONFIG_DIR/.unlock-check.XXXXXX") || return 1
        if "$AGE_BIN" -d -i "$id" -o "$check" "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1; then
            rm -f "$check"; GITHUB_IDENTITY="$id"; export GITHUB_IDENTITY; return 0
        fi
        rm -f "$check" "$id"; warn "Сохранённый ключ расшифровки недействителен и будет удалён."
    fi
    while (( attempts > 0 )); do
        read -rsp "Введите пароль доступа к конфигурации (осталось попыток: $attempts): " pass; printf '\n'
        check=$(umask 077; mktemp "$CONFIG_DIR/.unlock-check.XXXXXX") || return 1
        if [[ -n "$pass" ]] && printf '%s\n' "$pass" | "$AGE_BIN" -d -p -o "$check" "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1; then
            GITHUB_IDENTITY="$check"; export GITHUB_IDENTITY
            if _github_prompt_remember_unlock; then github_config_remember "$GITHUB_IDENTITY"; fi
            return 0
        fi
        rm -f "$check"; attempts=$((attempts - 1))
    done
    return 1
}

_github_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
# Build logical state from the active runtime. state.sh may provide a richer
# serializer; this fallback intentionally only reads files and never evals them.
github_config_serialize() {
    local out=${1:?output path} cfg=${2:-${CONFIG_JSON:?CONFIG_JSON is unset}}
    local secrets=${SECRETS_JSON:-${CONFIG_DIR:-.}/secrets.json} manifest=${STATE_MANIFEST:-${CONFIG_DIR:-.}/manifest.json}
    local known=${SSH_KNOWN_HOSTS:-${CONFIG_DIR:-.}/ssh/known_hosts} known_data="" tmp name content pub
    [[ -f "$known" ]] && known_data=$(cat "$known")
    [[ -f "$secrets" && -f "$manifest" ]] || return 1
    jq -n --argjson config "$(cat "$cfg")" --slurpfile sec "$secrets" \
      --slurpfile man "$manifest" --arg known "$known_data" --arg minimum "${CURRENT_VERSION:-0.0.0}" \
      '{vault_version:1,minimum_remote_control_version:$minimum,portability:($man[0].portability // {status:"ready",issues:[]}),access:($man[0].access // {script_password_hash:null}),config:$config,secrets:($sec[0] // {node_passwords:{}}),templates:($man[0].templates // {}),ssh:{identities:{},known_hosts:$known}}' > "$out" || return 1
    tmp="${out}.tmp.$$"
    local used template source builtin_hash snapshot_hash
    local used_templates="default.yaml "
    while IFS= read -r template; do
        [[ -n "$template" ]] && used_templates+="$template "
    done < <(jq -r '(.groups // [])[]? | (.template // "default.yaml")' "$cfg" 2>/dev/null)
    for template in $used_templates; do
        name="$TEMPLATES_DIR/$template"
        source=custom
        if [[ ! -f "$name" && -f "$BUILTIN_TEMPLATES_DIR/$template" ]]; then
            name="$BUILTIN_TEMPLATES_DIR/$template"
            source=builtin
        fi
        [[ -f "$name" ]] || { [[ ${CONFIG_SOURCE:-local} == github ]] && return 1; continue; }
        if [[ "$source" == custom && -f "$BUILTIN_TEMPLATES_DIR/$template" ]] && cmp -s "$name" "$BUILTIN_TEMPLATES_DIR/$template"; then source=builtin; fi
        snapshot_hash=$(_github_sha256 "$name")
        builtin_hash=null
        if [[ "$source" == custom && -f "$BUILTIN_TEMPLATES_DIR/$template" ]]; then
            builtin_hash=$(_github_sha256 "$BUILTIN_TEMPLATES_DIR/$template")
        fi
        jq --arg n "$template" --rawfile c "$name" --arg source "$source" \
            --arg hash "$snapshot_hash" --arg builtin "$builtin_hash" \
            '.templates += {($n): {content:$c,source:$source,snapshot_sha256:$hash,ignored_builtin_sha256:(if $builtin=="null" then null else $builtin end)}}' \
            "$out" > "$tmp" && mv "$tmp" "$out" || return 1
    done
    for name in "$SSH_IDENTITIES_DIR"/*; do
        [[ -f "$name" && "$name" != *.pub ]] || continue
        pub="${name}.pub"
        if [[ -f "$pub" ]]; then
            jq --arg n "$(basename "$name")" --rawfile p "$name" --rawfile q "$pub" '.ssh.identities += {($n): {private:$p,public:$q}}' "$out" > "$tmp" && mv "$tmp" "$out"
        else
            jq --arg n "$(basename "$name")" --rawfile p "$name" '.ssh.identities += {($n): {private:$p,public:null}}' "$out" > "$tmp" && mv "$tmp" "$out"
        fi
    done
    chmod 600 "$out"
}
github_config_validate() {
    local state=${1:?state json}
    jq -e 'type=="object" and .vault_version==1 and (.config|type=="object") and (.secrets|type=="object") and (.templates|type=="object") and (.ssh|type=="object") and ((.portability.status=="ready") or (.portability.status=="needs_setup")) and (.portability.issues|type=="array")' "$state" >/dev/null 2>&1 || return 1
    jq -e '((.config.nodes // []) | map(.id) | length == (map(.) | unique | length)) and ((.config.nodes // []) | map(.name) | length == (map(.) | unique | length)) and all((.config.nodes // [])[]; (.id|type=="string") and (.name|type=="string"))' "$state" >/dev/null 2>&1 || return 1
    jq -e '
        all((.templates // {}) | to_entries[];
            (.key | test("^[A-Za-z0-9._-]+[.]yaml$")) and
            (.value | type=="object") and (.value.content | type=="string")) and
        ((.ssh.known_hosts // "") | type=="string") and
        all((.ssh.identities // {}) | to_entries[];
            (.key | test("^[0-9a-fA-F]{32}$")) and
            (.value | type=="object") and
            (.value.private | type=="string" and length>0) and
            (.value.public | type=="string" and length>0))
    ' "$state" >/dev/null 2>&1
}

_github_plain_write() {
    local state=$1 w=$GITHUB_WORKTREE name stage backup path
    local -a paths=(config.json secrets.json manifest.json ssh templates)
    github_config_validate "$state" || return 1
    stage=$(umask 077; mktemp -d "$w/.plain-write.XXXXXX") || return 1
    mkdir -p "$stage/templates" "$stage/ssh/identities" || {
        rm -rf "$stage"
        return 1
    }
    if ! jq -e '.config' "$state" > "$stage/config.json" ||
       ! jq -e '.secrets' "$state" > "$stage/secrets.json" ||
       ! jq -e '{vault_version,minimum_remote_control_version,portability,access,templates}' \
            "$state" > "$stage/manifest.json" ||
       ! jq -j '.ssh.known_hosts // ""' "$state" > "$stage/ssh/known_hosts"; then
        rm -rf "$stage"
        return 1
    fi
    while IFS= read -r name; do
        jq -j --arg n "$name" '.templates[$n].content' "$state" \
            > "$stage/templates/$name" || {
            rm -rf "$stage"
            return 1
        }
    done < <(jq -r '.templates // {} | keys[]' "$state")
    while IFS= read -r name; do
        if ! jq -j --arg n "$name" '.ssh.identities[$n].private' "$state" \
                > "$stage/ssh/identities/$name" ||
           ! jq -j --arg n "$name" '.ssh.identities[$n].public' "$state" \
                > "$stage/ssh/identities/$name.pub"; then
            rm -rf "$stage"
            return 1
        fi
    done < <(jq -r '.ssh.identities // {} | keys[]' "$state")
    chmod 700 "$stage" "$stage/templates" "$stage/ssh" "$stage/ssh/identities" &&
        chmod 600 "$stage/secrets.json" "$stage/ssh/known_hosts" || {
        rm -rf "$stage"
        return 1
    }
    chmod 600 "$stage/ssh/identities/"* 2>/dev/null || true
    chmod 644 "$stage/config.json" "$stage/manifest.json" "$stage/templates/"* \
        "$stage/ssh/identities/"*.pub 2>/dev/null || true

    backup=$(umask 077; mktemp -d "$w/.plain-backup.XXXXXX") || {
        rm -rf "$stage"
        return 1
    }
    for path in "${paths[@]}"; do
        if [[ -e "$w/$path" ]] && ! mv "$w/$path" "$backup/$path"; then
            for path in "${paths[@]}"; do
                [[ -e "$backup/$path" ]] && mv "$backup/$path" "$w/$path" 2>/dev/null || true
            done
            rm -rf "$stage" "$backup"
            return 1
        fi
    done
    for path in "${paths[@]}"; do
        if ! mv "$stage/$path" "$w/$path"; then
            local restore
            for restore in "${paths[@]}"; do rm -rf "$w/$restore"; done
            for restore in "${paths[@]}"; do
                [[ -e "$backup/$restore" ]] &&
                    mv "$backup/$restore" "$w/$restore" 2>/dev/null || true
            done
            rm -rf "$stage" "$backup"
            return 1
        fi
    done
    rmdir "$stage" 2>/dev/null || rm -rf "$stage"
    rm -rf "$backup"
    chmod 700 "$w"
}
_github_plain_read() {
    local w=$GITHUB_WORKTREE out=$1 name content pub
    [[ -f "$w/config.json" && -f "$w/secrets.json" && -f "$w/manifest.json" ]] || return 1
    local -a known_args
    if [[ -f "$w/ssh/known_hosts" ]]; then
        known_args=(--rawfile known "$w/ssh/known_hosts")
    else
        known_args=(--arg known "")
    fi
    jq -n --argjson config "$(cat "$w/config.json")" \
      --argjson secrets "$(cat "$w/secrets.json")" --slurpfile man "$w/manifest.json" \
      "${known_args[@]}" \
      '{vault_version:1,minimum_remote_control_version:($man[0].minimum_remote_control_version // "0.0.0"),portability:($man[0].portability // {status:"ready",issues:[]}),access:($man[0].access // {script_password_hash:null}),config:$config,secrets:$secrets,templates:($man[0].templates // {}),ssh:{identities:{},known_hosts:$known}}' > "$out" || return 1
    local tmp="${out}.tmp.$$"
    for name in "$w/templates/"*.yaml; do
        [[ -f "$name" ]] || continue
        jq --arg n "$(basename "$name")" -j --rawfile c "$name" \
            '.templates[$n].content=$c' "$out" > "$tmp" || {
            rm -f "$tmp"; return 1;
        }
        mv -f "$tmp" "$out" || return 1
    done
    for name in "$w/ssh/identities/"*.pub; do
        [[ -f "$name" ]] || continue
        [[ -f "${name%.pub}" ]] || return 1
    done
    for name in "$w/ssh/identities/"*; do
        [[ -f "$name" && "$name" != *.pub ]] || continue
        content="${name##*/}"
        [[ "$content" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
        jq --arg n "$content" -j --rawfile p "$name" --rawfile q "$name.pub" \
            '.ssh.identities[$n]={private:$p,public:$q}' "$out" > "$tmp" || {
            rm -f "$tmp"; return 1;
        }
        mv -f "$tmp" "$out" || return 1
    done
    rm -f "$tmp"
    github_config_validate "$out"
}
github_config_checkpoint() {
    local state=${1:-${CONFIG_DIR:-.}/runtime-state.json}
    local generated_state=false
    if [[ ! -f "$state" ]]; then
        state=$(umask 077; mktemp "$CONFIG_DIR/.runtime-state.XXXXXX") || return 1
        generated_state=true
        github_config_serialize "$state" "${CONFIG_JSON:?}" || {
            rm -f "$state"
            return 1
        }
    fi
    [[ -f "$GITHUB_WORKTREE/storage.json" ]] ||
        _github_storage_init "${GITHUB_STORAGE_MODE:-none}" || {
            [[ "$generated_state" == true ]] && rm -f "$state"
            return 1
        }
    if [[ ${GITHUB_STORAGE_MODE:-none} == none ]]; then
        _github_plain_write "$state"
    else
        [[ -n ${GITHUB_RECIPIENT:-} ]] || {
            [[ "$generated_state" == true ]] && rm -f "$state"
            return 1
        }
        "$AGE_BIN" -r "$GITHUB_RECIPIENT" -o "$GITHUB_WORKTREE/state.json.age" "$state" || {
            [[ "$generated_state" == true ]] && rm -f "$state"
            return 1
        }
        chmod 600 "$GITHUB_WORKTREE/state.json.age"
    fi
    local rc=$?
    [[ "$generated_state" == true ]] && rm -f "$state"
    return "$rc"
}
config_persist_candidate() {
    [[ ${CONFIG_SOURCE:-local} == github ]] || return 0
    local candidate="${1:-}" original="${CONFIG_JSON:-}" serialized
    [[ -f "$candidate" && -n "$original" ]] || return 1
    serialized=$(umask 077; mktemp "$CONFIG_DIR/.candidate-state.XXXXXX") || return 1
    CONFIG_JSON="$candidate"
    if ! state_validate true >/dev/null 2>&1; then
        if [[ "${CONFIG_PERSIST_ALLOW_NEEDS_SETUP:-0}" != "1" ]] ||
           ! state_validate false >/dev/null 2>&1; then
            CONFIG_JSON="$original"
            rm -f "$serialized"
            return 1
        fi
    fi
    if ! github_config_serialize "$serialized" "$candidate" ||
       ! github_config_checkpoint "$serialized"; then
        CONFIG_JSON="$original"
        rm -f "$serialized"
        return 1
    fi
    CONFIG_JSON="$original"
    rm -f "$serialized"
    return 0
}
github_config_remember() {
    local id="${1:-}"
    [[ -s "$id" ]] || return 1
    _github_mkdir_secure "$GITHUB_CREDENTIALS_DIR" || return 1
    cp "$id" "$GITHUB_UNLOCK_FILE" || return 1
    chmod 600 "$GITHUB_UNLOCK_FILE"
}
github_config_forget() { rm -f "$GITHUB_UNLOCK_FILE"; }
github_config_export_recovery() {
    local target="${1:-}"
    [[ -n "$target" && "$target" != "$GITHUB_WORKTREE"/* && "$target" != "$CONFIG_DIR"/* ]] || return 1
    [[ -s "${GITHUB_IDENTITY:-}" ]] || return 1
    cp "$GITHUB_IDENTITY" "$target" || return 1
    chmod 600 "$target"
}
github_config_import_recovery() {
    local source="${1:-}" check
    [[ -s "$source" && "$source" != "$GITHUB_WORKTREE"/* && "$source" != "$CONFIG_DIR"/* ]] || return 1
    check=$(umask 077; mktemp "$CONFIG_DIR/.recovery-key.XXXXXX") || return 1
    cp "$source" "$check" && chmod 600 "$check" || { rm -f "$check"; return 1; }
    "$AGE_KEYGEN_BIN" -y "$check" >/dev/null 2>&1 || { rm -f "$check"; return 1; }
    GITHUB_IDENTITY="$check"; export GITHUB_IDENTITY
    return 0
}
github_config_rewrap_master() {
    [[ ${GITHUB_STORAGE_MODE:-none} == age && -s "$GITHUB_WORKTREE/unlock.age" ]] || return 1
    local old new tmp
    info "Изменится только пароль доступа; ключ шифрования и текущие данные останутся прежними."
    warn "Старые версии в истории GitHub могут по-прежнему открываться прежним паролем."
    read -rsp "Текущий пароль доступа: " old; printf '\n'
    read -rsp "Новый пароль доступа: " new; printf '\n'
    [[ -n "$new" ]] || return 1
    read -rsp "Повторите новый пароль доступа: " _new; printf '\n'
    [[ "$new" == "$_new" ]] || return 1
    tmp=$(umask 077; mktemp "$CONFIG_DIR/.rewrap.XXXXXX") || return 1
    if ! printf '%s\n' "$old" | "$AGE_BIN" -d -p -o "$tmp" "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
    if ! printf '%s\n%s\n' "$new" "$new" | "$AGE_BIN" -p -o "$GITHUB_WORKTREE/unlock.age" "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    github_sync_flush
}
github_config_rotate_vault_key() {
    [[ ${GITHUB_STORAGE_MODE:-none} == age ]] || return 1
    warn "Будет создан новый ключ, и текущая конфигурация будет зашифрована заново. Пароли нод не изменятся."
    warn "Старые версии в истории GitHub останутся доступны по прежнему ключу."
    confirm_yn "Создать новый ключ шифрования?" N || return 1
    github_config_age_init || return 1
    github_config_checkpoint || return 1
    github_sync_flush
}
github_config_switch_local() {
    [[ ${CONFIG_SOURCE:-local} == github && -f ${CONFIG_JSON:-} ]] || return 1
    state_validate true >/dev/null 2>&1 || return 1
    local staging backup stamp
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    staging="$CONFIG_DIR/.local-switch.$$.tmp"
    backup="$CONFIG_DIR/import-backups/$stamp"
    rm -rf "$staging"; mkdir -p "$staging/templates" "$staging/ssh/identities" "$backup"
    cp "$CONFIG_JSON" "$staging/config.json" && cp "$SECRETS_JSON" "$staging/secrets.json" &&
        cp "$STATE_MANIFEST" "$staging/manifest.json" || return 1
    cp -R "$TEMPLATES_DIR/." "$staging/templates/" 2>/dev/null || true
    cp -R "$SSH_IDENTITIES_DIR/." "$staging/ssh/identities/" 2>/dev/null || true
    cp "$SSH_KNOWN_HOSTS" "$staging/ssh/known_hosts" 2>/dev/null || :
    for path in config.json secrets.json manifest.json; do
        [[ -e "$CONFIG_DIR/$path" ]] && mv "$CONFIG_DIR/$path" "$backup/$path"
    done
    [[ -d "$CONFIG_DIR/templates" ]] && mv "$CONFIG_DIR/templates" "$backup/templates"
    [[ -d "$CONFIG_DIR/ssh" ]] && mv "$CONFIG_DIR/ssh" "$backup/ssh"
    mv "$staging/config.json" "$CONFIG_DIR/config.json" && mv "$staging/secrets.json" "$CONFIG_DIR/secrets.json" &&
        mv "$staging/manifest.json" "$CONFIG_DIR/manifest.json" && mv "$staging/templates" "$CONFIG_DIR/templates" &&
        mv "$staging/ssh" "$CONFIG_DIR/ssh" || return 1
    rm -f "$CONFIG_DIR/source.json" || return 1
    rmdir "$staging" 2>/dev/null || rm -rf "$staging"
    github_config_close >/dev/null 2>&1 || true
    CONFIG_SOURCE=local; STATE_DIR="$CONFIG_DIR"; CONFIG_JSON="$CONFIG_DIR/config.json"
    SECRETS_JSON="$CONFIG_DIR/secrets.json"; STATE_MANIFEST="$CONFIG_DIR/manifest.json"
    TEMPLATES_DIR="$CONFIG_DIR/templates"; SSH_IDENTITIES_DIR="$CONFIG_DIR/ssh/identities"
    SSH_KNOWN_HOSTS="$CONFIG_DIR/ssh/known_hosts"; SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    GITHUB_WORKTREE=""; GITHUB_IDENTITY=""; GITHUB_RECIPIENT=""
    GITHUB_REMOTE=""; GITHUB_OWNER=""
    _github_clear_error
    export CONFIG_SOURCE STATE_DIR CONFIG_JSON SECRETS_JSON STATE_MANIFEST TEMPLATES_DIR SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE
    export GITHUB_WORKTREE GITHUB_IDENTITY GITHUB_RECIPIENT GITHUB_REMOTE GITHUB_OWNER
}
github_config_open() {
    local root="${1:?worktree}" out="${2:-${CONFIG_DIR:-.}/runtime-state.json}"
    GITHUB_WORKTREE="$root"
    _github_storage_read || return 1
    _github_validate_tracked_tree || return 1
    if [[ $GITHUB_STORAGE_MODE == none ]]; then
        _github_plain_read "$out" || return 1
    else
        [[ -s "$root/recipient.txt" && -s "$root/state.json.age" ]] || return 1
        GITHUB_RECIPIENT=$(tr -d '\r\n' < "$root/recipient.txt")
        github_config_unlock || return 1
        local id="${GITHUB_IDENTITY:-}"
        [[ -s "$id" ]] || return 1
        "$AGE_BIN" -d -i "$id" -o "$out" "$root/state.json.age" || return 1
        github_config_validate "$out" || { rm -f "$out"; return 1; }
    fi
    chmod 600 "$out"; return 0
}

_github_repo() { printf '%s/%s' "${GITHUB_OWNER:?}" "$GITHUB_REPO_NAME"; }
github_source_metadata_valid() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    jq -e 'type=="object" and .type=="github" and .private_verified == true and
        (.repo | strings | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
        (.branch | strings | length > 0)' "$file" >/dev/null 2>&1
}
github_source_metadata_write() {
    local tmp repo
    if [[ -z "${GITHUB_OWNER:-}" || -z "${GITHUB_REPO_NAME:-}" ||
          -z "${GITHUB_BRANCH:-}" ]] || ! mkdir -p "$CONFIG_DIR"; then
        _github_record_error "сохранение настроек источника" \
            "Не удалось сохранить параметры репозитория GitHub."
        return 1
    fi
    repo="$GITHUB_OWNER/$GITHUB_REPO_NAME"
    tmp=$(umask 077; mktemp "$CONFIG_DIR/.source.XXXXXX") || {
        _github_record_error "сохранение настроек источника" \
            "Не удалось сохранить параметры репозитория GitHub."
        return 1
    }
    if ! jq -n --arg repo "$repo" --arg branch "$GITHUB_BRANCH" \
        '{type:"github",repo:$repo,branch:$branch,private_verified:true}' > "$tmp" ||
       ! github_source_metadata_valid "$tmp" ||
       ! chmod 600 "$tmp" ||
       ! mv "$tmp" "$CONFIG_DIR/source.json"; then
        rm -f "$tmp"
        _github_record_error "сохранение настроек источника" \
            "Не удалось сохранить параметры репозитория GitHub."
        return 1
    fi
}


legacy_local_source_metadata_valid() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    jq -e 'type=="object" and keys==["type"] and .type=="local"' \
        "$file" >/dev/null 2>&1
}


github_sync_init() {
    local announce_account="${1:-false}"
    # github_enable_local may initialize the transport before calling
    # config_source_startup. Reuse that live worktree instead of attempting
    # to create the same session branch a second time.
    _github_clear_error
    if [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] &&
       git -C "$GITHUB_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi
    if ! _github_ensure_deps "" "$GITHUB_REMOTE"; then
        _github_record_error "проверка зависимостей" "Не удалось подготовить git и GitHub CLI."
        return 1
    fi
    if ! _github_require git; then
        _github_record_error "проверка зависимостей" "Не найдена команда git."
        return 1
    fi

    local repo remote_view login setup_output create_output
    local git_output fetch_output fetch_ok=true local_oid="" remote_oid=""
    local current_origin="" remote_changed=false
    local gh="${GH_BIN:-gh}"
    if [[ "$GITHUB_REMOTE" != /* && "$GITHUB_REMOTE" != *.git && "$GITHUB_REMOTE" != file://* ]]; then
        if ! _github_ensure_deps; then
            _github_record_error "проверка зависимостей" "Не удалось подготовить GitHub CLI."
            return 1
        fi
        if ! _github_require "$gh"; then
            _github_record_error "проверка зависимостей" "Не найдена команда GitHub CLI: $gh."
            return 1
        fi
        if ! setup_output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" auth setup-git 2>&1); then
            _github_record_error "настройка Git для GitHub CLI" "$setup_output" true
            return 1
        fi
        if ! login=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" api user --jq .login 2>&1); then
            _github_record_error "определение пользователя GitHub" "$login" true
            return 1
        fi
        [[ -n "$GITHUB_OWNER" ]] || GITHUB_OWNER="$login"
        if [[ "$login" != "$GITHUB_OWNER" ]]; then
            _github_record_error "проверка пользователя GitHub" \
                "GitHub CLI подключён как $login, ожидался пользователь $GITHUB_OWNER."
            return 1
        fi
        if [[ "$announce_account" == true ]]; then
            info "GitHub-аккаунт для репозитория конфигурации: $login"
        fi
        repo="$GITHUB_OWNER/$GITHUB_REPO_NAME"
        if ! remote_view=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo view "$repo" --json visibility 2>&1); then
            if [[ "$remote_view" != *"not found"* &&
                  "$remote_view" != *"Could not resolve to a Repository"* ]]; then
                _github_record_error "проверка приватного репозитория" "$remote_view" true
                return 1
            fi
            if ! create_output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo create "$repo" \
                --private --description "Essence Remote Control configuration" 2>&1); then
                _github_record_error "создание приватного репозитория" "$create_output" true
                return 1
            fi
            remote_view='{"visibility":"PRIVATE"}'
        fi
        if [[ "$remote_view" != *PRIVATE* ]]; then
            _github_record_error "проверка приватного репозитория" \
                "Репозиторий $repo должен быть приватным."
            return 1
        fi
        GITHUB_REMOTE="https://github.com/$repo.git"
    fi

    if ! _github_mkdir_secure "$GITHUB_STORE" "$GITHUB_SESSIONS_DIR"; then
        _github_record_error "подготовка локального хранилища" \
            "Не удалось создать служебные каталоги GitHub."
        return 1
    fi
    GITHUB_SESSION_ID=${GITHUB_SESSION_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}
    local dir="$GITHUB_SESSIONS_DIR/$GITHUB_SESSION_ID" remote_ref remote_refs
    if ! mkdir -p "$dir"; then
        _github_record_error "подготовка локального хранилища" \
            "Не удалось создать каталог рабочей сессии."
        return 1
    fi
    if [[ ! -d "$GITHUB_STORE/objects" ]]; then
        if ! git_output=$(git init --bare "$GITHUB_STORE" 2>&1); then
            _github_record_error "подготовка локального репозитория" "$git_output"
            return 1
        fi
    fi
    if current_origin=$(git --git-dir="$GITHUB_STORE" remote get-url origin 2>/dev/null); then
        if [[ "$current_origin" != "$GITHUB_REMOTE" ]]; then
            if ! git_output=$(git --git-dir="$GITHUB_STORE" remote set-url \
                origin "$GITHUB_REMOTE" 2>&1); then
                _github_record_error "настройка адреса репозитория" "$git_output"
                return 1
            fi
            remote_changed=true
        fi
    elif ! git_output=$(git --git-dir="$GITHUB_STORE" remote add \
        origin "$GITHUB_REMOTE" 2>&1); then
        _github_record_error "настройка адреса репозитория" "$git_output"
        return 1
    fi
    local local_ref="refs/heads/$GITHUB_BRANCH"
    remote_ref="refs/remotes/origin/$GITHUB_BRANCH"
    fetch_output=$(GIT_TERMINAL_PROMPT=0 _github_run_with_timeout 30 \
        git --git-dir="$GITHUB_STORE" fetch --no-tags origin "$GITHUB_BRANCH" 2>&1) || fetch_ok=false
    if [[ "$fetch_ok" == true ]] &&
       git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
        remote_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref") || return 1
        if ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
            if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref \
                "$local_ref" "$remote_ref" 2>&1); then
                _github_record_error "обновление локальной копии репозитория" "$git_output"
                return 1
            fi
            GITHUB_SYNC_STATUS=clean
            local_oid="$remote_oid"
        else
            local_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref") || return 1
        fi
        if [[ -n "$local_oid" && "$local_oid" == "$remote_oid" ]]; then
            GITHUB_SYNC_STATUS=clean
        elif git --git-dir="$GITHUB_STORE" merge-base --is-ancestor "$remote_ref" "$local_ref"; then
            # A previous process committed locally while push was unavailable.
            # Keep that commit as the restart-safe source until it is pushed.
            GITHUB_SYNC_STATUS=pending
        elif git --git-dir="$GITHUB_STORE" merge-base --is-ancestor "$local_ref" "$remote_ref"; then
            if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref \
                "$local_ref" "$remote_ref" 2>&1); then
                _github_record_error "обновление локальной копии репозитория" "$git_output"
                return 1
            fi
            GITHUB_SYNC_STATUS=clean
        else
            _github_record_error "сверка локальных и удалённых изменений" \
                "Локальная конфигурация и GitHub изменились независимо. Автоматическое объединение остановлено, чтобы не потерять данные."
            return 1
        fi
    elif [[ "$fetch_ok" != true ]]; then
        if [[ "$remote_changed" == true ]]; then
            if remote_refs=$(_github_run_with_timeout 15 git ls-remote \
                "$GITHUB_REMOTE" "refs/heads/$GITHUB_BRANCH" 2>/dev/null) &&
               [[ -z "$remote_refs" ]]; then
                local previous_oid="" archive_ref
                if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
                    previous_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref")
                elif git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
                    previous_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref")
                fi
                if [[ -n "$previous_oid" ]]; then
                    archive_ref="refs/archive/remote-switch-$(date -u +%Y%m%dT%H%M%SZ)-$$"
                    if ! git --git-dir="$GITHUB_STORE" update-ref \
                        "$archive_ref" "$previous_oid"; then
                        _github_record_error "сохранение истории прежнего репозитория" \
                            "Не удалось сохранить прежнюю локальную ветку перед сменой репозитория."
                        return 1
                    fi
                fi
                git --git-dir="$GITHUB_STORE" update-ref -d "$local_ref" || return 1
                git --git-dir="$GITHUB_STORE" update-ref -d "$remote_ref" || return 1
                info "Репозиторий GitHub изменён: прежняя история сохранена локально, новый пустой репозиторий будет инициализирован отдельно."
            else
                if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
                    _github_record_error "загрузка нового репозитория GitHub" "$fetch_output" true
                else
                    _github_record_error "загрузка нового репозитория GitHub" "$fetch_output"
                fi
                return 1
            fi
        fi
        GITHUB_SYNC_STATUS=offline
        if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
            if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
                local_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref") || return 1
                remote_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref") || return 1
                if git --git-dir="$GITHUB_STORE" merge-base --is-ancestor "$remote_ref" "$local_ref" &&
                   [[ "$local_oid" != "$remote_oid" ]]; then
                    GITHUB_SYNC_STATUS=pending
                fi
            fi
        elif [[ "$GITHUB_REMOTE" == /* || "$GITHUB_REMOTE" == file://* ]] &&
             { [[ -d "$GITHUB_REMOTE" ]] ||
               [[ -z "$(_github_run_with_timeout 15 git ls-remote "$GITHUB_REMOTE" "refs/heads/$GITHUB_BRANCH" 2>/dev/null)" ]]; }; then
            :
        elif remote_refs=$(_github_run_with_timeout 15 git ls-remote "$GITHUB_REMOTE" 2>/dev/null) &&
             [[ -z "$remote_refs" ]]; then
            :
        else
            if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
                _github_record_error "загрузка репозитория GitHub" "$fetch_output" true
            else
                _github_record_error "загрузка репозитория GitHub" "$fetch_output"
            fi
            return 1
        fi
    fi
    if ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
        local tree commit
        if ! tree=$(printf '' | git --git-dir="$GITHUB_STORE" mktree 2>&1) ||
           ! commit=$(printf 'Initial empty state\n' |
                git -c user.name='Essence Remote Control' \
                    -c user.email='remote-control@localhost' \
                    --git-dir="$GITHUB_STORE" commit-tree "$tree" 2>&1) ||
           ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref \
                "$local_ref" "$commit" 2>&1); then
            _github_record_error "создание локальной ветки конфигурации" \
                "${git_output:-${commit:-${tree:-}}}"
            return 1
        fi
    fi
    GITHUB_WORKTREE=$dir/worktree
    if ! git_output=$(git --git-dir="$GITHUB_STORE" worktree add \
        -b "session/$GITHUB_SESSION_ID" "$GITHUB_WORKTREE" "$GITHUB_BRANCH" 2>&1); then
        _github_record_error "подготовка рабочей копии конфигурации" "$git_output"
        return 1
    fi
    if ! chmod 700 "$dir" "$GITHUB_WORKTREE"; then
        _github_record_error "защита рабочей копии конфигурации" \
            "Не удалось ограничить доступ к служебным файлам."
        return 1
    fi
    export GITHUB_WORKTREE GITHUB_SESSION_ID
}
github_sync_status() {
    printf '%s\n' "${GITHUB_SYNC_STATUS:-clean}"
}

_github_validate_tracked_tree() {
    local path rel tracked
    tracked=$(git -C "$GITHUB_WORKTREE" ls-files) || return 1
    [[ -z "$tracked" ]] && return 0
    while IFS= read -r path; do
        rel="$path"
        case "$rel" in
            storage.json) ;;
            recipient.txt|unlock.age|state.json.age)
                [[ ${GITHUB_STORAGE_MODE:-none} == age ]] || return 1 ;;
            config.json|secrets.json|manifest.json)
                [[ ${GITHUB_STORAGE_MODE:-none} == none ]] || return 1 ;;
            templates/*.yaml|ssh/known_hosts|ssh/identities/[0-9a-fA-F]*|ssh/identities/[0-9a-fA-F]*.pub)
                [[ ${GITHUB_STORAGE_MODE:-none} == none ]] || return 1 ;;
            *) warn "В хранилище конфигурации GitHub обнаружен недопустимый файл: $rel"; return 1 ;;
        esac
    done <<< "$tracked"
}
_github_stage_allowlist() {
    local -a paths=(storage.json) existing=()
    local path
    _github_validate_tracked_tree || return 1
    if [[ ${GITHUB_STORAGE_MODE:-none} == age ]]; then
        paths+=(recipient.txt unlock.age state.json.age)
    else
        paths+=(config.json secrets.json manifest.json ssh templates)
    fi
    for path in "${paths[@]}"; do
        [[ -e "$GITHUB_WORKTREE/$path" || -n "$(git -C "$GITHUB_WORKTREE" ls-files -- "$path" 2>/dev/null)" ]] && existing+=("$path")
    done
    git -C "$GITHUB_WORKTREE" add -A -- "${existing[@]}"
}

github_sync_flush() {
    [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] || return 1
    local had_files=false commit_output push_output head
    [[ -n "$(git -C "$GITHUB_WORKTREE" ls-files 2>/dev/null)" ]] && had_files=true
    _github_stage_allowlist || {
        GITHUB_SYNC_STATUS=pending
        return 1
    }
    if ! git -C "$GITHUB_WORKTREE" diff --cached --quiet; then
        if ! commit_output=$(git -C "$GITHUB_WORKTREE" \
            -c user.name='Essence Remote Control' \
            -c user.email='remote-control@localhost' commit -m \
            "remote-control: $([[ "$had_files" == false ]] && printf '%s' 'initialize state' || printf '%s' 'sync state')" \
            2>&1); then
            _github_record_error "сохранение локальных изменений Git" "$commit_output"
            GITHUB_SYNC_STATUS=pending
            return 1
        fi
    elif [[ "$GITHUB_SYNC_STATUS" != pending ]]; then
        GITHUB_SYNC_STATUS=clean
        return 0
    fi

    head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>/dev/null) || {
        GITHUB_SYNC_STATUS=pending
        return 1
    }
    # Preserve every committed mutation on the local main ref before network
    # I/O, so a new process can recover it even when push is unavailable.
    if ! git --git-dir="$GITHUB_STORE" update-ref "refs/heads/$GITHUB_BRANCH" "$head"; then
        _github_record_error "сохранение локальной точки восстановления" \
            "Не удалось закрепить локальный commit конфигурации."
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    if ! push_output=$(GIT_TERMINAL_PROMPT=0 _github_run_with_timeout 30 \
        git --git-dir="$GITHUB_STORE" push origin \
        "refs/heads/session/$GITHUB_SESSION_ID:refs/heads/$GITHUB_BRANCH" 2>&1); then
        if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
            _github_record_error "отправка конфигурации в GitHub" "$push_output" true
        else
            _github_record_error "отправка конфигурации в GitHub" "$push_output"
        fi
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    git --git-dir="$GITHUB_STORE" update-ref \
        "refs/remotes/origin/$GITHUB_BRANCH" "$head" >/dev/null 2>&1 || true
    GITHUB_SYNC_STATUS=clean
    return 0
}

github_sync_fetch() {
    [[ -n "${GITHUB_STORE:-}" ]] || return 1
    if ! github_sync_flush; then
        warn "Есть неотправленные локальные изменения. Сначала отправьте их в GitHub."
        return 1
    fi
    declare -F config_source_startup >/dev/null 2>&1 || return 1
    github_config_close || return 1
    if ! config_source_startup; then
        warn "Не удалось заново открыть конфигурацию после загрузки из GitHub."
        return 1
    fi
    success "Конфигурация загружена из GitHub и открыта на этом компьютере."
}

state_action() {
    local label=$1 fn=$2
    shift 2
    declare -F "$fn" >/dev/null 2>&1 || return 1
    "$fn" "$@"
    local rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    if [[ ${CONFIG_SOURCE:-local} == github ]]; then
        state_validate true >/dev/null || return 1
        state_checkpoint || return 1
        github_config_checkpoint || { GITHUB_SYNC_STATUS=pending; return 1; }
        github_sync_flush || true
    else
        state_checkpoint || true
    fi
    return 0
}

github_config_close() {
    local rc=0 session_dir="" identity="${GITHUB_IDENTITY:-}"
    [[ -n ${GITHUB_WORKTREE:-} ]] && session_dir="${GITHUB_WORKTREE%/worktree}"
    if [[ -n ${GITHUB_WORKTREE:-} ]]; then
        git --git-dir="$GITHUB_STORE" worktree remove --force "$GITHUB_WORKTREE" \
            >/dev/null 2>&1 || rc=1
    fi
    if [[ -n ${GITHUB_SESSION_ID:-} && -d ${GITHUB_STORE:-} ]]; then
        git --git-dir="$GITHUB_STORE" update-ref -d \
            "refs/heads/session/$GITHUB_SESSION_ID" >/dev/null 2>&1 || rc=1
    fi
    [[ -z "$session_dir" ]] || rmdir "$session_dir" 2>/dev/null || true
    if [[ -n "$identity" && "$identity" != "${GITHUB_UNLOCK_FILE:-}" ]]; then
        rm -f "$identity" || rc=1
    fi
    GITHUB_WORKTREE=""
    GITHUB_SESSION_ID=""
    GITHUB_IDENTITY=""
    GITHUB_RECIPIENT=""
    unset GITHUB_MASTER_PASSWORD
    export GITHUB_WORKTREE GITHUB_SESSION_ID GITHUB_IDENTITY GITHUB_RECIPIENT
    return "$rc"
}

