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

STATE_FORMAT_VERSION=2

# format_migrate_chain <kind> <from> <to> [args…] — run _migrate_<kind>_<n>_to_<n+1> in order.
format_migrate_chain() {
    local kind="${1:?kind}" from="${2:?from}" to="${3:?to}" n step
    shift 3
    [[ "$from" =~ ^[1-9][0-9]*$ && "$to" =~ ^[1-9][0-9]*$ ]] || return 1
    (( from <= to )) || return 1
    for ((n = from; n < to; n++)); do
        step="_migrate_${kind}_${n}_to_$((n + 1))"
        declare -F "$step" >/dev/null 2>&1 || return 1
        "$step" "$@" || return 1
    done
}

_state_secret_decode() (
    set -o pipefail
    if declare -F node_pass_decode >/dev/null 2>&1; then
        node_pass_decode "$1"
        return
    fi
    # state.sh is sourced before nodes.sh by the production entrypoint. This
    # fallback only makes migration callable during early bootstrap/tests.
    local machine_id key
    machine_id=$(cat /etc/machine-id 2>/dev/null || hostname)
    key=$(printf '%s' "rcm-${machine_id}" | openssl dgst -sha256 -r | cut -d' ' -f1) || return 1
    printf '%s' "$1" | base64 -d 2>/dev/null |
        openssl enc -aes-256-cbc -d -pbkdf2 -pass fd:3 3<<< "$key" 2>/dev/null
)

_state_secret_encode() (
    set -o pipefail
    if declare -F node_pass_encode >/dev/null 2>&1; then
        node_pass_encode "$1"
        return
    fi
    local machine_id key
    machine_id=$(cat /etc/machine-id 2>/dev/null || hostname)
    key=$(printf '%s' "rcm-${machine_id}" | openssl dgst -sha256 -r | cut -d' ' -f1) || return 1
    printf '%s' "$1" | openssl enc -aes-256-cbc -pbkdf2 -pass fd:3 3<<< "$key" 2>/dev/null |
        base64 | tr -d '\n'
)

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
    state_format_migrate || return 1
    _state_ensure_secrets || return 1
    state_validate false >/dev/null || return 1
    state_checkpoint || return 1
    return 0
}

# state_format_migrate — bring local config.json to STATE_FORMAT_VERSION before validation.
state_format_migrate() {
    [[ -f "$CONFIG_JSON" ]] || { _ensure_config || return 1; }
    jq -e . "$CONFIG_JSON" >/dev/null 2>&1 || {
        warn "config.json содержит некорректный JSON."
        return 1
    }
    local schema
    schema=$(jq -r '.schema_version // 1' "$CONFIG_JSON" 2>/dev/null) || return 1
    [[ "$schema" =~ ^[1-9][0-9]*$ ]] || {
        warn "Неподдерживаемая версия config.json: $schema"
        return 1
    }
    if (( schema > STATE_FORMAT_VERSION )); then
        warn "config.json создан более новой версией Remote Control (формат $schema). Обновите скрипт и запустите снова."
        return 1
    fi
    if (( schema < STATE_FORMAT_VERSION )); then
        format_migrate_chain state "$schema" "$STATE_FORMAT_VERSION" || return 1
    fi
    # A v2 config must never retain the old inline password field.
    if jq -e 'any(.nodes[]?; has("pass"))' "$CONFIG_JSON" >/dev/null 2>&1; then
        warn "В конфигурации версии 2 пароль ноды нельзя хранить непосредственно в config.json."
        return 1
    fi
}

# _migrate_state_1_to_2 — move inline node passwords into secrets.json (schema 1→2).
_migrate_state_1_to_2() {
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
            encoded_json=$(printf '%s' "$pass" | jq -Rs --arg k "$secret_id" --slurpfile s "$secrets_tmp" '. as $v | $s[0] | .node_passwords[$k]=$v') || {
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

    local minimum script_auth_hash=""
    minimum=$(jq -r '.minimum_remote_control_version // empty' "$CONFIG_JSON")
    [[ -s "${SCRIPT_AUTH_FILE:-}" ]] &&
        script_auth_hash=$(tr -d '\r\n' < "$SCRIPT_AUTH_FILE")
    jq -n --arg min "$minimum" --arg auth_hash "$script_auth_hash" \
        '{schema_version:2,minimum_remote_control_version:(if $min=="" then null else $min end),portability:{status:"ready",issues:[]},access:{script_password_hash:(if $auth_hash=="" then null else $auth_hash end)},templates:{}}' \
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
    jq -c '{status:(.portability.status // "ready"),issues:(.portability.issues // [])}' "$source" 2>/dev/null
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

    _state_secrets_container_valid "$SECRETS_JSON" || {
        warn "Файл защищённых данных имеет некорректную структуру."
        return 1
    }

    jq -e --arg ure "$NODE_SSH_USER_RE" --arg hre "$NODE_SSH_HOST_RE" '
        . as $root |
        ($root.nodes|type=="array") and ($root.groups|type=="array") and
        ($root.clients|type=="array") and ($root.connections|type=="array") and
        ($root.nodes | all(.[]; (
          (.id|type=="string" and test("^[0-9a-fA-F]{32}$")) and
          (.name|type=="string" and length>0) and
          (.port|type=="number" and floor==. and . >= 1 and . <= 65535) and
          '"$NODE_SSH_FIELDS_JQ"' and
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

    local declared issues_json detected_json node_issues
    node_issues=$(_state_password_issues "$CONFIG_JSON" "$SECRETS_JSON") || return 1
    declared=$(_state_declared_portability) || return 1
    jq -e '(.status=="ready" or .status=="needs_setup") and
        (.issues|type=="array") and
        all(.issues[]; type=="object" and
            (.node_id|type=="string") and
            (.reason=="missing_identity" or .reason=="missing_secret" or .reason=="missing_host_key"))' \
        <<< "$declared" >/dev/null 2>&1 || {
        warn "portability содержит некорректные issue."
        return 1
    }
    issues_json=$(jq -c --argjson secret_issues "$node_issues" \
        '[.issues[] | select(.reason!="missing_secret")] + $secret_issues |
         unique | sort_by([.node_id,.reason])' <<< "$declared") || return 1
    detected_json='[]'
    if [[ "${#detected[@]}" -gt 0 ]]; then
        detected_json=$(printf '%s\n' "${detected[@]}" | jq -s -c 'unique | sort_by([.node_id,.reason])') || {
            warn "Не удалось собрать portability issues."
            return 1
        }
    fi
    if [[ "$portable" == "true" ]]; then
        if [[ "$(jq -S -c 'map(select(.reason!="missing_secret")) | sort_by([.node_id,.reason])' <<< "$issues_json")" != \
              "$(jq -S -c 'sort_by([.node_id,.reason])' <<< "$detected_json")" ]]; then
            warn "portability.issues не соответствует отсутствующим ресурсам."
            return 1
        fi
    fi
    [[ "$issues_json" != "[]" ]] && echo "needs_setup" || echo "ready"
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


# Runtime entries may be individually broken; only the container is mandatory.
_state_secrets_container_valid() {
    [[ -f "$1" && -r "$1" ]] || return 1
    jq -e -s 'length==1 and (.[0] | type=="object" and
        .schema_version==1 and (.node_passwords|type=="object"))' \
        "$1" >/dev/null 2>&1
}

_state_secret_tools_available() {
    local tool
    for tool in jq openssl base64 cut tr cat mktemp; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
}

# stdout is plaintext only. 2 is a single unavailable password, 1 is global.
node_secret_get() (
    umask 077
    local node_id="${1:-}" secrets_file="${2:-$SECRETS_JSON}"
    [[ -n "$node_id" ]] || return 1
    _state_secret_tools_available || return 1
    _state_secrets_container_valid "$secrets_file" || return 1
    local secret_id="node:${node_id}:ssh-password" cipher plaintext work rc
    rc=0
    jq -e --arg id "$secret_id" '.node_passwords[$id] |
        type=="string" and length>0 and (contains("\u0000")|not)' \
        "$secrets_file" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 1 ]] || return 2
    [[ "$rc" -eq 0 ]] || return 1
    cipher=$(jq -r --arg id "$secret_id" '.node_passwords[$id]' "$secrets_file") || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/node-secret.XXXXXX") || return 1
    trap 'rm -rf "$work"' EXIT
    # A failed decoder can emit a prefix. Keep it private and discard it.
    _state_secret_decode "$cipher" > "$work/password" || return 2
    [[ -s "$work/password" ]] || return 2
    rc=0
    jq -ne --rawfile password "$work/password" \
        '$password | contains("\u0000") | not' >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 1 ]] || return 2
    [[ "$rc" -eq 0 ]] || return 1
    plaintext=$(cat "$work/password"; rc=$?; printf '.'; exit "$rc") || return 1
    plaintext="${plaintext%.}"
    [[ -n "$plaintext" ]] || return 2
    printf '%s' "$plaintext"
)

_state_password_nodes() {
    jq -e -s 'length==1 and (.[0] | type=="object" and
        .schema_version==2 and (.nodes|type=="array") and
        (.groups|type=="array") and (.clients|type=="array") and
        (.connections|type=="array") and
        all(.nodes[]; type=="object" and
            (.id|type=="string" and test("^[0-9a-fA-F]{32}$")) and
            (.name|type=="string" and length>0) and
            (.ip|type=="string" and length>0) and
            (.port|type=="number" and floor==. and .>=1 and .<=65535) and
            (.user|type=="string" and length>0) and
            (.auth=="password" or .auth=="key") and
            (if .auth=="password" then .secret_id==("node:"+.id+":ssh-password")
             else has("secret_id") and .secret_id==null end)))' \
        "$1" >/dev/null 2>&1 || return 1
    jq -r '[.nodes[] | select(.auth=="password") | .id] | unique[]' "$1"
}

_state_password_issues() {
    local config_file="$1" secrets_file="$2" ids id rc issues='[]'
    _state_secret_tools_available || return 1
    _state_secrets_container_valid "$secrets_file" || return 1
    ids=$(_state_password_nodes "$config_file") || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        rc=0
        node_secret_get "$id" "$secrets_file" >/dev/null || rc=$?
        case "$rc" in
            0) ;;
            2) issues=$(jq -c --arg id "$id" \
                '. + [{node_id:$id,reason:"missing_secret"}]' <<< "$issues") || return 1 ;;
            *) return 1 ;;
        esac
    done <<< "$ids"
    jq -c 'unique | sort_by([.node_id,.reason])' <<< "$issues"
}

# Conversion outputs belong to private caller-owned staging, never live state.
# Work in a private sibling directory, and publish only fully formed results.
_state_secrets_export_portable() (
    umask 077
    local config_file="$1" runtime_secrets="$2" portable_output="$3" issues_output="$4"
    local work ids id plaintext rc had_portable=false had_issues=false
    [[ "$portable_output" != "$issues_output" &&
       "$portable_output" != "$runtime_secrets" && "$issues_output" != "$runtime_secrets" &&
       "$portable_output" != "$config_file" && "$issues_output" != "$config_file" ]] || return 1
    [[ ! -d "$portable_output" && ! -L "$portable_output" &&
       ! -d "$issues_output" && ! -L "$issues_output" &&
       -d "$(dirname "$issues_output")" ]] || return 1
    _state_secret_tools_available || return 1
    _state_secrets_container_valid "$runtime_secrets" || return 1
    ids=$(_state_password_nodes "$config_file") || return 1
    work=$(mktemp -d "$(dirname "$portable_output")/.portable-secrets.XXXXXX") || return 1
    trap 'rm -rf "$work"' EXIT
    printf '%s\n' '{"schema_version":2,"node_passwords":{}}' > "$work/secrets" || return 1
    printf '%s\n' '[]' > "$work/issues" || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        rc=0
        plaintext=$(node_secret_get "$id" "$runtime_secrets"; rc=$?; printf '.'; exit "$rc") || rc=$?
        case "$rc" in
            0)
                plaintext="${plaintext%.}"
                printf '%s' "$plaintext" > "$work/password" || return 1
                jq --arg id "node:${id}:ssh-password" --rawfile password "$work/password" \
                    '.node_passwords[$id]=$password' "$work/secrets" > "$work/next" || return 1
                mv "$work/next" "$work/secrets" || return 1
                ;;
            2)
                jq --arg id "$id" '. + [{node_id:$id,reason:"missing_secret"}]' \
                    "$work/issues" > "$work/next" || return 1
                mv "$work/next" "$work/issues" || return 1
                ;;
            *) return 1 ;;
        esac
    done <<< "$ids"
    if [[ -e "$portable_output" ]]; then
        cp -p "$portable_output" "$work/old-secrets" || return 1
        had_portable=true
    fi
    if [[ -e "$issues_output" ]]; then
        cp -p "$issues_output" "$work/old-issues" || return 1
        had_issues=true
    fi
    if ! _state_write_atomic "$work/secrets" "$portable_output" ||
       ! _state_write_atomic "$work/issues" "$issues_output"; then
        if $had_portable; then
            mv -f "$work/old-secrets" "$portable_output" || return 1
        else
            rm -f "$portable_output"
        fi
        if $had_issues; then
            mv -f "$work/old-issues" "$issues_output" || return 1
        else
            rm -f "$issues_output"
        fi
        return 1
    fi
)

_state_secrets_import_portable() (
    umask 077
    local portable_input="$1" runtime_output="$2" work ids id plaintext encoded
    [[ "$portable_input" != "$runtime_output" &&
       ! -d "$runtime_output" && ! -L "$runtime_output" ]] || return 1
    _state_secret_tools_available || return 1
    # Reject NUL before JSON strings enter Bash; empty entries are not secrets.
    jq -e -s 'length==1 and (.[0] | type=="object" and
        .schema_version==2 and (.node_passwords|type=="object") and
        all(.node_passwords | to_entries[];
            (.key|test("^node:[0-9a-fA-F]{32}:ssh-password$")) and
            (.value|type=="string" and length>0 and (contains("\u0000")|not))))' \
        "$portable_input" >/dev/null 2>&1 || return 1
    ids=$(jq -r '.node_passwords | keys[]' "$portable_input") || return 1
    work=$(mktemp -d "$(dirname "$runtime_output")/.runtime-secrets.XXXXXX") || return 1
    trap 'rm -rf "$work"' EXIT
    printf '%s\n' '{"schema_version":1,"node_passwords":{}}' > "$work/secrets" || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        plaintext=$(jq -j --arg id "$id" '.node_passwords[$id]' "$portable_input";
            rc=$?; printf '.'; exit "$rc") || return 1
        plaintext="${plaintext%.}"
        encoded=$(_state_secret_encode "$plaintext") || return 1
        [[ -n "$encoded" ]] || return 1
        printf '%s' "$encoded" > "$work/cipher" || return 1
        jq --arg id "$id" --rawfile cipher "$work/cipher" \
            '.node_passwords[$id]=$cipher' "$work/secrets" > "$work/next" || return 1
        mv "$work/next" "$work/secrets" || return 1
    done <<< "$ids"
    _state_write_atomic "$work/secrets" "$runtime_output"
)

_state_warn_missing_passwords() {
    local config_file="$1" issues_json="$2" names
    names=$(jq -r --argjson issues "$issues_json" \
        '[.nodes[] | . as $node |
          select(any($issues[]; .reason=="missing_secret" and .node_id==$node.id)) |
          .name] | unique | join(", ")' "$config_file") || return 1
    [[ -n "$names" ]] || return 0
    warn "Конфигурация неполна: пароль SSH недоступен для нод: ${names}."
}

node_secret_set() {
    local node_id="${1:-}" plaintext="${2:-}"
    [[ -n "$node_id" && -n "$plaintext" ]] || return 1
    _state_secret_tools_available || return 1
    umask 077
    _state_ensure_dirs || return 1
    _state_ensure_secrets || return 1
    _state_secrets_container_valid "$SECRETS_JSON" || return 1
    local encoded tmp secret_id="node:${node_id}:ssh-password"
    encoded=$(_state_secret_encode "$plaintext") || return 1
    [[ -n "$encoded" ]] || return 1
    tmp="${SECRETS_JSON}.tmp.$$"
    # Шифротекст — через stdin, не в argv jq (/proc/<pid>/cmdline).
    if ! printf '%s' "$encoded" | jq --arg id "$secret_id" --rawfile value /dev/stdin \
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
    local tmp existing minimum node_issues script_auth_hash=""
    node_issues=$(_state_password_issues "$CONFIG_JSON" "$SECRETS_JSON") || return 1
    umask 077
    tmp="${STATE_MANIFEST}.tmp.$$"
    existing='{}'
    if [[ -f "$STATE_MANIFEST" ]]; then
        existing=$(jq -ce 'select(type=="object")' "$STATE_MANIFEST") || return 1
    fi
    minimum=$(jq -r '.minimum_remote_control_version // empty' <<< "$existing" 2>/dev/null || true)
    [[ -n "$minimum" ]] || minimum="${CURRENT_VERSION:-0.0.0}"
    [[ -s "${SCRIPT_AUTH_FILE:-}" ]] &&
        script_auth_hash=$(tr -d '\r\n' < "$SCRIPT_AUTH_FILE")
    if ! jq -n --argjson old "$existing" --arg min "$minimum" \
        --arg auth_hash "$script_auth_hash" --argjson secret_issues "$node_issues" \
        '([$old.portability.issues[]? | select(.reason!="missing_secret")] + $secret_issues |
          unique | sort_by([.node_id,.reason])) as $issues |
         {schema_version:2,minimum_remote_control_version:$min,portability:{status:(if ($issues|length)>0 then "needs_setup" else "ready" end),issues:$issues},access:{script_password_hash:(if $auth_hash=="" then null else $auth_hash end)},templates:($old.templates // {})}' > "$tmp"; then
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
    if [[ -f "$STATE_MANIFEST" ]]; then
        existing=$(jq -ce 'select(type=="object")' "$STATE_MANIFEST" 2>/dev/null) || return 1
    fi
    tmp="${STATE_MANIFEST}.tmp.$$"
    jq --argjson issues "$issues" \
        '.schema_version=2 | .portability={status:(if ($issues|length)>0 then "needs_setup" else "ready" end),issues:$issues}' \
        <<< "$existing" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$tmp" && mv "$tmp" "$STATE_MANIFEST"
}

# Prints the declared issues array; fails on an unreadable manifest instead of
# letting an empty read replace the issue list.
_state_declared_issues() {
    local declared
    declared=$(_state_declared_portability) && [[ -n "$declared" ]] || return 1
    jq -ce '.issues | arrays' <<< "$declared"
}

state_portability_add_issue() {
    local node_id="${1:-}" reason="${2:-}" current updated
    [[ -n "$node_id" && -n "$reason" ]] || return 1
    current=$(_state_declared_issues) || return 1
    updated=$(jq -c --arg id "$node_id" --arg reason "$reason" \
        '. + [{node_id:$id,reason:$reason}] | unique | sort_by([.node_id,.reason])' <<< "$current") || return 1
    state_portability_set_issues "$updated"
}

state_portability_remove_issue() {
    local node_id="${1:-}" reason="${2:-}" current updated
    [[ -n "$node_id" && -n "$reason" ]] || return 1
    current=$(_state_declared_issues) || return 1
    updated=$(jq -c --arg id "$node_id" --arg reason "$reason" \
        'map(select(.node_id != $id or .reason != $reason))' <<< "$current") || return 1
    state_portability_set_issues "$updated"
}

state_portability_remove_node() {
    local node_id="${1:-}" current updated
    [[ -n "$node_id" ]] || return 1
    current=$(_state_declared_issues) || return 1
    updated=$(jq -c --arg id "$node_id" 'map(select(.node_id != $id))' <<< "$current") || return 1
    state_portability_set_issues "$updated"
}

# ─── Ошибки ядра ─────────────────────────────────────────────────────────────
# Core-функции сообщают о сбое через rc_fail: код (машиночитаемый литерал),
# сообщение (русский текст) и необязательный JSON-объект с подробностями.
RC_ERROR_CODE=""
RC_ERROR_MESSAGE=""
RC_ERROR_EXTRA=""

rc_error_reset() {
    RC_ERROR_CODE=""
    RC_ERROR_MESSAGE=""
    RC_ERROR_EXTRA=""
}

# RC_QUIET_DECISIONS=1 (serve, CLI с --json): коды-решения (*_required,
# plan_changed) не печатаются — их обрабатывает интерфейс. Переводы строк в
# сообщении сводятся к одному пробелу: журнал serve построчный, и чужой текст
# (имя, вывод сервера) не должен порождать отдельное событие.
rc_fail() {
    local message="${2:-}"
    message="${message//$'\r'/$'\n'}"
    while [[ "$message" == *$'\n\n'* ]]; do
        message="${message//$'\n\n'/$'\n'}"
    done
    RC_ERROR_CODE="${1:-failed}"
    RC_ERROR_MESSAGE="${message//$'\n'/ }"
    RC_ERROR_EXTRA="${3:-}"
    if [[ -n "$RC_ERROR_MESSAGE" ]]; then
        if [[ "${RC_QUIET_DECISIONS:-0}" != 1 ]] ||
           [[ "$RC_ERROR_CODE" != plan_changed && "$RC_ERROR_CODE" != *_required ]]; then
            warn "$RC_ERROR_MESSAGE"
        fi
    fi
    return 1
}

# ─── Подтверждение по плану ──────────────────────────────────────────────────
# Вход: CORE_PLAN_LINES (строки плана), CORE_PLAN_EXTRA (строка, влияющая на
# токен, но не на текст плана), CORE_PLAN_DATA (JSON-объект в EXTRA ошибки).
# Токен — первые 16 hex SHA-256 от RC_CONFIRM_SCOPE, строк плана и
# CORE_PLAN_EXTRA. Без --yes → confirmation_required; --yes с чужим токеном →
# plan_changed; иначе rc 0 и команда выполняется.
CORE_PLAN_LINES=()
CORE_PLAN_EXTRA=""
CORE_PLAN_DATA='{}'
RC_CONFIRM_YES=0
RC_CONFIRM_TOKEN=""
RC_CONFIRM_SCOPE=""

rc_plan_token() {
    local digest
    digest=$({
        printf '%s\n' "$RC_CONFIRM_SCOPE"
        (( ${#CORE_PLAN_LINES[@]} == 0 )) || printf '%s\n' "${CORE_PLAN_LINES[@]}"
        printf '%s' "$CORE_PLAN_EXTRA"
    } | openssl dgst -sha256) || return 1
    digest="${digest##* }"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${digest:0:16}"
}

rc_confirm_gate() {
    local token plan extra data="${CORE_PLAN_DATA:-}"
    if ! token=$(rc_plan_token); then
        rc_fail failed "Не удалось вычислить токен плана."
        return 1
    fi
    if (( ${#CORE_PLAN_LINES[@]} == 0 )); then
        plan='[]'
    else
        plan=$(printf '%s\n' "${CORE_PLAN_LINES[@]}" | jq -R . | jq -sc .) || plan='[]'
    fi
    printf '%s' "$data" | jq -e 'type == "object"' >/dev/null 2>&1 || data='{}'
    extra=$(jq -cn --argjson d "$data" --argjson p "$plan" --arg t "$token" \
        '$d + {plan:$p, plan_token:$t}') || extra='{}'
    if [[ "${RC_CONFIRM_YES:-0}" != 1 ]]; then
        rc_fail confirmation_required "Требуется подтверждение: повторите команду с --yes." "$extra"
        return 1
    fi
    if [[ -n "${RC_CONFIRM_TOKEN:-}" && "$RC_CONFIRM_TOKEN" != "$token" ]]; then
        rc_fail plan_changed "План изменился: проверьте его и подтвердите заново." "$extra"
        return 1
    fi
    return 0
}

# ─── Блокировка конфигурации ─────────────────────────────────────────────────
# mkdir-лок (flock нет на macOS). session — на весь процесс (GitHub-режим),
# mutation — на время одной записи. Повторный захват в том же процессе
# реентерабелен, чтобы вложенные state_action не блокировали сами себя.
_RC_LOCK_DEPTH=0
_RC_LOCK_SESSION=0

_rc_lock_dir() { printf '%s/.rc-lock' "$CONFIG_DIR"; }

_rc_lock_write_owner() {
    local dir="$1" kind="$2" label="$3" started
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    (umask 077; printf 'pid=%s\nkind=%s\nlabel=%s\nstarted=%s\n' "$$" "$kind" "$label" "$started" \
        > "$dir/owner.tmp" && mv -f "$dir/owner.tmp" "$dir/owner")
}

_rc_lock_owner_field() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] && { printf '%s' "${line#*=}"; return 0; }
    done < "$file"
    return 1
}

rc_lock_acquire() {
    local kind="${1:-mutation}" label="${2:-}" dir pid owner_kind owner_label deadline now stale wait_s
    dir=$(_rc_lock_dir)
    if (( _RC_LOCK_DEPTH > 0 )); then
        if [[ "$kind" == session ]]; then
            _rc_lock_write_owner "$dir" session "$label" || true
            _RC_LOCK_SESSION=1
        fi
        _RC_LOCK_DEPTH=$((_RC_LOCK_DEPTH + 1))
        return 0
    fi
    if [[ ! -d "$CONFIG_DIR" ]]; then
        (umask 077; mkdir -p "$CONFIG_DIR") || return 1
    fi
    now=$(date +%s)
    # Только целое число секунд: иначе значение окружения вычислялось бы как
    # арифметика (5s, 1+ — аварийное завершение; подстановки — выполнение кода).
    wait_s="${RC_LOCK_WAIT:-30}"
    [[ "$wait_s" =~ ^[0-9]{1,6}$ ]] || wait_s=30
    deadline=$((now + 10#$wait_s))
    while :; do
        if mkdir "$dir" 2>/dev/null; then
            if ! _rc_lock_write_owner "$dir" "$kind" "$label"; then
                rm -rf "$dir"
                rc_fail locked "Не удалось записать владельца блокировки конфигурации."
                return 1
            fi
            _RC_LOCK_DEPTH=1
            [[ "$kind" == session ]] && _RC_LOCK_SESSION=1
            return 0
        fi
        pid=$(_rc_lock_owner_field "$dir/owner" pid) || pid=""
        stale=false
        if [[ -z "$pid" ]]; then
            # Владелец ещё не записан: свежий каталог — чужой захват в процессе.
            [[ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]] && stale=true
        elif [[ "$pid" == "$$" ]] || ! kill -0 "$pid" 2>/dev/null; then
            # pid == $$ при нулевой глубине: лок остался от завершённого
            # подпроцесса этого же процесса ($$ в подоболочке — PID родителя).
            stale=true
        fi
        if [[ "$stale" == true ]]; then
            rm -rf "$dir.stale.$$" 2>/dev/null
            if mv "$dir" "$dir.stale.$$" 2>/dev/null; then
                rm -rf "$dir.stale.$$"
                continue
            fi
        fi
        owner_kind=$(_rc_lock_owner_field "$dir/owner" kind) || owner_kind=""
        owner_label=$(_rc_lock_owner_field "$dir/owner" label) || owner_label=""
        now=$(date +%s)
        if [[ "$owner_kind" == session ]] || (( now >= deadline )); then
            rc_fail locked "Конфигурация занята другим процессом (PID ${pid:-?}: ${owner_label:-?}). Повторите после его завершения."
            return 1
        fi
        sleep 0.2
    done
}

_rc_lock_remove_own() {
    local dir pid
    dir=$(_rc_lock_dir)
    [[ -d "$dir" ]] || return 0
    pid=$(_rc_lock_owner_field "$dir/owner" pid) || return 0
    [[ "$pid" == "$$" ]] && rm -rf "$dir"
    return 0
}

rc_lock_release() {
    (( _RC_LOCK_DEPTH > 0 )) || return 0
    _RC_LOCK_DEPTH=$((_RC_LOCK_DEPTH - 1))
    if (( _RC_LOCK_DEPTH == 0 && _RC_LOCK_SESSION == 0 )); then
        _rc_lock_remove_own
    fi
    return 0
}

rc_lock_release_all() {
    _rc_lock_remove_own
    _RC_LOCK_DEPTH=0
    _RC_LOCK_SESSION=0
}

rc_locked() {
    local label="$1" rc=0
    shift
    rc_lock_acquire mutation "$label" || return 1
    "$@" || rc=$?
    rc_lock_release
    return "$rc"
}

# state_action: лок на одну мутацию + транспорт-специфичное тело.
# _state_action_run в local-режиме — прямой вызов с локальной точкой
# восстановления; github-config.sh переопределяет его snapshot/flush-версией.
state_action() {
    rc_error_reset
    rc_lock_acquire mutation "$1" || return 1
    local rc=0
    _state_action_run "$@" || rc=$?
    rc_lock_release
    return "$rc"
}

# Изменение записано в конфигурацию: успех или partial (конфиг уже изменён,
# не удались только последующие шаги) — такое состояние тоже сохраняется.
_state_action_persists() {
    [[ "$1" -eq 0 || "${RC_ERROR_CODE:-}" == partial ]]
}

_state_action_run() {
    local label="$1" function="$2"
    shift 2
    [[ -n "$function" ]] || return 1
    declare -F "$function" >/dev/null 2>&1 || {
        warn "Неизвестное действие состояния: $function"
        return 1
    }
    "$function" "$@"
    local rc=$?
    if [[ "$CONFIG_SOURCE" == "local" ]] && _state_action_persists "$rc"; then
        if ! state_checkpoint >/dev/null; then
            warn "Не удалось сохранить локальную точку восстановления. Проверьте результат операции перед повтором."
            return 1
        fi
    fi
    return "$rc"
}