#!/bin/bash
# ─── Команды нод: node, conn, awg, telegram ──────────────────────────────────
# Спецификации, справка и обработчики по существительным (см. modules/cli.sh).

# ─── node ────────────────────────────────────────────────────────────────────

cli_spec_node() {
    case "$1" in
        list)           printf '' ;;
        show)           printf 'name=' ;;
        aliases)        printf 'name= set+ unset+' ;;
        rename)         printf 'name= new-name=' ;;
        tag)            printf 'name= tag=' ;;
        password)       printf 'name= @password' ;;
        add)            printf 'name= ip= port= user= auth= tag= host-key= accept-new-host-key replace-host-key= defer-ssh-setup @password' ;;
        trust-host-key) printf 'name= host-key=' ;;
        delete)         printf 'name= scope= revoke-key' ;;
        check)          printf 'name=' ;;
        upload-scripts) printf 'name= force' ;;
        harden)         printf 'name= port=' ;;
        setup-ssh)      printf 'provision-keys= on-failure=' ;;
        shell)          printf 'name= !tty' ;;
        *) return 1 ;;
    esac
}

_cli_help_node() {
    cat <<'EOF'
node list|Список нод
node show --name N|Подробности ноды и варианты удаления
node aliases --name N [--set ORIG=ALIAS…] [--unset ORIG…]|Псевдонимы подключений (без --set/--unset — обнаружить по SSH)
node rename --name N --new-name M|Переименовать ноду (имя: латиница, цифры, «.», «_», «-»)
node tag --name N --tag T|Задать тег ноды (пустой допустим; до 32 символов, без управляющих и служебных символов)
node password --name N|Сохранить пароль SSH (секрет password: --password-stdin)
node add --name N --ip IP [--port 22] [--user root] --auth key|password --tag T [--host-key SHA256:… | --accept-new-host-key] [--replace-host-key SHA256:… [--yes]] [--defer-ssh-setup]|Добавить ноду (для --auth password — секрет password)
node trust-host-key --name N --host-key SHA256:… [--yes]|Доверять новому ключу сервера ноды
node delete --name N [--scope local|server] [--revoke-key] [--yes]|Удалить ноду
node check --name N|Проверить SSH-подключение
node upload-scripts --name N [--force [--yes]]|Загрузить скрипты на ноду
node harden --name N [--port P] [--yes]|Усилить защиту SSH: ключ, отключение пароля, новый порт (подтверждение планом — только с --port)
node setup-ssh [--provision-keys yes|no] [--on-failure rollback|defer] [--yes]|Завершить отложенную SSH-настройку нод (GitHub)
node shell --name N|Открыть меню сервера по SSH (нужен терминал)
EOF
}

# JSON-массив нод с состоянием пароля и проблемами переносимости.
_cli_nodes_json() {
    local base auth_states='{}' issues='[]' id state
    base=$(jq_r -c '[.nodes[] | {id, name, ip, port, user, auth, tag:(.tag // ""),
        identity:(if .identity == null or .identity == "" then null
                  elif .identity == "system" then "system" else "managed" end),
        aliases:(.aliases // {})}]')
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        state=$(_cli_node_password_state "$id")
        auth_states=$(jq -c --arg id "$id" --arg s "$state" '. + {($id): $s}' <<< "$auth_states")
    done < <(jq_r '.nodes[] | select(.auth=="password") | .id')
    if [[ "$CONFIG_SOURCE" == github ]]; then
        issues=$(_state_declared_issues 2>/dev/null) || issues='[]'
        [[ -n "$issues" ]] || issues='[]'
    fi
    jq -c --argjson astate "$auth_states" --argjson is "$issues" '
        map(. as $n | . + {
            password: (if $n.auth == "password" then ($astate[$n.id] // "error") else null end),
            issues: [$is[] | select(.node_id == $n.id) | .reason]
        })' <<< "$base"
}

cli_cmd_node_list() {
    CLI_DATA=$(_cli_nodes_json | jq -c 'map(del(.id, .aliases))')
}

cli_cmd_node_show() {
    cli_require_value name || return 1
    local name clients=0 c groups node
    name=$(cli_opt name)
    _cli_require_node "$name" || return 1
    node=$(_cli_nodes_json | jq -c --arg n "$name" '.[] | select(.name==$n) | del(.id)')
    groups=$(jq_r -c --arg n "$name" '[.connections[] | select(.node==$n) | .groups[].name] | unique')
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        [[ ",$(_collect_client_nodes "$c")," == *",$name,"* ]] && clients=$((clients + 1))
    done < <(jq_r '.clients[].name')
    CLI_DATA=$(jq -c --argjson g "$groups" --argjson c "$clients" \
        --argjson d "$(_node_delete_options_json "$name")" \
        '. + {groups:$g, clients:$c, delete_options:$d}' <<< "$node")
}

# Обнаружить подключения ноды по SSH → CLI_DISCOVERED (строки, может быть пусто).
_cli_node_discover() {
    local name="$1"
    CLI_DISCOVERED=""
    _cli_node_load "$name" || return 1
    ssh_probe || return 1
    if ! CLI_DISCOVERED=$(_discover_connections); then
        rc_fail remote_failed "Не удалось обнаружить подключения на $name."
        return 1
    fi
}

_cli_node_aliases_read() {
    local name="$1" aliases
    _cli_node_discover "$name" || return 1
    aliases=$(jq_r -c --arg n "$name" '.nodes[] | select(.name==$n) | .aliases // {}')
    CLI_DATA=$(printf '%s\n' "$CLI_DISCOVERED" | _cli_json_lines |
        jq -c --argjson a "$aliases" 'map({proxy:., alias:($a[.] // null)})')
}

cli_cmd_node_aliases() {
    cli_require_value name || return 1
    local name aliases line orig alias
    name=$(cli_opt name)
    if ! cli_has set && ! cli_has unset; then
        _cli_node_aliases_read "$name"
        return
    fi
    _cli_require_node "$name" || return 1
    aliases=$(jq_r -c --arg n "$name" '.nodes[] | select(.name==$n) | .aliases // {}')
    while IFS= read -r line; do
        if [[ "$line" != *=* || -z "${line%%=*}" ]]; then
            rc_fail usage "Флаг --set ожидает ORIG=ALIAS, получено: ${line}."
            return 1
        fi
        orig="${line%%=*}"
        alias="${line#*=}"
        if [[ -n "$alias" ]]; then
            aliases=$(jq -c --arg k "$orig" --arg v "$alias" '. + {($k): $v}' <<< "$aliases")
        else
            aliases=$(jq -c --arg k "$orig" 'del(.[$k])' <<< "$aliases")
        fi
    done < <(cli_list set)
    while IFS= read -r orig; do
        if [[ -z "$orig" ]]; then
            rc_fail usage "Флаг --unset ожидает имя подключения."
            return 1
        fi
        aliases=$(jq -c --arg k "$orig" 'del(.[$k])' <<< "$aliases")
    done < <(cli_list unset)
    state_action node_aliases core_node_set_aliases "$name" "$aliases" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --argjson a "$aliases" '{name:$n, aliases:$a}')
}

cli_cmd_node_rename() {
    cli_require_value name new-name || return 1
    local new
    new=$(cli_opt new-name)
    state_action rename_node core_node_rename "$(cli_opt name)" "$new" || return 1
    CLI_DATA=$(jq -cn --arg n "$new" '{name:$n}')
}

cli_cmd_node_tag() {
    cli_require_value name || return 1
    cli_require tag || return 1
    local name tag
    name=$(cli_opt name)
    tag=$(cli_opt tag)
    state_action set_node_tag core_node_set_tag "$name" "$tag" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --arg t "$tag" '{name:$n, tag:$t}')
}

cli_cmd_node_password() {
    cli_require_value name || return 1
    local name id auth password
    name=$(cli_opt name)
    if ! password=$(rc_secret password) || [[ -z "$password" ]]; then
        rc_fail usage "Не передан секрет password (--password-stdin или поле secrets)."
        return 1
    fi
    _cli_require_node "$name" || return 1
    auth=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .auth')
    if [[ "$auth" != password ]]; then
        rc_fail invalid "Нода '$name' использует вход по ключу; пароль не нужен."
        return 1
    fi
    id=$(jq_r --arg n "$name" '.nodes[] | select(.name==$n) | .id')
    state_action save_node_password node_save_password "$id" "$password" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" '{name:$n}')
    success "Пароль SSH ноды '$name' сохранён."
}

cli_cmd_node_add() {
    cli_require_value name ip auth || return 1
    cli_require tag || return 1
    local name auth password="" mode=known-only defer=false port user
    name=$(cli_opt name)
    auth=$(cli_opt auth)
    case "$auth" in
        key)
            if rc_secret password >/dev/null; then
                rc_fail usage "Секрет password используется только с --auth password."
                return 1
            fi
            ;;
        password)
            if ! password=$(rc_secret password) || [[ -z "$password" ]]; then
                rc_fail usage "Для --auth password нужен секрет password (--password-stdin или поле secrets)."
                return 1
            fi
            ;;
        *)
            rc_fail usage "Флаг --auth принимает key или password."
            return 1
            ;;
    esac
    if cli_has host-key && cli_has accept-new-host-key; then
        rc_fail usage "Укажите только один из флагов: --host-key | --accept-new-host-key."
        return 1
    fi
    if cli_has host-key && cli_has replace-host-key; then
        rc_fail usage "Укажите только один из флагов: --host-key | --replace-host-key."
        return 1
    fi
    if cli_has replace-host-key; then
        # Сменившийся ключ: сверить отпечаток со снимком и заменить записи узла
        # только после согласия с планом (прежние и новый отпечатки).
        mode=$(cli_opt replace-host-key)
        if [[ "$mode" != SHA256:?* ]]; then
            rc_fail usage "Флаг --replace-host-key ожидает отпечаток вида SHA256:…"
            return 1
        fi
        mode="replace:$mode"
    elif cli_has host-key; then
        mode=$(cli_opt host-key)
        if [[ "$mode" != SHA256:?* ]]; then
            rc_fail usage "Флаг --host-key ожидает отпечаток вида SHA256:…"
            return 1
        fi
    elif cli_has accept-new-host-key; then
        mode=accept-new
    fi
    if cli_has defer-ssh-setup; then
        if [[ "$CONFIG_SOURCE" != github ]]; then
            rc_fail usage "Флаг --defer-ssh-setup доступен только в режиме GitHub."
            return 1
        fi
        defer=true
    fi
    port=$(cli_opt port)
    user=$(cli_opt user)
    if [[ "$mode" == replace:* ]]; then
        CORE_PLAN_LINES=()
        core_node_add_replace_plan "$name" "$(cli_opt ip)" "${port:-22}" "${mode#replace:}" || return 1
        rc_confirm_gate || return 1
    fi
    local partial=false
    CORE_NODE_ADD_ID="" CORE_NODE_ADD_NEEDS_SETUP=false
    if ! state_action add_node core_node_add "$name" "$(cli_opt ip)" "${port:-22}" "${user:-root}" \
        "$auth" "$password" "$(cli_opt tag)" "$mode" "$defer"; then
        [[ "$RC_ERROR_CODE" == partial && -n "$CORE_NODE_ADD_ID" ]] || return 1
        partial=true
    fi
    CLI_DATA=$(jq -cn --arg n "$name" --arg id "$CORE_NODE_ADD_ID" \
        --argjson s "${CORE_NODE_ADD_NEEDS_SETUP:-false}" '{name:$n, id:$id, needs_setup:$s}')
    [[ "$partial" == false ]]
}

cli_cmd_node_delete() {
    cli_require_value name || return 1
    local name scope revoke=false
    name=$(cli_opt name)
    scope=$(cli_opt scope)
    scope="${scope:-local}"
    cli_has revoke-key && revoke=true
    CORE_PLAN_LINES=()
    core_node_delete_plan "$name" "$scope" "$revoke" || return 1
    rc_confirm_gate || return 1
    CORE_NODE_DELETE_REMOTE_REMOVED=false CORE_NODE_DELETE_DELETED=false
    if ! state_action delete_node core_node_delete "$name" "$scope" "$revoke"; then
        [[ "$RC_ERROR_CODE" == partial ]] || return 1
        CLI_DATA=$(jq -cn --arg n "$name" --arg s "$scope" \
            --argjson d "${CORE_NODE_DELETE_DELETED:-false}" \
            --argjson r "${CORE_NODE_DELETE_REMOTE_REMOVED:-false}" \
            '{name:$n, scope:$s, deleted:$d, remote_removed:$r}')
        return 1
    fi
    CLI_DATA=$(jq -cn --arg n "$name" --arg s "$scope" '{name:$n, scope:$s}')
}

cli_cmd_node_check() {
    cli_require_value name || return 1
    local name
    name=$(cli_opt name)
    core_node_check "$name" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" '{name:$n, reachable:true}')
}

cli_cmd_node_upload_scripts() {
    cli_require_value name || return 1
    local name rc=0
    name=$(cli_opt name)
    _cli_node_load "$name" || return 1
    ssh_require_portable || return 1
    if cli_has force; then
        if ! _remote_scripts_probe; then
            rc_fail remote_failed "Не удалось проверить скрипты на ноде '$name'."
            return 1
        fi
        CORE_PLAN_LINES=()
        _remote_scripts_force_plan || return 1
        rc_confirm_gate || return 1
        ensure_remote_scripts_current --force || rc=$?
    else
        ensure_remote_scripts_current || rc=$?
    fi
    if (( rc != 0 )); then
        [[ -n "$RC_ERROR_CODE" ]] || rc_fail remote_failed "Не удалось обновить скрипты на ноде '$name'."
        return 1
    fi
    CLI_DATA=$(jq -cn --arg n "$name" --arg s "${REMOTE_SCRIPTS_STATE:-}" --arg v "${REMOTE_SCRIPTS_VERSION:-}" \
        '{name:$n, state:$s, version:$v}')
}

cli_cmd_node_trust_host_key() {
    cli_require_value name host-key || return 1
    local name fp scan rc=0
    name=$(cli_opt name)
    fp=$(cli_opt host-key)
    core_node_trust_host_key_plan "$name" "$fp" || return 1
    scan="$NODE_HOSTKEY_SCAN"
    if ! rc_confirm_gate; then
        rm -f "$scan"
        return 1
    fi
    state_action trust_host_key core_node_trust_host_key "$name" "$scan" "$fp" || rc=$?
    rm -f "$scan"
    (( rc == 0 )) || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --arg f "$fp" '{name:$n, fingerprint:$f}')
}

cli_cmd_node_harden() {
    cli_require_value name || return 1
    local name
    name=$(cli_opt name)
    if cli_has port; then
        cli_require_value port || return 1
    fi
    core_harden_pick_port "$name" "$(cli_opt port)" || return 1
    CORE_PLAN_LINES=()
    core_node_harden_plan
    rc_confirm_gate || return 1
    state_action ssh_hardening core_node_harden "$name" "$HARDEN_NEW_PORT" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --argjson p "$HARDEN_NEW_PORT" '{name:$n, port:$p, auth:"key"}')
}

cli_cmd_node_setup_ssh() {
    local provision="" on_failure=rollback names line
    # Отпечатки ключей серверов из плана этого запроса (см. onboarding_plan_lines).
    local ONBOARDING_PLANNED_FPS=""
    if cli_has provision-keys; then
        provision=$(cli_opt provision-keys)
        case "$provision" in
            yes|no) ;;
            *) rc_fail usage "Флаг --provision-keys принимает yes или no."; return 1 ;;
        esac
    fi
    if cli_has on-failure; then
        on_failure=$(cli_opt on-failure)
        case "$on_failure" in
            rollback|defer) ;;
            *) rc_fail usage "Флаг --on-failure принимает rollback или defer."; return 1 ;;
        esac
    fi
    if [[ "$CONFIG_SOURCE" != github ]]; then
        rc_fail invalid "Отложенная SSH-настройка доступна только для источника GitHub."
        return 1
    fi
    if ! state_actionable_ssh_setup_pending; then
        rc_fail nothing_pending "Отложенной SSH-настройки нод нет."
        return 1
    fi
    names=$(_portable_onboarding_key_nodes | _cli_json_lines)
    if [[ -z "$provision" && "$names" != "[]" ]]; then
        rc_fail key_provisioning_required "Нужно решить, создавать ли переносимый SSH-ключ для нод со входом по ключу." \
            "$(jq -cn --argjson n "$names" '{nodes:$n}')"
        return 1
    fi
    [[ -n "$provision" ]] || provision=no
    CORE_PLAN_LINES=("Ноды: $(jq_r '[.nodes[].name] | join(", ")')")
    if [[ "$names" != "[]" && "$provision" == no ]]; then
        line=$(jq -r 'join(", ")' <<< "$names")
        CORE_PLAN_LINES+=("Без переносимого ключа, настройка останется отложенной: $line")
    fi
    onboarding_plan_lines "$provision" || return 1
    if [[ "$on_failure" == defer ]]; then
        CORE_PLAN_LINES+=("При сбое проблемная нода останется отложенной.")
    else
        CORE_PLAN_LINES+=("При сбое все изменения будут отменены.")
    fi
    rc_confirm_gate || return 1
    state_action complete_portable_node_setup core_node_setup_ssh "$provision" "$on_failure" || return 1
    CLI_DATA=$(jq -cn --argjson r "${SETUP_SSH_READY:-false}" \
        --argjson i "$(_cli_json_array "${ONBOARDING_INSTALLED[@]}")" \
        --argjson d "$(_cli_ssh_setup_deferred_json)" \
        --argjson p "$(state_actionable_ssh_setup_pending && echo true || echo false)" \
        '{ready:$r, installed:$i, deferred:$d, pending:$p}')
}

# Оставшиеся отметки отложенной настройки → [{"name","issue"}].
_cli_ssh_setup_deferred_json() {
    local issues
    issues=$(_state_declared_issues 2>/dev/null) || issues='[]'
    [[ -n "$issues" ]] || issues='[]'
    jq_r -c --argjson is "$issues" '. as $c | [$is[] | . as $i
        | {name:(($c.nodes[] | select(.id == $i.node_id) | .name) // $i.node_id), issue:$i.reason}]'
}

cli_cmd_node_shell() {
    cli_require_value name || return 1
    local name rc=0
    name=$(cli_opt name)
    if ! _rc_tty_available; then
        rc_fail tty_required "Меню сервера требует терминала."
        return 1
    fi
    _cli_node_load "$name" || return 1
    ssh_probe || return 1
    ensure_remote_scripts_current || {
        [[ -n "$RC_ERROR_CODE" ]] || rc_fail remote_failed "Не удалось подготовить скрипты на ноде '$name'."
        return 1
    }
    _rc_tty_run run_remote || rc=$?
    if (( rc != 0 )); then
        rc_fail remote_failed "SSH-сессия с нодой '$name' завершилась с ошибкой."
        return 1
    fi
    info "SSH-сессия завершена."
    CLI_DATA='{}'
}

# ─── conn ────────────────────────────────────────────────────────────────────

cli_spec_conn() {
    case "$1" in
        list) printf 'node= discover' ;;
        set)  printf 'node= group+ proxy+' ;;
        sync) printf 'node=' ;;
        *) return 1 ;;
    esac
}

_cli_help_conn() {
    cat <<'EOF'
conn list [--node N [--discover]]|Подключения нод по группам
conn set --node N --group G… [--proxy P…]|Назначить подключения группам (без --proxy — снять)
conn sync [--node N]|Обнаружить подключения нод по SSH и убрать устаревшие назначения
EOF
}

cli_cmd_conn_list() {
    local node="" list
    if cli_has discover && ! cli_has node; then
        rc_fail usage "Флаг --discover требует --node. $(_cli_usage_hint)"
        return 1
    fi
    if cli_has node; then
        node=$(cli_opt node)
        _cli_require_node "$node" || return 1
    fi
    CLI_DATA=$(jq_r -c --arg n "$node" '
        . as $root |
        [$root.nodes[].name | select($n == "" or . == $n)] |
        map(. as $node | {node:$node,
            groups:([$root.connections[]? | select(.node==$node) | .groups[]? | {name, proxies:(.proxies // [])}])})')
    if cli_has discover; then
        local base="$CLI_DATA"
        CLI_DATA=""
        _cli_node_discover "$node" || return 1
        list=$(printf '%s\n' "$CLI_DISCOVERED" | _cli_json_lines)
        CLI_DATA=$(jq -c --argjson d "$list" 'map(. + {discovered:$d})' <<< "$base")
    fi
}

cli_cmd_conn_set() {
    cli_require_value node || return 1
    cli_require group || return 1
    local node groups=() proxies=()
    node=$(cli_opt node)
    _cli_unique_lines < <(cli_list group)
    (( ${#CLI_UNIQUE[@]} == 0 )) || groups=("${CLI_UNIQUE[@]}")
    _cli_unique_lines < <(cli_list proxy)
    (( ${#CLI_UNIQUE[@]} == 0 )) || proxies=("${CLI_UNIQUE[@]}")
    CORE_CONN_ASSIGN_APPLIED=()
    if ! state_action assign_connections core_conn_assign "$node" "${#groups[@]}" "${groups[@]}" "${proxies[@]}"; then
        [[ "$RC_ERROR_CODE" == partial ]] || return 1
        CLI_DATA=$(jq -cn --arg n "$node" --argjson g "$(_cli_json_array "${groups[@]}")" \
            --argjson p "$(_cli_json_array "${proxies[@]}")" \
            --argjson a "$(_cli_json_array "${CORE_CONN_ASSIGN_APPLIED[@]}")" \
            '{node:$n, groups:$g, proxies:$p, applied:$a}')
        return 1
    fi
    CLI_DATA=$(jq -cn --arg n "$node" --argjson g "$(_cli_json_array "${groups[@]}")" \
        --argjson p "$(_cli_json_array "${proxies[@]}")" '{node:$n, groups:$g, proxies:$p}')
}

cli_cmd_conn_sync() {
    local node=""
    if cli_has node; then
        cli_require_value node || return 1
        node=$(cli_opt node)
    fi
    local rc=0
    CONN_SYNC_JSON=""
    state_action sync_connections core_conn_sync "$node" || rc=$?
    [[ -z "$CONN_SYNC_JSON" ]] || CLI_DATA="$CONN_SYNC_JSON"
    return "$rc"
}

# ─── awg ─────────────────────────────────────────────────────────────────────

cli_spec_awg() {
    case "$1" in
        status|sync) printf 'node=' ;;
        remove)      printf 'node= peer+ orphans' ;;
        *) return 1 ;;
    esac
}

_cli_help_awg() {
    cat <<'EOF'
awg status --node N|Клиенты AmneziaWG на ноде
awg sync --node N|Создать недостающих клиентов AmneziaWG
awg remove --node N (--peer P… | --orphans) [--yes]|Удалить клиентов AmneziaWG
EOF
}

# Имена клиентов со статусом из AWG_STATUS_* (после core_awg_status).
_cli_awg_names_with() {
    local want="$1" i
    for ((i = 0; i < ${#AWG_STATUS_NAMES[@]}; i++)); do
        [[ "${AWG_STATUS_STATES[$i]}" == "$want" ]] && printf '%s\n' "${AWG_STATUS_NAMES[$i]}"
    done
    return 0
}

cli_cmd_awg_status() {
    cli_require_value node || return 1
    local i items=()
    core_awg_status "$(cli_opt node)" || return 1
    for ((i = 0; i < ${#AWG_STATUS_NAMES[@]}; i++)); do
        items+=("$(jq -cn --arg n "${AWG_STATUS_NAMES[$i]}" --arg s "${AWG_STATUS_STATES[$i]}" '{name:$n, status:$s}')")
    done
    CLI_DATA=$(jq -cn --argjson inst "${AWG_STATUS_INSTALLED:-false}" \
        --argjson p "$(if (( ${#items[@]} > 0 )); then printf '%s\n' "${items[@]}" | jq -sc .; else printf '[]'; fi)" \
        '{installed:$inst, peers:$p}')
}

cli_cmd_awg_sync() {
    cli_require_value node || return 1
    local node missing=()
    node=$(cli_opt node)
    core_awg_status "$node" || return 1
    if [[ "${AWG_STATUS_INSTALLED:-false}" != true ]]; then
        rc_fail invalid "AmneziaWG не установлен на ноде '$node'."
        return 1
    fi
    _cli_unique_lines < <(_cli_awg_names_with missing)
    (( ${#CLI_UNIQUE[@]} == 0 )) || missing=("${CLI_UNIQUE[@]}")
    if (( ${#missing[@]} > 0 )); then
        state_action awg_peers core_awg_create "$node" "${missing[@]}" || return 1
    else
        info "Все клиенты AmneziaWG уже созданы."
    fi
    CLI_DATA=$(jq -cn --argjson c "$(_cli_json_array "${missing[@]}")" '{created:$c}')
}

cli_cmd_awg_remove() {
    cli_require_value node || return 1
    cli_require_one peer orphans || return 1
    local node peers=()
    node=$(cli_opt node)
    if cli_has orphans; then
        core_awg_status "$node" || return 1
        _cli_unique_lines < <(_cli_awg_names_with orphan)
    else
        _cli_unique_lines < <(cli_list peer)
    fi
    (( ${#CLI_UNIQUE[@]} == 0 )) || peers=("${CLI_UNIQUE[@]}")
    if (( ${#peers[@]} == 0 )); then
        info "Удалять нечего."
        CLI_DATA='{"removed":[]}'
        return 0
    fi
    CORE_PLAN_LINES=()
    core_awg_remove_plan "$node" "${peers[@]}" || return 1
    rc_confirm_gate || return 1
    state_action awg_peers core_awg_remove "$node" "${peers[@]}" || return 1
    CLI_DATA=$(jq -cn --argjson r "$(_cli_json_array "${peers[@]}")" '{removed:$r}')
}

# ─── telegram ────────────────────────────────────────────────────────────────

cli_spec_telegram() {
    case "$1" in
        status|install|refresh-ip|web-update|web-restart|backend-restart|remove|remove-all)
            printf 'node+ all component=' ;;
        menu) printf 'node= !tty' ;;
        *) return 1 ;;
    esac
}

_cli_help_telegram() {
    cat <<'EOF'
telegram status [--node N… | --all]|Состояние Telegram Proxy
telegram install|refresh-ip|web-update|web-restart|backend-restart (--node N… | --all) [--yes]|Действия Telegram Proxy
telegram remove --component web|mtproto (--node N… | --all) [--yes]|Удалить компонент Telegram Proxy
telegram remove-all (--node N… | --all) [--yes]|Удалить Telegram Proxy целиком
telegram menu --node N [--yes]|Серверное меню Telegram Proxy одной ноды (нужен терминал)
EOF
}

_cli_telegram() {
    local verb="$1" component action indices=() name idx rc=0 i items=() status
    case "$verb" in
        status) component=shared action=status ;;
        install) component=mtproto action=install ;;
        refresh-ip) component=mtproto action=refresh-ip ;;
        web-update) component=web action=update ;;
        web-restart) component=web action=restart ;;
        backend-restart) component=backend action=restart ;;
        remove)
            cli_require_value component || return 1
            component=$(cli_opt component)
            case "$component" in
                web|mtproto) ;;
                *) rc_fail usage "Флаг --component принимает web или mtproto."; return 1 ;;
            esac
            action=remove
            ;;
        remove-all) component=shared action=remove-all ;;
    esac
    if [[ "$verb" != remove ]] && cli_has component; then
        rc_fail usage "Флаг --component используется только с telegram remove."
        return 1
    fi
    if cli_has all && cli_has node; then
        rc_fail usage "Укажите --node или --all, но не оба."
        return 1
    fi
    if cli_has node; then
        _cli_unique_lines < <(cli_list node)
        for name in "${CLI_UNIQUE[@]}"; do
            idx=$(jq_r --arg n "$name" '.nodes | to_entries[] | select(.value.name==$n) | .key')
            if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
                rc_fail not_found "Нода '$name' не найдена."
                return 1
            fi
            indices+=("$((idx + 1))")
        done
    elif cli_has all || [[ "$verb" == status ]]; then
        local count
        count=$(nodes_count)
        for ((i = 1; i <= ${count:-0}; i++)); do indices+=("$i"); done
    else
        rc_fail usage "Укажите ноды: --node N… или --all."
        return 1
    fi
    if (( ${#indices[@]} == 0 )); then
        rc_fail invalid "Нет нод для выполнения."
        return 1
    fi
    TELEGRAM_PROXY_RESULT_NAMES=() TELEGRAM_PROXY_RESULT_CODES=() TELEGRAM_PROXY_RESULT_REASONS=()
    core_telegram_run "$component" "$action" "${indices[@]}" || rc=$?
    case "$RC_ERROR_CODE" in
        usage|failed|confirmation_required|plan_changed) return 1 ;;
    esac
    for ((i = 0; i < ${#TELEGRAM_PROXY_RESULT_NAMES[@]}; i++)); do
        case "${TELEGRAM_PROXY_RESULT_CODES[$i]}" in
            0) status=ok ;;
            3) status=not_installed ;;
            4) status=partial ;;
            *) status=error ;;
        esac
        items+=("$(jq -cn --arg n "${TELEGRAM_PROXY_RESULT_NAMES[$i]}" \
            --argjson c "${TELEGRAM_PROXY_RESULT_CODES[$i]:-1}" --arg s "$status" \
            --arg r "${TELEGRAM_PROXY_RESULT_REASONS[$i]}" \
            '{node:$n, code:$c, status:$s, reason:(if $r == "" then null else $r end)}')")
    done
    CLI_DATA=$(jq -cn --argjson r "$(if (( ${#items[@]} > 0 )); then printf '%s\n' "${items[@]}" | jq -sc .; else printf '[]'; fi)" \
        '{results:$r}')
    case "$rc" in
        0) return 0 ;;
        3) rc_fail not_installed "Компонент Telegram Proxy не установлен на части нод."; return 3 ;;
        4) rc_fail partial "Действие Telegram Proxy выполнено частично."; return 4 ;;
        *) [[ -n "$RC_ERROR_CODE" ]] || rc_fail remote_failed "Действие Telegram Proxy завершилось ошибкой."; return 1 ;;
    esac
}

cli_cmd_telegram_status() { _cli_telegram status; }
cli_cmd_telegram_install() { _cli_telegram install; }
cli_cmd_telegram_refresh_ip() { _cli_telegram refresh-ip; }
cli_cmd_telegram_web_update() { _cli_telegram web-update; }
cli_cmd_telegram_web_restart() { _cli_telegram web-restart; }
cli_cmd_telegram_backend_restart() { _cli_telegram backend-restart; }
cli_cmd_telegram_remove() { _cli_telegram remove; }
cli_cmd_telegram_remove_all() { _cli_telegram remove-all; }

cli_cmd_telegram_menu() {
    cli_require_value node || return 1
    local node idx
    node=$(cli_opt node)
    if ! _rc_tty_available; then
        rc_fail tty_required "Меню Telegram Proxy требует терминала."
        return 1
    fi
    _cli_require_node "$node" || return 1
    idx=$(jq_r --arg n "$node" '.nodes | to_entries[] | select(.value.name==$n) | .key')
    core_telegram_menu "$((idx + 1))" || return 1
    CLI_DATA='{}'
}
