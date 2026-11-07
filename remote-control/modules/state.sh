#!/bin/bash
# ─── Версионированное состояние remote-control ───────────────────────────────
# Этот модуль не выполняет transport-операции. Он отвечает за локальную
# материализацию состояния, атомарную миграцию старого config.json и единый
# secrets/validation contract для local и GitHub backends.

STATE_SCHEMA_VERSION=2

# Keep all paths overridable by a backend before state_open_* is called.
CONFIG_SOURCE="${CONFIG_SOURCE:-local}"
CONFIG_DIR="${CONFIG_DIR:-${HOME:-/tmp}/.config/remote-control-essence}"
LOCAL_CONFIG_JSON="${LOCAL_CONFIG_JSON:-$CONFIG_DIR/config.json}"
STATE_DIR="${STATE_DIR:-$CONFIG_DIR}"
STATE_MANIFEST="${STATE_MANIFEST:-$STATE_DIR/manifest.json}"
CONFIG_JSON="${CONFIG_JSON:-$LOCAL_CONFIG_JSON}"
SECRETS_JSON="${SECRETS_JSON:-$STATE_DIR/secrets.json}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$STATE_DIR/templates}"
SSH_IDENTITIES_DIR="${SSH_IDENTITIES_DIR:-$STATE_DIR/ssh/identities}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$STATE_DIR/ssh/known_hosts}"
SCRIPT_AUTH_FILE="${SCRIPT_AUTH_FILE:-$CONFIG_DIR/.auth}"

_state_hash_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | cut -d' ' -f1
    else
        shasum -a 256 "$file" | cut -d' ' -f1
    fi
}

_state_version_gt() {
    local required="$1" current="${CURRENT_VERSION:-0.0.0}"
    [[ -z "$required" || "$required" == "null" ]] && return 1
    local r1 r2 r3 r_extra c1 c2 c3 c_extra
    IFS=. read -r r1 r2 r3 r_extra <<< "$required"
    IFS=. read -r c1 c2 c3 c_extra <<< "$current"
    r1=${r1:-0}; r2=${r2:-0}; r3=${r3:-0}
    c1=${c1:-0}; c2=${c2:-0}; c3=${c3:-0}
    [[ -z "$r_extra" && -z "$c_extra" &&
       "$r1" =~ ^[0-9]+$ && "$r2" =~ ^[0-9]+$ && "$r3" =~ ^[0-9]+$ ]] || return 1
    [[ "$c1" =~ ^[0-9]+$ && "$c2" =~ ^[0-9]+$ && "$c3" =~ ^[0-9]+$ ]] || return 1
    (( r1 > c1 || (r1 == c1 && r2 > c2) ||
       (r1 == c1 && r2 == c2 && r3 > c3) ))
}

_state_version_valid() {
    local version="$1" major minor patch extra
    IFS=. read -r major minor patch extra <<< "$version"
    [[ -z "$extra" && "$major" =~ ^[0-9]+$ &&
       "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]
}

_state_secret_decode() {
    if declare -F node_pass_decode >/dev/null 2>&1; then
        node_pass_decode "$1"
        return
    fi
    # state.sh is sourced before nodes.sh by the production entrypoint. This
    # fallback only makes migration callable during early bootstrap/tests.
    local machine_id key
    machine_id=$(cat /etc/machine-id 2>/dev/null || hostname)
    key=$(printf '%s' "rcm-${machine_id}" | openssl dgst -sha256 -r | cut -d' ' -f1)
    printf '%s' "$1" | base64 -d 2>/dev/null |
        openssl enc -aes-256-cbc -d -pbkdf2 -k "$key" 2>/dev/null
}

_state_secret_encode() {
    if declare -F node_pass_encode >/dev/null 2>&1; then
        node_pass_encode "$1"
        return
    fi
    local machine_id key
    machine_id=$(cat /etc/machine-id 2>/dev/null || hostname)
    key=$(printf '%s' "rcm-${machine_id}" | openssl dgst -sha256 -r | cut -d' ' -f1)
    printf '%s' "$1" | openssl enc -aes-256-cbc -pbkdf2 -k "$key" 2>/dev/null |
        base64 | tr -d '\n'
}

_state_ensure_dirs() {
    mkdir -p "$STATE_DIR" "$TEMPLATES_DIR" "$SSH_IDENTITIES_DIR" "$(dirname "$SSH_KNOWN_HOSTS")"
    chmod 700 "$STATE_DIR" "$SSH_IDENTITIES_DIR" 2>/dev/null || true
    [[ -f "$SSH_KNOWN_HOSTS" ]] && chmod 600 "$SSH_KNOWN_HOSTS" 2>/dev/null || true
}

_state_write_atomic() {
    local source="$1" target="$2" mode="${3:-600}"
    local tmp="${target}.tmp.$$"
    if ! cp "$source" "$tmp" || ! chmod "$mode" "$tmp" || ! mv "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

_state_ensure_secrets() {
    [[ -f "$SECRETS_JSON" ]] && return 0
    local tmp="${SECRETS_JSON}.tmp.$$"
    umask 077
    printf '%s\n' '{"schema_version":1,"node_passwords":{}}' > "$tmp" || return 1
    chmod 600 "$tmp" && mv "$tmp" "$SECRETS_JSON"
}

# state_open_local — select the device-local backend and migrate before menus.
state_open_local() {
    CONFIG_SOURCE=local
    STATE_DIR="$CONFIG_DIR"
    LOCAL_CONFIG_JSON="${LOCAL_CONFIG_JSON:-$CONFIG_DIR/config.json}"
    CONFIG_JSON="$LOCAL_CONFIG_JSON"
    STATE_MANIFEST="$STATE_DIR/manifest.json"
    SECRETS_JSON="$STATE_DIR/secrets.json"
    TEMPLATES_DIR="$STATE_DIR/templates"
    SSH_IDENTITIES_DIR="$STATE_DIR/ssh/identities"
    SSH_KNOWN_HOSTS="$STATE_DIR/ssh/known_hosts"
    SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    _state_ensure_dirs || return 1
    _ensure_config || return 1
    state_migrate_v1_to_v2 || return 1
    _state_ensure_secrets || return 1
    state_validate false >/dev/null || return 1
    state_checkpoint || return 1
    return 0
}

# state_migrate_v1_to_v2 — validate/decrypt everything before touching source.
state_migrate_v1_to_v2() {
    [[ -f "$CONFIG_JSON" ]] || { _ensure_config || return 1; }
    jq -e . "$CONFIG_JSON" >/dev/null 2>&1 || {
        warn "config.json содержит некорректный JSON."
        return 1
    }

    local schema
    schema=$(jq -r '.schema_version // 1' "$CONFIG_JSON" 2>/dev/null) || return 1
    [[ "$schema" == "2" ]] && {
        # A v2 config must never retain the old inline password field.
        if jq -e 'any(.nodes[]?; has("pass"))' "$CONFIG_JSON" >/dev/null 2>&1; then
            warn "В конфигурации версии 2 пароль ноды нельзя хранить непосредственно в config.json."
            return 1
        fi
        return 0
    }
    [[ "$schema" == "1" || "$schema" == "null" ]] || {
        warn "Неподдерживаемая версия config.json: $schema"
        return 1
    }

    local parent migration_dir config_tmp secrets_tmp manifest_tmp
    parent=$(dirname "$CONFIG_JSON")
    migration_dir=$(mktemp -d "$parent/.state-migration.XXXXXX") || return 1
    config_tmp="$migration_dir/config.json"
    secrets_tmp="$migration_dir/secrets.json"
    manifest_tmp="$migration_dir/manifest.json"

    local node_count i node id auth pass decoded secret_id
    node_count=$(jq '.nodes | length' "$CONFIG_JSON") || { rm -rf "$migration_dir"; return 1; }
    local -a ids=() seen_ids=()
    printf '%s\n' '{"schema_version":1,"node_passwords":{}}' > "$secrets_tmp"

    # Do not write config/secrets until every old ciphertext has decrypted.
    for ((i = 0; i < node_count; i++)); do
        node=$(jq -c --argjson i "$i" '.nodes[$i]' "$CONFIG_JSON") || {
            rm -rf "$migration_dir"; return 1;
        }
        id=$(jq -r '.id // empty' <<< "$node") || {
            rm -rf "$migration_dir"; return 1;
        }
        if [[ -z "$id" ]]; then
            id=$(openssl rand -hex 16 2>/dev/null) || {
                rm -rf "$migration_dir"; return 1;
            }
        fi
        [[ "$id" =~ ^[0-9a-fA-F]{32}$ ]] || {
            warn "Некорректный идентификатор ноды."
            rm -rf "$migration_dir"; return 1
        }
        local duplicate j
        for ((j = 0; j < ${#seen_ids[@]}; j++)); do
            duplicate="${seen_ids[$j]}"
            [[ "$duplicate" == "$id" ]] && {
                warn "Повторяющийся идентификатор ноды."
                rm -rf "$migration_dir"; return 1
            }
        done
        seen_ids+=("$id")
        ids[$i]="$id"
        auth=$(jq -r '.auth // (if has("pass") then "password" else "key" end)' <<< "$node")
        if [[ "$auth" == "password" ]]; then
            pass=$(jq -r '.pass // empty' <<< "$node")
            [[ -n "$pass" ]] || {
                warn "У ноды с авторизацией по паролю отсутствует сохранённый пароль."
                rm -rf "$migration_dir"; return 1
            }
            decoded=$(_state_secret_decode "$pass") || {
                warn "Не удалось расшифровать пароль ноды."
                rm -rf "$migration_dir"; return 1
            }
            [[ -n "$decoded" ]] || {
                warn "Не удалось расшифровать пароль ноды."
                rm -rf "$migration_dir"; return 1
            }
            secret_id="node:${id}:ssh-password"
            local encoded_json
            encoded_json=$(jq --arg k "$secret_id" --arg v "$pass" '.node_passwords[$k]=$v' "$secrets_tmp") || {
                rm -rf "$migration_dir"; return 1;
            }
            printf '%s\n' "$encoded_json" > "$secrets_tmp"
        fi
    done

    local migrated
    migrated=$(jq -c --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)" '
        .schema_version=2 |
        .nodes = [range(0; (.nodes|length)) as $i |
          .nodes[$i] |
          .id=$ids[$i] |
          .auth=(.auth // (if has("pass") then "password" else "key" end)) |
          .identity=(if .auth=="password" then null else (.identity // "system") end) |
          .secret_id=(if .auth=="password" then ("node:" + .id + ":ssh-password") else null end) |
          del(.pass) |
          .aliases=(.aliases // {})
        ]
    ' "$CONFIG_JSON") || { rm -rf "$migration_dir"; return 1; }
    printf '%s\n' "$migrated" | jq . > "$config_tmp" || {
        rm -rf "$migration_dir"; return 1;
    }

    local minimum script_password_hash=""
    minimum=$(jq -r '.minimum_remote_control_version // empty' "$CONFIG_JSON")
    [[ -s "${SCRIPT_AUTH_FILE:-}" ]] &&
        script_password_hash=$(tr -d '\r\n' < "$SCRIPT_AUTH_FILE")
    jq -n --arg min "$minimum" --arg password_hash "$script_password_hash" \
        '{schema_version:2,minimum_remote_control_version:(if $min=="" then null else $min end),portability:{status:"ready",issues:[]},access:{script_password_hash:(if $password_hash=="" then null else $password_hash end)},templates:{}}' \
        > "$manifest_tmp" || {
        rm -rf "$migration_dir"; return 1;
    }
    chmod 600 "$config_tmp" "$secrets_tmp" "$manifest_tmp"

    # Install all files only after the complete migration has been prepared.
    # Keep rollback copies so a failed rename cannot leave a half-migrated
    # local state (for example, a read-only manifest directory).
    local -a migration_targets=("$SECRETS_JSON" "$CONFIG_JSON" "$STATE_MANIFEST")
    local -a migration_backups=()
    local target backup target_index
    for target_index in "${!migration_targets[@]}"; do
        target="${migration_targets[$target_index]}"
        if [[ -e "$target" ]]; then
            backup="$migration_dir/original.$target_index"
            cp -p "$target" "$backup" || {
                rm -rf "$migration_dir"
                return 1
            }
            migration_backups[$target_index]="$backup"
        fi
    done

    if ! mv -f "$secrets_tmp" "$SECRETS_JSON" ||
       ! mv -f "$config_tmp" "$CONFIG_JSON" ||
       ! mv -f "$manifest_tmp" "$STATE_MANIFEST"; then
        for target_index in "${!migration_targets[@]}"; do
            target="${migration_targets[$target_index]}"
            backup="${migration_backups[$target_index]:-}"
            if [[ -n "$backup" && -e "$backup" ]]; then
                rm -f "$target"
                mv -f "$backup" "$target" || true
            else
                rm -f "$target"
            fi
        done
        rm -rf "$migration_dir"
        return 1
    fi
    rm -rf "$migration_dir"
    return 0
}

_state_node_issue_json() {
    local id="$1" reason="$2"
    jq -nc --arg id "$id" --arg reason "$reason" '{node_id:$id,reason:$reason}'
}

_state_declared_portability() {
    local source="$STATE_MANIFEST"
    [[ -f "$source" ]] || source="$CONFIG_JSON"
    jq -c '{status:(.portability.status // "ready"),issues:(.portability.issues // [])}' "$source" 2>/dev/null ||
        printf '%s\n' '{"status":"ready","issues":[]}'
}

# state_validate <portable:true|false> — validate logical state and resources.
state_validate() {
    local portable="${1:-false}"
    [[ "$portable" == "true" || "$portable" == "false" ]] || {
        warn "state_validate ожидает portable:true или portable:false."
        return 1
    }
    [[ -f "$CONFIG_JSON" ]] || { warn "Не найден config.json."; return 1; }
    jq -e . "$CONFIG_JSON" >/dev/null 2>&1 || {
        warn "config.json содержит некорректный JSON."
        return 1
    }

    local schema minimum
    schema=$(jq -r '.schema_version // empty' "$CONFIG_JSON") || return 1
    [[ "$schema" == "2" ]] || {
        warn "Ожидается schema_version: 2."
        return 1
    }
    minimum=$(jq -r '.minimum_remote_control_version // empty' "$STATE_MANIFEST" 2>/dev/null || true)
    [[ -n "$minimum" ]] || minimum=$(jq -r '.minimum_remote_control_version // empty' "$CONFIG_JSON" 2>/dev/null || true)
    if [[ -n "$minimum" ]]; then
        _state_version_valid "$minimum" || {
            warn "Некорректная minimum_remote_control_version: ${minimum}."
            return 1
        }
        if [[ -n "${CURRENT_VERSION:-}" ]] && _state_version_gt "$minimum"; then
            warn "Для этого config требуется Remote Control ${minimum}. Обновите скрипт и запустите снова."
            return 1
        fi
    fi

    if [[ -f "$SECRETS_JSON" ]] &&
       ! jq -e 'type=="object" and (.schema_version == 1) and (.node_passwords|type=="object")' \
           "$SECRETS_JSON" >/dev/null 2>&1; then
        warn "Файл защищённых данных имеет некорректную структуру."
        return 1
    fi

    jq -e '
        . as $root |
        ($root.nodes|type=="array") and ($root.groups|type=="array") and
        ($root.clients|type=="array") and ($root.connections|type=="array") and
        ($root.nodes | all(.[]; (
          (.id|type=="string" and test("^[0-9a-fA-F]{32}$")) and
          (.name|type=="string" and length>0) and
          (.ip|type=="string" and length>0) and
          (.port|type=="number" and floor==. and . >= 1 and . <= 65535) and
          (.user|type=="string" and length>0) and
          (.auth|type=="string" and test("^(key|password)$")) and
          ((.aliases // {})|type=="object")
        ))) and
        (([$root.nodes[].id] | length) == ([$root.nodes[].id] | unique | length)) and
        (([$root.nodes[].name] | length) == ([$root.nodes[].name] | unique | length))
    ' "$CONFIG_JSON" >/dev/null 2>&1 || {
        warn "Структура config.json или нод некорректна."
        return 1
    }

    jq -e '
      .nodes as $nodes |
      (all(.connections[]?; .node as $name |
          any($nodes[]; .name == $name))) and
      (all(.clients[]?;
          (all(.nodes[]?; . as $name | any($nodes[]; .name == $name))) and
          (all(.connections[]?; .node as $name |
              any($nodes[]; .name == $name)))))
    ' "$CONFIG_JSON" >/dev/null 2>&1 || {
        warn "config.json содержит ссылку на неизвестную ноду."
        return 1
    }

    if [[ "$portable" == "true" ]]; then
        local template_name group_count
        group_count=$(jq -r '.groups|length' "$CONFIG_JSON") || return 1
        if (( group_count > 0 )); then
            while IFS= read -r template_name; do
                [[ "$template_name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || {
                    warn "Недопустимое имя шаблона: ${template_name}."
                    return 1
                }
                [[ -f "$TEMPLATES_DIR/$template_name" ]] || {
                    warn "Не найден шаблон состояния: ${template_name}."
                    return 1
                }
            done < <(jq -r '.groups[] | (.template // "default.yaml")' "$CONFIG_JSON")
        fi
    fi

    local node_json node_id node_auth node_identity node_secret
    local -a detected=()
    local node_count
    node_count=$(jq -r '.nodes|length' "$CONFIG_JSON") || return 1
    if (( node_count > 0 )); then
    while IFS= read -r node_json; do
        node_id=$(jq -r '.id' <<< "$node_json")
        node_auth=$(jq -r '.auth // "password"' <<< "$node_json")
        node_identity=$(jq -r '.identity // empty' <<< "$node_json")
        node_secret=$(jq -r '.secret_id // empty' <<< "$node_json")
        if [[ "$node_auth" == "password" ]]; then
            [[ "$node_secret" == "node:${node_id}:ssh-password" ]] || {
                warn "У ноды ${node_id} некорректная ссылка на пароль (secret_id)."
                return 1
            }
            jq -e --arg id "$node_secret" '.node_passwords[$id]|type=="string" and length>0' \
                "$SECRETS_JSON" >/dev/null 2>&1 || {
                if [[ "$portable" == "true" ]]; then
                    detected+=("$(_state_node_issue_json "$node_id" missing_secret)")
                else
                    warn "Для ноды с авторизацией по паролю ${node_id} отсутствуют защищённые данные."
                    return 1
                fi
            }
        else
            [[ "$(jq -r 'has("secret_id") and (.secret_id == null)' <<< "$node_json")" == "true" ]] || {
                warn "У ноды с авторизацией по ключу ${node_id} ссылка на пароль (secret_id) должна быть пустой."
                return 1
            }
            if [[ "$portable" == "true" ]]; then
                if [[ -z "$node_identity" || "$node_identity" == "system" ]]; then
                    detected+=("$(_state_node_issue_json "$node_id" missing_identity)")
                elif [[ "$node_identity" != "$node_id" ||
                        ! -f "$SSH_IDENTITIES_DIR/$node_identity" ||
                        ! -f "$SSH_IDENTITIES_DIR/$node_identity.pub" ]]; then
                    detected+=("$(_state_node_issue_json "$node_id" missing_identity)")
                elif ! ssh-keygen -y -f "$SSH_IDENTITIES_DIR/$node_identity" >/dev/null 2>&1; then
                    warn "Приватный ключ ноды ${node_id} некорректен."
                    return 1
                elif [[ "$(ssh-keygen -lf "$SSH_IDENTITIES_DIR/$node_identity" 2>/dev/null | awk '{print $2}')" != "$(ssh-keygen -lf "$SSH_IDENTITIES_DIR/$node_identity.pub" 2>/dev/null | awk '{print $2}')" ]]; then
                    warn "Пара SSH-ключей ноды ${node_id} не совпадает."
                    return 1
                fi
            fi
        fi
        if [[ "$portable" == "true" ]]; then
            local host ip port host_entry
            ip=$(jq -r '.ip' <<< "$node_json")
            port=$(jq -r '.port' <<< "$node_json")
            host_entry="$ip"
            [[ "$port" != "22" ]] && host_entry="[$ip]:$port"
            if [[ ! -f "$SSH_KNOWN_HOSTS" ]] ||
               ! ssh-keygen -F "$host_entry" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
                detected+=("$(_state_node_issue_json "$node_id" missing_host_key)")
            fi
        fi
    done < <(jq -c '.nodes[]' "$CONFIG_JSON")
    fi

    local declared status issues_json detected_json
    declared=$(_state_declared_portability)
    jq -e '(.status=="ready" or .status=="needs_setup") and
        (.issues|type=="array") and
        all(.issues[]; type=="object" and
            (.node_id|type=="string") and
            (.reason=="missing_identity" or .reason=="missing_secret" or .reason=="missing_host_key"))' \
        <<< "$declared" >/dev/null 2>&1 || {
        warn "portability содержит некорректные issue."
        return 1
    }
    status=$(jq -r '.status' <<< "$declared")
    issues_json=$(jq -c '.issues' <<< "$declared")
    detected_json='[]'
    if [[ "${#detected[@]}" -gt 0 ]]; then
        detected_json=$(printf '%s\n' "${detected[@]}" | jq -s -c 'unique | sort_by([.node_id,.reason])') || {
            warn "Не удалось собрать portability issues."
            return 1
        }
    fi
    if [[ "$portable" == "true" ]]; then
        if [[ "${#detected[@]}" -gt 0 ]]; then
            [[ "$status" == "needs_setup" ]] || {
                warn "Переносимое состояние требует настройки нод."
                return 1
            }
            if [[ "$(jq -S -c 'sort_by([.node_id,.reason])' <<< "$issues_json")" != "$(jq -S -c 'sort_by([.node_id,.reason])' <<< "$detected_json")" ]]; then
                warn "portability.issues не соответствует отсутствующим ресурсам."
                return 1
            fi
        else
            [[ "$status" == "ready" && "$issues_json" == "[]" ]] || {
                warn "portability содержит устаревшие issue."
                return 1
            }
        fi
    fi
    [[ "$status" == "needs_setup" ]] && echo "needs_setup" || echo "ready"
}
state_actionable_ssh_setup_pending() {
    local status declared
    status=$(state_validate true 2>/dev/null) || return 1
    [[ "$status" == needs_setup ]] || return 1
    declared=$(_state_declared_portability) || return 1
    jq -e 'any(.issues[]?;
        .reason=="missing_identity" or .reason=="missing_host_key")' \
        <<< "$declared" >/dev/null 2>&1
}


node_secret_get() {
    local node_id="${1:-}"
    [[ -n "$node_id" ]] || return 1
    local secret_id="node:${node_id}:ssh-password"
    [[ -f "$SECRETS_JSON" ]] || return 1
    local cipher
    cipher=$(jq -r --arg id "$secret_id" '.node_passwords[$id] // empty' "$SECRETS_JSON" 2>/dev/null) || return 1
    [[ -n "$cipher" ]] || return 1
    _state_secret_decode "$cipher"
}

node_secret_set() {
    local node_id="${1:-}" plaintext="${2:-}"
    [[ -n "$node_id" && -n "$plaintext" ]] || return 1
    _state_ensure_dirs || return 1
    _state_ensure_secrets || return 1
    local encoded tmp secret_id="node:${node_id}:ssh-password"
    encoded=$(_state_secret_encode "$plaintext") || return 1
    [[ -n "$encoded" ]] || return 1
    tmp="${SECRETS_JSON}.tmp.$$"
    if ! jq --arg id "$secret_id" --arg value "$encoded" \
        '.schema_version=(.schema_version // 1) | .node_passwords=(.node_passwords // {}) | .node_passwords[$id]=$value' \
        "$SECRETS_JSON" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" && mv "$tmp" "$SECRETS_JSON"
}

node_secret_delete() {
    local node_id="${1:-}" tmp
    [[ -n "$node_id" ]] || return 1
    local secret_id="node:${node_id}:ssh-password"
    [[ -f "$SECRETS_JSON" ]] || return 0
    tmp="${SECRETS_JSON}.tmp.$$"
    if ! jq --arg id "$secret_id" 'del(.node_passwords[$id])' "$SECRETS_JSON" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" && mv "$tmp" "$SECRETS_JSON"
}

state_checkpoint() {
    [[ -f "$CONFIG_JSON" ]] || return 1
    _state_ensure_dirs || return 1
    _state_ensure_secrets || return 1
    local tmp existing minimum script_password_hash=""
    tmp="${STATE_MANIFEST}.tmp.$$"
    existing='{}'
    [[ -f "$STATE_MANIFEST" ]] && existing=$(jq -c . "$STATE_MANIFEST" 2>/dev/null || printf '%s' '{}')
    minimum=$(jq -r '.minimum_remote_control_version // empty' <<< "$existing" 2>/dev/null || true)
    [[ -n "$minimum" ]] || minimum="${CURRENT_VERSION:-0.0.0}"
    [[ -s "${SCRIPT_AUTH_FILE:-}" ]] &&
        script_password_hash=$(tr -d '\r\n' < "$SCRIPT_AUTH_FILE")
    if ! jq -n --argjson old "$existing" --arg min "$minimum" \
        --arg password_hash "$script_password_hash" \
        '{schema_version:2,minimum_remote_control_version:$min,portability:($old.portability // {status:"ready",issues:[]}),access:{script_password_hash:(if $password_hash=="" then null else $password_hash end)},templates:($old.templates // {})}' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" && mv "$tmp" "$STATE_MANIFEST"
}

state_portability_set_issues() {
    local issues="${1:-[]}" existing='{}' tmp
    jq -e 'type=="array" and all(.[]; type=="object" and
        (.node_id|type=="string") and
        (.reason=="missing_identity" or .reason=="missing_secret" or .reason=="missing_host_key"))' \
        <<< "$issues" >/dev/null 2>&1 || return 1
    _state_ensure_dirs || return 1
    [[ -f "$STATE_MANIFEST" ]] && existing=$(jq -c . "$STATE_MANIFEST" 2>/dev/null || printf '%s' '{}')
    tmp="${STATE_MANIFEST}.tmp.$$"
    jq --argjson issues "$issues" \
        '.schema_version=2 | .portability={status:(if ($issues|length)>0 then "needs_setup" else "ready" end),issues:$issues}' \
        <<< "$existing" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$tmp" && mv "$tmp" "$STATE_MANIFEST"
}

state_portability_add_issue() {
    local node_id="${1:-}" reason="${2:-}" current updated
    [[ -n "$node_id" && -n "$reason" ]] || return 1
    current=$(_state_declared_portability | jq -c '.issues')
    updated=$(jq -c --arg id "$node_id" --arg reason "$reason" \
        '. + [{node_id:$id,reason:$reason}] | unique | sort_by([.node_id,.reason])' <<< "$current") || return 1
    state_portability_set_issues "$updated"
}

state_portability_remove_issue() {
    local node_id="${1:-}" reason="${2:-}" current updated
    [[ -n "$node_id" && -n "$reason" ]] || return 1
    current=$(_state_declared_portability | jq -c '.issues')
    updated=$(jq -c --arg id "$node_id" --arg reason "$reason" \
        'map(select(.node_id != $id or .reason != $reason))' <<< "$current") || return 1
    state_portability_set_issues "$updated"
}

state_portability_remove_node() {
    local node_id="${1:-}" current updated
    [[ -n "$node_id" ]] || return 1
    current=$(_state_declared_portability | jq -c '.issues')
    updated=$(jq -c --arg id "$node_id" 'map(select(.node_id != $id))' <<< "$current") || return 1
    state_portability_set_issues "$updated"
}

# state_action is intentionally transport-agnostic. github-config.sh may wrap
# it with a stronger snapshot/flush implementation; local mode must remain a
# direct call so existing menu functions retain their return values.
state_action() {
    local label="$1" function="$2"
    shift 2
    [[ -n "$function" ]] || return 1
    declare -F "$function" >/dev/null 2>&1 || {
        warn "Неизвестное действие состояния: $function"
        return 1
    }
    "$function" "$@"
    local rc=$?
    if [[ "$CONFIG_SOURCE" == "local" && $rc -eq 0 ]]; then
        state_checkpoint >/dev/null 2>&1 || true
    fi
    return "$rc"
}