#!/bin/bash
# ─── SSH Hardening: ключ + отключение пароля + смена порта ───────────────────

_revoke_managed_remote_key_value() {
    local pubkey="${1:-}" old_onboarding rc
    [[ -n "$pubkey" ]] || return 1
    old_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
    SSH_ALLOW_PORTABLE_ONBOARDING=1
    ssh_run -- "if [ -f ~/.ssh/authorized_keys ]; then
        _essence_tmp=\$(mktemp ~/.ssh/authorized_keys.XXXXXX) &&
        awk -v key='$pubkey' '\$0 != key' ~/.ssh/authorized_keys > \"\$_essence_tmp\" &&
        cat \"\$_essence_tmp\" > ~/.ssh/authorized_keys &&
        rm -f \"\$_essence_tmp\"
    fi"
    rc=$?
    SSH_ALLOW_PORTABLE_ONBOARDING="$old_onboarding"
    return "$rc"
}

_revoke_managed_remote_key() {
    local node_id="${1:-}" pubfile pubkey
    [[ -n "$node_id" ]] || return 1
    pubfile="${SSH_IDENTITIES_DIR:-}/$node_id.pub"
    [[ -f "$pubfile" ]] || return 1
    pubkey=$(cat "$pubfile") || return 1
    _revoke_managed_remote_key_value "$pubkey"
}

_onboarding_restore_backups() {
    local known_existed="$1" known_backup="$2" manifest_backup="$3" restore_ok=true
    if [[ "$known_existed" == true ]]; then
        [[ -f "$known_backup" ]] && cp "$known_backup" "$SSH_KNOWN_HOSTS" || restore_ok=false
    else
        rm -f "$SSH_KNOWN_HOSTS" || restore_ok=false
    fi
    if [[ -n "$manifest_backup" ]]; then
        [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST" || restore_ok=false
    else
        rm -f "$STATE_MANIFEST" || restore_ok=false
    fi
    if [[ "$restore_ok" == true ]]; then
        rm -f "$known_backup" "$manifest_backup"
    else
        warn "Не удалось восстановить SSH-настройку. Резервные копии оставлены: $known_backup $manifest_backup"
        return 1
    fi
}

# Revokes keys installed during onboarding, then restores known_hosts and the
# manifest. A key whose revocation failed keeps its .pub for manual cleanup.
_onboarding_rollback() {
    local known_existed="$1" known_backup="$2" manifest_backup="$3" id node_name
    shift 3
    for id in "$@"; do
        node_name=$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .name')
        if [[ -n "$node_name" ]] && node_load_by_name "$node_name" &&
           _revoke_managed_remote_key "$id"; then
            rm -f "$SSH_IDENTITIES_DIR/$id" "$SSH_IDENTITIES_DIR/$id.pub"
        else
            rm -f "$SSH_IDENTITIES_DIR/$id"
            warn "Не удалось отозвать переносимый SSH-ключ ноды «${node_name:-$id}». Удалите его из authorized_keys вручную: $SSH_IDENTITIES_DIR/$id.pub"
        fi
    done
    _onboarding_restore_backups "$known_existed" "$known_backup" "$manifest_backup" || true
}

# Имена нод со входом по ключу без переносимого SSH-ключа (по строке).
_portable_onboarding_key_nodes() {
    jq_r '.nodes[] | select(.auth=="key" and ((.identity // "system")=="system")) | .name'
}

# onboarding_plan_lines PROVISION — только чтение (keyscan): дописывает в
# CORE_PLAN_LINES ноды, которым будет установлен новый переносимый SSH-ключ
# (PROVISION=yes), и для каждой ноды без записи в SSH_KNOWN_HOSTS — SHA256-
# отпечатки ключей сервера, которые будут закреплены (или что ключ прочитать
# не удалось: закрепление этой ноды не выполнится). Согласованные отпечатки
# дописываются в ONBOARDING_PLANNED_FPS строками «NODE_ID SHA256:…» (после
# вызова значение непустое) — закрепление пропускает только их. Вызывающий
# обнуляет ONBOARDING_PLANNED_FPS перед построением плана.
# PROVISION пусто при нодах без ключа → key_provisioning_required {"nodes":[…]}.
onboarding_plan_lines() {
    local provision="${1:-}" names id name ip port host rc fp line
    case "$provision" in
        yes|no) ;;
        "")
            names=$(_portable_onboarding_key_nodes | jq -R 'select(length > 0)' | jq -sc .) || names='[]'
            if [[ "$names" != "[]" ]]; then
                rc_fail key_provisioning_required "Нужно решить, создавать ли переносимый SSH-ключ для нод со входом по ключу." \
                    "$(jq -cn --argjson n "$names" '{nodes:$n}')"
                return 1
            fi
            provision=no
            ;;
        *) rc_fail usage "Решение о переносимых ключах: yes или no."; return 1 ;;
    esac
    ONBOARDING_PLANNED_FPS+="# plan"$'\n'
    if [[ "$provision" == yes ]]; then
        names=$(_portable_onboarding_key_nodes | awk 'NF { printf "%s%s", sep, $0; sep = ", " }')
        [[ -z "$names" ]] || CORE_PLAN_LINES+=("Будет создан переносимый SSH-ключ: $names")
    fi
    while IFS=$'\t' read -r id name ip port <&3; do
        [[ -n "$id" ]] || continue
        host="$ip"
        [[ "$port" != 22 ]] && host="[$ip]:$port"
        if [[ -n "${SSH_KNOWN_HOSTS:-}" && -f "$SSH_KNOWN_HOSTS" ]] &&
           ssh-keygen -F "$host" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
            continue
        fi
        # Те же проверки, что у онбординга: без пароля ключ не закрепляется,
        # повреждённая запись (логин, адрес) не сканируется.
        rc=0
        ( node_load_by_name "$name" ) >/dev/null 2>&1 || rc=$?
        if [[ $rc -eq 2 ]]; then
            continue
        elif [[ $rc -ne 0 ]]; then
            ONBOARDING_PLANNED_FPS+="$id -"$'\n'
            CORE_PLAN_LINES+=("Нода $name: запись повреждена, SSH-настройка не выполнится.")
            continue
        fi
        if ! _node_hostkey_scan "$ip" "$port"; then
            ONBOARDING_PLANNED_FPS+="$id -"$'\n'
            CORE_PLAN_LINES+=("Ключ сервера $name ($ip:$port) прочитать не удалось: закрепление не выполнится.")
            continue
        fi
        rm -f "$NODE_HOSTKEY_SCAN"
        NODE_HOSTKEY_SCAN=""
        line=""
        for fp in "${NODE_HOSTKEY_FPS[@]}"; do
            line+="${line:+, }$fp"
            ONBOARDING_PLANNED_FPS+="$id $fp"$'\n'
        done
        CORE_PLAN_LINES+=("Ключ сервера $name ($ip:$port) будет закреплён: $line")
    done 3< <(jq_r '.nodes[] | [.id, .name, .ip, (.port | tostring)] | @tsv')
}

# _onboarding_known_key_agreed ID — записи загруженной ноды ID в SSH_KNOWN_HOSTS
# согласованы с планом onboarding_plan_lines: плана нет, нода была известна при
# его построении или каждый её отпечаток показан в плане. Иначе (ключ записан
# при входе accept-new и не совпал, ключ при плане не прочитан) — rc 1.
_onboarding_known_key_agreed() {
    local node="${1:-}" id fp host known seen=false
    local -a planned=()
    [[ -n "${ONBOARDING_PLANNED_FPS:-}" ]] || return 0
    while read -r id fp; do
        [[ -n "$id" && "$id" == "$node" ]] || continue
        seen=true
        [[ "$fp" == SHA256:?* ]] && planned+=("$fp")
    done <<< "$ONBOARDING_PLANNED_FPS"
    [[ "$seen" == true ]] || return 0
    [[ ${#planned[@]} -gt 0 ]] || return 1
    host="$SERVER_IP"
    [[ "${SERVER_PORT:-22}" != 22 ]] && host="[$SERVER_IP]:$SERVER_PORT"
    known=$(_node_hostkey_known_fps "$host")
    [[ -n "$known" ]] || return 1
    while IFS= read -r fp; do
        [[ " ${planned[*]} " == *" $fp "* ]] || return 1
    done <<< "$known"
}

# _github_initial_portable_onboarding PROVISION ON_FAILURE — переносимые SSH-ключи
# и ключи серверов для всех нод источника GitHub.
# PROVISION=yes|no — создавать ли переносимый ключ нодам без него; пусто при
# таких нодах → key_provisioning_required {"nodes":[…]}.
# ON_FAILURE=rollback — откат всех изменений и onboarding_failed
# {"node","step":"provision|pin","rolled_back":true}; defer — проблемная нода
# получает отметку отложенной настройки, остальные продолжаются.
# Результат: ONBOARDING_INSTALLED — имена нод с новым переносимым ключом.
_github_initial_portable_onboarding() {
    local provision="${1:-}" on_failure="${2:-rollback}" names
    ONBOARDING_INSTALLED=() ONBOARDING_FAIL_NODE="" ONBOARDING_FAIL_STEP=""
    [[ "${CONFIG_SOURCE:-local}" == "github" ]] || return 0
    case "$on_failure" in
        rollback|defer) ;;
        *) rc_fail usage "Режим при сбое SSH-настройки: rollback или defer."; return 1 ;;
    esac
    case "$provision" in
        yes|no) ;;
        "")
            names=$(_portable_onboarding_key_nodes | jq -R 'select(length > 0)' | jq -sc .) || names='[]'
            if [[ "$names" != "[]" ]]; then
                rc_fail key_provisioning_required "Нужно решить, создавать ли переносимый SSH-ключ для нод со входом по ключу." \
                    "$(jq -cn --argjson n "$names" '{nodes:$n}')"
                return 1
            fi
            provision=no
            ;;
        *) rc_fail usage "Решение о переносимых ключах: yes или no."; return 1 ;;
    esac
    local known_backup="" known_existed=false manifest_backup="" id
    local -a installed_ids=()
    if [[ -f "${SSH_KNOWN_HOSTS:-}" ]]; then
        known_existed=true
        known_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.known-hosts.XXXXXX") || return 1
        cp "$SSH_KNOWN_HOSTS" "$known_backup" || { rm -f "$known_backup"; return 1; }
    fi
    if [[ -f "${STATE_MANIFEST:-}" ]]; then
        manifest_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.manifest.XXXXXX") || {
            rm -f "$known_backup"
            return 1
        }
        cp "$STATE_MANIFEST" "$manifest_backup" || {
            rm -f "$known_backup" "$manifest_backup"
            return 1
        }
    fi
    # Every failure after the backups exist goes through the same rollback;
    # the steps append to installed_ids in this scope.
    if ! _github_portable_onboarding_steps "$provision" "$on_failure"; then
        _onboarding_rollback "$known_existed" "$known_backup" "$manifest_backup" "${installed_ids[@]}"
        if [[ -n "$ONBOARDING_FAIL_STEP" ]]; then
            rc_fail onboarding_failed "Не удалось настроить SSH для ноды «${ONBOARDING_FAIL_NODE}». Изменения отменены." \
                "$(jq -cn --arg n "$ONBOARDING_FAIL_NODE" --arg s "$ONBOARDING_FAIL_STEP" \
                    '{node:$n, step:$s, rolled_back:true}')"
        fi
        return 1
    fi
    for id in "${installed_ids[@]}"; do
        ONBOARDING_INSTALLED+=("$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .name')")
    done
    rm -f "$known_backup" "$manifest_backup"
    return 0
}

_github_portable_onboarding_steps() {
    local provision="$1" on_failure="$2" id name
    local -a key_ids=() node_rows=()
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] && node_rows+=("$id"$'\t'"$name")
        if [[ -n "$id" ]] && [[ "$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | (.auth=="key" and ((.identity // "system")=="system"))')" == true ]]; then
            key_ids+=("$id")
        fi
    done < <(jq_r '.nodes[] | [.id,.name] | @tsv')
    for id in "${key_ids[@]}"; do
        if [[ "$provision" != yes ]]; then
            state_portability_add_issue "$id" missing_identity || return 1
            continue
        fi
        name=$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .name')
        node_load_by_name "$name" || return 1
        local previous_defer="${PORTABLE_IDENTITY_DEFER_CONFIG:-0}"
        local previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
        PORTABLE_IDENTITY_DEFER_CONFIG=1
        SSH_ALLOW_PORTABLE_ONBOARDING=1
        _provision_portable_identity "$id"
        local provision_rc=$?
        PORTABLE_IDENTITY_DEFER_CONFIG="$previous_defer"
        SSH_ALLOW_PORTABLE_ONBOARDING="$previous_onboarding"
        if [[ $provision_rc -eq 0 ]]; then
            installed_ids+=("$id")
        elif [[ "$on_failure" == defer ]]; then
            warn "Переносимый SSH-ключ ноды «${name}» не создан; SSH-настройка отложена."
            state_portability_add_issue "$id" missing_identity || return 1
        else
            ONBOARDING_FAIL_NODE="$name" ONBOARDING_FAIL_STEP=provision
            return 1
        fi
    done
    for name in "${node_rows[@]}"; do
        id="${name%%$'\t'*}"
        name="${name#*$'\t'}"
        local load_rc=0
        node_load_by_name "$name" || load_rc=$?
        if [[ $load_rc -eq 2 ]]; then
            state_portability_add_issue "$id" missing_secret || return 1
            if (
                SERVER_IP=$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .ip') || exit 1
                SERVER_PORT=$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .port') || exit 1
                _ssh_known_host_present
            ); then
                state_portability_remove_issue "$id" missing_host_key || return 1
            else
                state_portability_add_issue "$id" missing_host_key || return 1
            fi
            continue
        elif [[ $load_rc -ne 0 ]]; then
            return 1
        fi
        if [[ "$id" == "" ]]; then continue; fi
        NODE_ID="$id"
        if [[ ${#installed_ids[@]} -gt 0 ]] && [[ " ${installed_ids[*]} " == *" $id "* ]]; then NODE_IDENTITY="$id"; fi
        local pin_rc=0 pin_host
        if _ssh_known_host_present; then
            # Запись могла появиться при входе для установки ключа (accept-new):
            # по согласованному плану она обязана совпасть с показанными отпечатками.
            if _onboarding_known_key_agreed "$id"; then
                state_portability_remove_issue "$id" missing_host_key || return 1
                continue
            fi
            pin_host="$SERVER_IP"
            [[ "${SERVER_PORT:-22}" != 22 ]] && pin_host="[$SERVER_IP]:$SERVER_PORT"
            ssh-keygen -R "$pin_host" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || return 1
            warn "Ключ сервера ноды '${NODE_NAME}' не совпадает с согласованным в плане."
            pin_rc=1
        else
            local previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
            SSH_ALLOW_PORTABLE_ONBOARDING=1
            _ssh_pin_host_key
            pin_rc=$?
            SSH_ALLOW_PORTABLE_ONBOARDING="$previous_onboarding"
        fi
        if [[ $pin_rc -eq 0 ]]; then
            state_portability_remove_issue "$id" missing_host_key || return 1
        elif [[ "$on_failure" == defer ]]; then
            warn "Не удалось закрепить SSH-ключ ноды '${NODE_NAME}'; SSH-настройка отложена."
            state_portability_add_issue "$id" missing_host_key || return 1
        else
            warn "Не удалось закрепить SSH-ключ ноды '${NODE_NAME}'."
            ONBOARDING_FAIL_NODE="$name" ONBOARDING_FAIL_STEP=pin
            return 1
        fi
    done
    if [[ ${#installed_ids[@]} -gt 0 ]]; then
        local ids_json
        ids_json=$(printf '%s\n' "${installed_ids[@]}" | jq -R . | jq -s .) || return 1
        # The candidate must see issues matching its newly installed identities.
        # The caller restores the original manifest if either step fails.
        for id in "${installed_ids[@]}"; do
            state_portability_remove_issue "$id" missing_identity || return 1
        done
        jq_w --argjson ids "$ids_json" \
            '.nodes |= map(.id as $id | if ($ids | index($id)) then .identity=$id else . end)' ||
            return 1
    fi
    return 0
}

# core_node_setup_ssh PROVISION ON_FAILURE — завершить отложенную SSH-настройку
# нод (только GitHub). Результат: SETUP_SSH_READY (true|false).
core_node_setup_ssh() {
    local provision="${1:-}" on_failure="${2:-rollback}" status
    SETUP_SSH_READY=false
    if [[ "${CONFIG_SOURCE:-local}" != github ]]; then
        rc_fail invalid "Отложенная SSH-настройка доступна только для источника GitHub."
        return 1
    fi
    if ! state_actionable_ssh_setup_pending; then
        rc_fail nothing_pending "Отложенной SSH-настройки нод нет."
        return 1
    fi
    if ! _github_initial_portable_onboarding "$provision" "$on_failure"; then
        [[ -n "$RC_ERROR_CODE" ]] || rc_fail failed "Не удалось завершить SSH-настройку нод."
        return 1
    fi
    if ! status=$(state_validate true 2>/dev/null); then
        rc_fail failed "Не удалось проверить SSH-настройку нод для синхронизации через GitHub."
        return 1
    fi
    if [[ "$status" == ready ]]; then
        SETUP_SSH_READY=true
        success "Отложенная SSH-настройка нод завершена: SSH-ключи и ключи серверов готовы для синхронизации через GitHub."
    elif state_actionable_ssh_setup_pending; then
        warn "Для части нод SSH-настройка всё ещё отложена. Повторите node setup-ssh позже."
    else
        warn "SSH-ключи настроены, но другим нодам требуются защищённые данные для входа."
    fi
}

# _portable_identity_abort NODE_ID TMP_DIR PUBKEY — откат после начала замены
# ключа: отзывает новый ключ на сервере и возвращает прежнюю пару ключей ноды
# из TMP_DIR/previous (если её не было — удаляет новую). При сбое возврата
# TMP_DIR с копией остаётся для ручного восстановления.
_portable_identity_abort() {
    local node_id="$1" tmp_dir="$2" pubkey="$3" file
    _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
    if ! rm -f "$SSH_IDENTITIES_DIR/$node_id" "$SSH_IDENTITIES_DIR/$node_id.pub"; then
        warn "Не удалось удалить новый SSH-ключ. Прежний ключ сохранён в $tmp_dir/previous"
        return 1
    fi
    for file in "$node_id" "$node_id.pub"; do
        [[ -e "$tmp_dir/previous/$file" ]] || continue
        if ! cp -p "$tmp_dir/previous/$file" "$SSH_IDENTITIES_DIR/$file"; then
            warn "Не удалось вернуть прежний SSH-ключ ноды. Резервная копия: $tmp_dir/previous"
            return 1
        fi
    done
    rm -rf "$tmp_dir"
}

# _provision_portable_identity NODE_ID — новый переносимый ключ ноды. Прежняя
# пара ключей (повторное усиление) хранится в резервной копии до фиксации и
# возвращается при любом сбое; после фиксации её открытый ключ — в
# PORTABLE_IDENTITY_REPLACED_PUBKEY (вызывающий отзывает его на сервере).
_provision_portable_identity() {
    local node_id="${1:-}"
    PORTABLE_IDENTITY_REPLACED_PUBKEY=""
    [[ -n "$node_id" ]] || { warn "Не найден стабильный идентификатор ноды."; return 1; }
    local runtime_root="${CONFIG_DIR:-${TMPDIR:-/tmp}}"
    local tmp_dir remote_installed=false
    tmp_dir=$(umask 077; mktemp -d "$runtime_root/.identity.XXXXXX") || {
        warn "Не удалось создать временную директорию для SSH-ключа."
        return 1
    }
    local private="$tmp_dir/$node_id" public="$tmp_dir/$node_id.pub"
    if ! ssh-keygen -t ed25519 -f "$private" -N "" -C "essence:${node_id}" -q; then
        rm -rf "$tmp_dir"
        warn "Не удалось сгенерировать переносимый SSH-ключ."
        return 1
    fi

    local pubkey
    pubkey=$(cat "$public") || { rm -rf "$tmp_dir"; return 1; }
    info "Копируем открытый переносимый SSH-ключ на сервер..."
    local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
    if ! ssh_run -- "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF '$pubkey' ~/.ssh/authorized_keys || printf '%s\\n' '$pubkey' >> ~/.ssh/authorized_keys; }"; then
        SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
        rm -rf "$tmp_dir"
        warn "Не удалось скопировать переносимый SSH-ключ на сервер."
        return 1
    fi
    remote_installed=true
    SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"

    local verify_options=(-o ConnectTimeout=10 -o PasswordAuthentication=no
        -o BatchMode=yes -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        # During onboarding accept-new is scoped to this managed known_hosts
        # and to a host without a pinned key; normal GitHub sessions remain
        # strict in ssh.sh.
        local verify_strict=accept-new
        _ssh_known_host_present && verify_strict=yes
        verify_options=(-o "StrictHostKeyChecking=$verify_strict"
            -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
            -o ConnectTimeout=10 -o PasswordAuthentication=no
            -o BatchMode=yes -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    else
        verify_options=(-o StrictHostKeyChecking=accept-new
            -o ConnectTimeout=10 -o PasswordAuthentication=no
            -o BatchMode=yes -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    fi
    info "Проверяем авторизацию по переносимому SSH-ключу..."
    if ! run_with_timeout 10 ${RC_SERVE_TIMEOUT_FLAG:+"$RC_SERVE_TIMEOUT_FLAG"} ssh "${verify_options[@]}" \
        -- "${SERVER_USER}@${SERVER_IP}" "echo ok" &>/dev/null; then
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -rf "$tmp_dir"
        warn "Авторизация по переносимому SSH-ключу не работает."
        return 1
    fi
    mkdir -p "$SSH_IDENTITIES_DIR" && chmod 700 "$SSH_IDENTITIES_DIR" || {
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -rf "$tmp_dir"
        return 1;
    }
    # Копия прежней пары ключей делается до замены: сбой ниже её возвращает.
    local previous_identity=""
    if [[ -e "$SSH_IDENTITIES_DIR/$node_id" || -e "$SSH_IDENTITIES_DIR/$node_id.pub" ]]; then
        if ! mkdir "$tmp_dir/previous" ||
           { [[ -e "$SSH_IDENTITIES_DIR/$node_id" ]] &&
             ! cp -p "$SSH_IDENTITIES_DIR/$node_id" "$tmp_dir/previous/"; } ||
           { [[ -e "$SSH_IDENTITIES_DIR/$node_id.pub" ]] &&
             ! cp -p "$SSH_IDENTITIES_DIR/$node_id.pub" "$tmp_dir/previous/"; }; then
            [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
            rm -rf "$tmp_dir"
            warn "Не удалось сохранить резервную копию прежнего SSH-ключа."
            return 1
        fi
    fi
    if [[ "${PORTABLE_IDENTITY_DEFER_CONFIG:-0}" != "1" ]]; then
        previous_identity=$(jq_r --arg id "$node_id" '.nodes[] | select(.id==$id) | .identity // empty' 2>/dev/null) ||
            previous_identity=""
    fi
    if ! mv "$private" "$SSH_IDENTITIES_DIR/$node_id" ||
       ! mv "$public" "$SSH_IDENTITIES_DIR/$node_id.pub" ||
       ! chmod 600 "$SSH_IDENTITIES_DIR/$node_id" ||
       ! chmod 644 "$SSH_IDENTITIES_DIR/$node_id.pub"; then
        _portable_identity_abort "$node_id" "$tmp_dir" "$pubkey" || true
        warn "Не удалось установить переносимый SSH-ключ в локальное хранилище."
        return 1
    fi

    if [[ "${PORTABLE_IDENTITY_DEFER_CONFIG:-0}" != "1" ]] &&
       ! jq_w --arg id "$node_id" --arg identity "$node_id" \
        '.nodes |= map(if .id==$id then .identity=$identity else . end)'; then
        _portable_identity_abort "$node_id" "$tmp_dir" "$pubkey" || true
        warn "Не удалось сохранить ссылку на переносимый SSH-ключ."
        return 1
    fi
    NODE_IDENTITY="$node_id"
    if [[ "${PORTABLE_IDENTITY_DEFER_CONFIG:-0}" != "1" ]]; then
        if ! state_checkpoint; then
            if [[ -d "$tmp_dir/previous" && "$previous_identity" == "$node_id" ]]; then
                # Конфигурация уже ссылалась на этот ключ: возврат прежней пары
                # полностью отменяет замену.
                _portable_identity_abort "$node_id" "$tmp_dir" "$pubkey" || true
                warn "Не удалось сохранить точку восстановления; прежний SSH-ключ возвращён."
                return 1
            fi
            rm -rf "$tmp_dir"
            warn "SSH-ключ сохранён, но точку восстановления сохранить не удалось; дальнейшая настройка остановлена."
            return 1
        fi
        if [[ "$previous_identity" == "$node_id" && -f "$tmp_dir/previous/$node_id.pub" ]]; then
            PORTABLE_IDENTITY_REPLACED_PUBKEY=$(cat "$tmp_dir/previous/$node_id.pub") ||
                PORTABLE_IDENTITY_REPLACED_PUBKEY=""
        fi
    fi
    rm -rf "$tmp_dir"
    success "Переносимый SSH-ключ установлен"
}

_harden_setup_key() {
    _provision_portable_identity "${NODE_ID:-}" || return 1
}

# Hardening pins the just-verified identity with IdentitiesOnly/BatchMode even
# for local nodes, whose normal SSH sessions also allow agent/system keys.
_harden_ssh_run() {
    local SERVER_AUTH=key SERVER_PASS=""
    ssh_run -i "$SSH_IDENTITIES_DIR/$NODE_IDENTITY" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no -- "$@"
}

_harden_disable_password() {
    info "Отключаем вход по паролю на сервере..."
    _harden_ssh_run "
        sed -i '/^#\\?PubkeyAuthentication/d' /etc/ssh/sshd_config &&
        sed -i '/^#\\?PasswordAuthentication/d' /etc/ssh/sshd_config &&
        sed -i '/^#\\?ChallengeResponseAuthentication/d' /etc/ssh/sshd_config &&
        echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config &&
        echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config &&
        echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config
    " || { warn "Не удалось изменить sshd_config."; return 1; }
    success "Вход по паролю отключён (ожидает перезапуска SSH-сервиса)"
}

_harden_restore_password() {
    _harden_ssh_run "
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config &&
        sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config &&
        echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config &&
        sshd -t &&
        (systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null)
    " 2>/dev/null
}

# Загружает ноду NAME для усиления защиты: not_found / missing_secret / invalid /
# needs_setup (отложенная SSH-настройка GitHub — до первого удалённого шага).
_harden_load_node() {
    local name="${1:-}" rc=0
    if ! _node_exists "$name"; then
        rc_fail not_found "Нода '${name}' не найдена."
        return 1
    fi
    node_load_by_name "$name" >/dev/null || rc=$?
    case "$rc" in
        0) ssh_require_portable; return ;;
        2) rc_fail missing_secret "Пароль SSH ноды '${name}' недоступен." ;;
        *) rc_fail invalid "Запись ноды '${name}' повреждена или неполна." ;;
    esac
    return 1
}

# Состояние порта на загруженной ноде: free | occupied; rc 1 — SSH-сбой.
_harden_port_state() {
    local state
    state=$(ssh_run -- "ss -tlnp > /dev/null || exit 1; if ss -tlnp | grep -q ':${1}\b'; then echo occupied; else echo free; fi" 2>/dev/null) || return 1
    state="${state%$'\r'}"
    [[ "$state" == free || "$state" == occupied ]] || return 1
    printf '%s' "$state"
}

# core_harden_pick_port NAME [PORT] → HARDEN_NEW_PORT. Без PORT — случайный
# свободный порт; неверный PORT — invalid; занятый — port_in_use {"port"}.
core_harden_pick_port() {
    local name="${1:-}" port="${2:-}" state attempts=0
    HARDEN_NEW_PORT=""
    _harden_load_node "$name" || return 1
    if [[ -n "$port" ]]; then
        if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
            rc_fail invalid "Порт должен быть числом от 1 до 65535."
            return 1
        fi
        if ! state=$(_harden_port_state "$port"); then
            rc_fail remote_failed "Не удалось проверить занятость SSH-порта на ноде."
            return 1
        fi
        if [[ "$state" != free ]]; then
            rc_fail port_in_use "Порт ${port} на ноде занят." "$(jq -cn --argjson p "$port" '{port:$p}')"
            return 1
        fi
        HARDEN_NEW_PORT="$port"
        return 0
    fi
    while (( attempts < 5 )); do
        port=$(( RANDOM % 16384 + 49152 ))
        if ! state=$(_harden_port_state "$port"); then
            rc_fail remote_failed "Не удалось проверить занятость SSH-порта на ноде."
            return 1
        fi
        if [[ "$state" == free ]]; then
            HARDEN_NEW_PORT="$port"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    rc_fail failed "Не удалось найти свободный порт."
}

# core_node_harden_plan — строки плана для загруженной ноды и HARDEN_NEW_PORT.
core_node_harden_plan() {
    CORE_PLAN_LINES=("Нода: $NODE_NAME  $SERVER_IP:$SERVER_PORT" "Пользователь: $SERVER_USER"
        "Ключ: $SSH_IDENTITIES_DIR/$NODE_ID" "Порт: $SERVER_PORT → $HARDEN_NEW_PORT"
        "Вход по паролю будет отключён."
        "Будет установлен SSH-ключ и изменены правила firewall для SSH."
        "При сбое может потребоваться консоль провайдера.")
    if [[ "$SERVER_AUTH" == key && "$SERVER_PORT" != 22 ]]; then
        CORE_PLAN_LINES+=("Усиление защиты SSH уже выполнено; настройки будут изменены повторно.")
    fi
    if [[ "${NODE_IDENTITY:-}" == "$NODE_ID" && -f "$SSH_IDENTITIES_DIR/$NODE_ID.pub" ]]; then
        CORE_PLAN_LINES+=("Прежний SSH-ключ ноды будет заменён новым и отозван на сервере.")
    fi
    CORE_PLAN_DATA=$(jq -cn --argjson p "$HARDEN_NEW_PORT" '{port:$p}')
}

_harden_rollback_port() {
    local old_port="$1" new_port="$2" rollback_ok=false
    local rollback_cmd="
        sed -i '/^Port /d' /etc/ssh/sshd_config &&
        echo 'Port ${old_port}' >> /etc/ssh/sshd_config || exit 1
        if command -v ufw >/dev/null 2>&1; then
            ufw allow ${old_port}/tcp >/dev/null 2>&1 &&
            ufw delete allow ${new_port}/tcp >/dev/null 2>&1 || exit 1
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=${old_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --permanent --remove-port=${new_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --reload >/dev/null 2>&1 || exit 1
        fi
        sshd -t &&
        systemctl daemon-reload &&
        (systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null)
    "
    SERVER_PORT="$old_port"
    if _harden_ssh_run "$rollback_cmd" 2>/dev/null; then
        rollback_ok=true
    else
        SERVER_PORT="$new_port"
        _harden_ssh_run "$rollback_cmd" 2>/dev/null && rollback_ok=true
    fi
    SERVER_PORT="$old_port"
    local verify
    if [[ "$rollback_ok" == true ]] &&
       verify=$(_harden_ssh_run "echo ok" 2>/dev/null) &&
       [[ "${verify%$'\r'}" == ok ]]; then
        warn "SSH-порт возвращён на $old_port. Усиление защиты SSH прервано."
        return 0
    fi
    warn "Не удалось подтвердить возврат SSH-порта. Проверьте порты $old_port и $new_port через консоль провайдера."
    return 1
}

# GitHub sessions check host keys strictly against the managed known_hosts and
# portable state requires an entry for the node's own port. Re-use only entries
# already present for the current port, keeping @cert-authority/@revoked markers,
# so verification stays strict.
_harden_trust_new_port() {
    local old_port="$1" new_port="$2" old_host="$SERVER_IP" new_host="$SERVER_IP" entries
    [[ "$old_port" != 22 ]] && old_host="[$SERVER_IP]:$old_port"
    [[ "$new_port" != 22 ]] && new_host="[$SERVER_IP]:$new_port"
    [[ -n "${SSH_KNOWN_HOSTS:-}" && -f "$SSH_KNOWN_HOSTS" ]] || return 1
    ssh-keygen -F "$new_host" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 && return 0
    entries=$(ssh-keygen -F "$old_host" -f "$SSH_KNOWN_HOSTS" 2>/dev/null |
        awk -v host="$new_host" '/^#/ { next }
            $1 ~ /^@/ { if (NF >= 4) print $1, host, $3, $4; next }
            NF >= 3 { print host, $2, $3 }')
    [[ -n "$entries" ]] || return 1
    printf '%s\n' "$entries" >> "$SSH_KNOWN_HOSTS"
}

_harden_restore_known_hosts() {
    local backup="$1"
    [[ -n "$backup" ]] || return 0
    cat "$backup" > "$SSH_KNOWN_HOSTS" ||
        warn "Не удалось вернуть прежний список ключей серверов: $SSH_KNOWN_HOSTS"
    rm -f "$backup"
}

# _harden_change_port PORT — сбой выставляет HARDEN_PORT_STAGE (port | verify |
# save) и HARDEN_PORT_ROLLED_BACK (порт подтверждённо возвращён).
_harden_change_port() {
    local old_port="$SERVER_PORT" new_port="$1" known_backup=""
    HARDEN_PORT_STAGE="" HARDEN_PORT_ROLLED_BACK=false
    if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
        if ! known_backup=$(mktemp) || ! cp "$SSH_KNOWN_HOSTS" "$known_backup"; then
            rm -f "$known_backup"
            warn "Не удалось сохранить копию списка ключей серверов."
            HARDEN_PORT_STAGE=port HARDEN_PORT_ROLLED_BACK=true
            return 1
        fi
        if ! _harden_trust_new_port "$old_port" "$new_port"; then
            _harden_restore_known_hosts "$known_backup"
            warn "Не удалось подготовить ключ сервера для нового SSH-порта."
            HARDEN_PORT_STAGE=port HARDEN_PORT_ROLLED_BACK=true
            return 1
        fi
    fi
    info "Меняем SSH-порт на ${new_port}..."
    if ! _harden_ssh_run "
        sed -i '/^#\\?Port /d' /etc/ssh/sshd_config &&
        echo 'Port ${new_port}' >> /etc/ssh/sshd_config || exit 1
        if command -v ufw >/dev/null 2>&1; then
            ufw allow ${new_port}/tcp >/dev/null 2>&1 &&
            ufw delete allow OpenSSH >/dev/null 2>&1 &&
            ufw delete allow 22/tcp >/dev/null 2>&1 &&
            ufw delete allow ${old_port}/tcp >/dev/null 2>&1 || exit 1
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=${new_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 &&
            firewall-cmd --permanent --remove-port=${old_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --reload >/dev/null 2>&1 || exit 1
        elif command -v firewall-cmd >/dev/null 2>&1 &&
             systemctl is-enabled firewalld >/dev/null 2>&1; then
            # Остановленный, но включённый firewalld после перезагрузки поднимет
            # старую permanent-зону и закроет новый порт: порт не меняем.
            exit 1
        fi
        sshd -t &&
        systemctl daemon-reload &&
        (systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null)
    "; then
        warn "Не удалось применить новый SSH-порт."
        HARDEN_PORT_STAGE=port
        _harden_rollback_port "$old_port" "$new_port" && HARDEN_PORT_ROLLED_BACK=true
        _harden_restore_known_hosts "$known_backup"
        return 1
    fi
    sleep 3
    local verify
    SERVER_PORT="$new_port"
    if ! verify=$(_harden_ssh_run "echo ok" 2>/dev/null) || [[ "${verify%$'\r'}" != ok ]]; then
        SERVER_PORT="$old_port"
        warn "Не удалось подключиться по новому порту."
        HARDEN_PORT_STAGE=verify
        _harden_rollback_port "$old_port" "$new_port" && HARDEN_PORT_ROLLED_BACK=true
        _harden_restore_known_hosts "$known_backup"
        return 1
    fi
    if ! jq_w --arg id "$NODE_ID" --argjson p "$new_port" --arg identity "$NODE_ID" \
        '.nodes |= map(if .id==$id then .port=$p | .auth="key" | .identity=$identity | .secret_id=null else . end)'; then
        SERVER_PORT="$old_port"
        warn "Не удалось сохранить параметры усиления защиты SSH."
        HARDEN_PORT_STAGE=save
        _harden_rollback_port "$old_port" "$new_port" && HARDEN_PORT_ROLLED_BACK=true
        _harden_restore_known_hosts "$known_backup"
        return 1
    fi
    rm -f "$known_backup"
    SERVER_AUTH=key; SERVER_PASS=""
    success "Подключение по порту ${new_port} работает"
    return 0
}

_harden_fail() {
    rc_fail hardening_failed "Усиление защиты SSH не выполнено (этап: $1)." \
        "$(jq -cn --arg s "$1" --argjson r "$2" --argjson c "$3" \
            '{stage:$s, rolled_back:$r, console_required:$c}')"
}

# core_node_harden NAME PORT — переносимый ключ, отключение пароля, смена порта.
# Сбой → hardening_failed {"stage","rolled_back","console_required"}.
core_node_harden() {
    local name="${1:-}" port="${2:-}" rolled_back restore_password=true old_fp
    _harden_load_node "$name" || return 1
    if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        rc_fail invalid "Порт должен быть числом от 1 до 65535."
        return 1
    fi
    # Откат возвращает вход по паролю, только если он был включён: у ноды со
    # входом по ключу (повторное усиление) пароль уже отключён.
    [[ "$SERVER_AUTH" == key ]] && restore_password=false
    if ! _harden_setup_key; then
        _harden_fail key true false
        return 1
    fi
    if [[ -n "${PORTABLE_IDENTITY_REPLACED_PUBKEY:-}" ]]; then
        info "Отзываем прежний SSH-ключ ноды на сервере..."
        if ! _revoke_managed_remote_key_value "$PORTABLE_IDENTITY_REPLACED_PUBKEY" >/dev/null 2>&1; then
            old_fp=$(printf '%s\n' "$PORTABLE_IDENTITY_REPLACED_PUBKEY" | ssh-keygen -E sha256 -lf - 2>/dev/null |
                awk '{print $2}') || old_fp=""
            warn "Прежний SSH-ключ ноды не отозван на сервере. Удалите его из ~/.ssh/authorized_keys вручную${old_fp:+ (отпечаток $old_fp)}."
        fi
    fi
    if ! _harden_disable_password; then
        rolled_back=true
        if [[ "$restore_password" == true ]]; then
            warn "Восстанавливаем вход по паролю..."
            _harden_restore_password || {
                rolled_back=false
                warn "Не удалось восстановить вход по паролю. Используйте консоль провайдера."
            }
        fi
        _harden_fail disable_password "$rolled_back" "$([[ "$rolled_back" == true ]] && echo false || echo true)"
        return 1
    fi
    if ! _harden_change_port "$port"; then
        rolled_back="$HARDEN_PORT_ROLLED_BACK"
        if [[ "$restore_password" == true ]]; then
            warn "Восстанавливаем вход по паролю..."
            _harden_restore_password || {
                rolled_back=false
                warn "Не удалось восстановить вход по паролю. Используйте консоль провайдера."
            }
        fi
        _harden_fail "${HARDEN_PORT_STAGE:-port}" "$rolled_back" "$([[ "$rolled_back" == true ]] && echo false || echo true)"
        return 1
    fi
    if ! node_secret_delete "$NODE_ID"; then
        warn "Порт и SSH-ключ сохранены, но старый пароль не удалось удалить из локального состояния."
        _harden_fail secret_delete false false
        return 1
    fi
    success "Усиление защиты SSH завершено!"
    info "Ключ: $SSH_IDENTITIES_DIR/$NODE_ID"
    info "Порт: $SERVER_PORT; вход по паролю отключён."
    return 0
}
