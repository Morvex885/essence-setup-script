#!/bin/bash
# ─── Управление клиентами ───────────────────────────────────────────────────

GENERATED_DIR="$CONFIG_DIR/generated"

_validate_client_name() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ && ! "$1" =~ ^\.+$ ]]
}

# Путь к директории/файлу конфигов клиента: $GENERATED_DIR/<group>/<client>/config.yaml.
# Имена клиента и группы из конфигурации проверяются заново: при недопустимом
# имени — rc 1 без вывода (код ошибки задаёт вызывающий через _client_dir_invalid).
_client_config_dir() {
    local client="$1"
    local group
    group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group')
    _validate_client_name "$client" && _validate_client_name "$group" || return 1
    printf '%s\n' "$GENERATED_DIR/$group/$client"
}

_client_config_file() {
    local dir
    dir=$(_client_config_dir "$1") || return 1
    printf '%s\n' "$dir/config.yaml"
}

_client_dir_invalid() {
    rc_fail invalid "Недопустимое имя клиента '$1' или его группы в конфигурации."
}

_generated_dir_guard() {
    _generated_path_safe "$1" && return 0
    rc_fail invalid "Каталог '$1' вне каталога сгенерированных конфигов — операция отменена."
    return 1
}

_client_exists() {
    [[ -n "${1:-}" && "$(jq_r --arg n "$1" 'any(.clients[]; .name==$n)')" == true ]]
}

_node_name_exists() {
    [[ -n "${1:-}" && "$(jq_r --arg n "$1" 'any(.nodes[]; .name==$n)')" == true ]]
}

# Имя нового клиента: допустимые символы и уникальность.
_client_add_name_check() {
    if ! _validate_client_name "${1:-}"; then
        rc_fail invalid "Имя может содержать только буквы, цифры, точку, - и _"
        return 1
    fi
    if _client_exists "$1"; then
        rc_fail conflict "Клиент '$1' уже существует."
        return 1
    fi
}

# core_client_add NAME GROUP — клиент с нодами от группы и новыми credentials.
core_client_add() {
    local name="${1:-}" group="${2:-}"
    _client_add_name_check "$name" || return 1
    _group_exists "$group" || { rc_fail not_found "Группа '$group' не найдена."; return 1; }

    # Показываем ноды группы
    local group_nodes
    group_nodes=$(_group_nodes_csv "$group")
    group_nodes="${group_nodes//,/, }"
    if [[ -n "$group_nodes" ]]; then
        info "Ноды группы: $group_nodes"
    else
        warn "У группы $group нет нод. Назначьте прокси группе через Подключения."
    fi

    # Генерируем per-client credentials; в jq — файлом 0600, не аргументами.
    local client_uuid client_hy2_pass cred_file rc=0
    client_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    client_hy2_pass=$(openssl rand -hex 16)
    if ! _client_vless_uuid_valid "$client_uuid" || [[ ! "$client_hy2_pass" =~ ^[0-9a-f]{32}$ ]] ||
        ! cred_file=$(_secret_tmpfile "{\"vless_uuid\":\"$client_uuid\",\"hy2_password\":\"$client_hy2_pass\"}"); then
        rc_fail failed "Не удалось создать учётные данные клиента."
        return 1
    fi

    jq_w --arg n "$name" --arg g "$group" --slurpfile cr "$cred_file" \
        '.clients += [{name:$n, group:$g, inherit_nodes_from_group:true, nodes:[], connections:[], credentials:$cr[0]}]' || rc=1
    rm -f "$cred_file"
    (( rc == 0 )) || return 1

    success "Клиент $name добавлен ($group, ноды от группы)"
}

# _secret_tmpfile VALUE — путь к файлу 0600 со значением (без перевода строки)
# для jq --rawfile/--slurpfile: секрет не попадает в argv. Удаляет вызывающий.
_secret_tmpfile() {
    local file
    file=$(umask 077; mktemp) || return 1
    if ! printf '%s' "$1" > "$file"; then
        rm -f "$file"
        return 1
    fi
    printf '%s\n' "$file"
}

# core_client_inherit_plan NAME — CORE_PLAN_LINES со своими нодами и
# подключениями клиента, которые сбросит переход на ноды группы; пусто — их нет.
core_client_inherit_plan() {
    local name="${1:-}" own
    CORE_PLAN_LINES=()
    _client_exists "$name" || { rc_fail not_found "Клиент '$name' не найден."; return 1; }
    own=$(jq_r --arg n "$name" '
        .clients[] | select(.name==$n) |
        ((.nodes // []) | map(" \(.)")) as $nodes |
        ((.connections // []) | map(" \(.node): \((.proxies // []) | join(", "))")) as $conns |
        (if ($nodes | length) > 0 then ["Свои ноды будут сброшены:"] + $nodes else [] end) +
        (if ($conns | length) > 0 then ["Собственные подключения будут удалены:"] + $conns else [] end) |
        .[]')
    [[ -n "$own" ]] || return 0
    local line group
    group=$(jq_r --arg n "$name" '.clients[] | select(.name==$n) | .group')
    CORE_PLAN_LINES=("Клиент: $name")
    while IFS= read -r line; do CORE_PLAN_LINES+=("$line"); done <<< "$own"
    CORE_PLAN_LINES+=("Будут использоваться ноды и подключения группы $group.")
}

_inherit_client_nodes() {
    _client_exists "${1:-}" || { rc_fail not_found "Клиент '${1:-}' не найден."; return 1; }
    jq_w --arg n "$1" \
        '.clients |= map(if .name==$n then .inherit_nodes_from_group=true | del(.nodes) | del(.connections) else . end)' || return 1
    success "$1: ноды от группы"
}

# core_client_set_group_plan NAME GROUP — валидация и сводка смены группы.
# Заполняет CORE_PLAN_LINES и CLIENT_SET_GROUP_{AFFECTED,OLD_DIR,TOKEN,AWG_DROP},
# которые использует core_client_set_group.
core_client_set_group_plan() {
    local target="${1:-}" new_group="${2:-}"
    CORE_PLAN_LINES=()
    CLIENT_SET_GROUP_AFFECTED=()
    CLIENT_SET_GROUP_OLD_DIR=""
    CLIENT_SET_GROUP_TOKEN=""
    CLIENT_SET_GROUP_AWG_DROP=()
    _client_exists "$target" || { rc_fail not_found "Клиент '$target' не найден."; return 1; }
    _group_exists "$new_group" || { rc_fail not_found "Группа '$new_group' не найдена."; return 1; }
    _validate_client_name "$new_group" || { rc_fail invalid "Недопустимое имя группы '$new_group' в конфигурации."; return 1; }
    local current_group
    current_group=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .group')
    if [[ "$new_group" == "$current_group" ]]; then
        rc_fail invalid "Клиент '$target' уже в группе '$new_group'."
        return 1
    fi

    local cur_tpl new_tpl
    cur_tpl=$(jq_r --arg g "$current_group" '.groups[] | select(.name==$g) | .template // "default.yaml"')
    new_tpl=$(jq_r --arg g "$new_group" '.groups[] | select(.name==$g) | .template // "default.yaml"')

    local inherit
    inherit=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | if .inherit_nodes_from_group == false then false else true end')

    # Собираем affected_nodes ДО изменения JSON
    local affected_nodes=()
    local _csv _n
    local -a _arr

    _csv=$(_group_nodes_csv "$current_group")
    IFS=',' read -ra _arr <<< "$_csv"
    for _n in "${_arr[@]}"; do
        [[ -z "$_n" ]] && continue
        array_contains "$_n" "${affected_nodes[@]}" && continue
        affected_nodes+=("$_n")
    done

    _csv=$(_group_nodes_csv "$new_group")
    IFS=',' read -ra _arr <<< "$_csv"
    for _n in "${_arr[@]}"; do
        [[ -z "$_n" ]] && continue
        array_contains "$_n" "${affected_nodes[@]}" && continue
        affected_nodes+=("$_n")
    done

    if [[ "$inherit" != "true" ]]; then
        _csv=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .nodes // [] | join(",")')
        IFS=',' read -ra _arr <<< "$_csv"
        for _n in "${_arr[@]}"; do
            [[ -z "$_n" ]] && continue
            array_contains "$_n" "${affected_nodes[@]}" && continue
            affected_nodes+=("$_n")
        done
    fi

    # Ноды, где после смены группы у клиента не будет AmneziaWG: клиент AmneziaWG
    # с его именем там удаляется (на остальных нодах генерация его сохранит).
    local -a awg_drop=()
    local awg_keep
    awg_keep=$'\n'$(_client_awg_nodes "$target" "$new_group")$'\n'
    while IFS= read -r _n; do
        [[ -n "$_n" && "$awg_keep" != *$'\n'"$_n"$'\n'* ]] && awg_drop+=("$_n")
    done < <(_client_awg_nodes "$target")

    # Путь старой папки клиента (не группы!) — снимается до jq_w, т.к. после
    # изменения group этот же клиент будет смотреть в новую подпапку.
    local old_dir
    old_dir=$(_client_config_dir "$target") || { _client_dir_invalid "$target"; return 1; }
    if [[ -e "$old_dir" || -L "$old_dir" ]]; then
        _generated_dir_guard "$old_dir" || return 1
    fi

    local token client_conns_count header_changes="" _addr
    token=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .subscription.token // empty')
    client_conns_count=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .connections // [] | length')
    # Итоговые заголовки подписки (default → группа → клиент, как _resolve_headers) до и после.
    if [[ -n "$token" ]]; then
        header_changes=$(jq_r --arg n "$target" --arg old "$current_group" --arg new "$new_group" '
            def effective($g): ((.subscription_default_headers // [])
                + ((.groups[] | select(.name==$g) | .subscription_headers) // [])
                + ((.clients[] | select(.name==$n) | .subscription.headers) // []))
                | group_by(.name) | map({key: .[-1].name, value: .[-1].value}) | from_entries;
            effective($old) as $a | effective($new) as $b |
            (($a + $b) | keys)[] as $k | select($a[$k] != $b[$k]) |
            if ($a | has($k) | not) then " + \($k): \($b[$k])"
            elif ($b | has($k) | not) then " - \($k): \($a[$k])"
            else " \($k): \($a[$k]) → \($b[$k])" end')
    fi

    # Сводка изменений
    local _review=("Клиент: $target" "Группа: $current_group → $new_group")
    [[ "$cur_tpl" != "$new_tpl" ]] && _review+=("Шаблон: $cur_tpl → $new_tpl")
    if [[ "$inherit" == "true" ]]; then
        local old_nodes new_nodes
        old_nodes=$(_group_nodes_csv "$current_group"); old_nodes="${old_nodes//,/, }"
        new_nodes=$(_group_nodes_csv "$new_group"); new_nodes="${new_nodes//,/, }"
        _review+=("Ноды клиента: ${old_nodes:-нет} → ${new_nodes:-нет}")
    fi
    _review+=("Затронутые ноды:")
    [[ ${#affected_nodes[@]} -gt 0 ]] || _review+=(" нет")
    for _n in "${affected_nodes[@]}"; do
        _addr=$(jq_r --arg n "$_n" '.nodes[] | select(.name==$n) | "\(.ip):\(.port)"')
        _review+=(" $_n  ${_addr:-не найдена}")
    done
    [[ "$client_conns_count" -gt 0 ]] && \
        _review+=("Собственные подключения ($client_conns_count) сохранятся — проверьте их: client connections --name $target.")
    if [[ -n "$header_changes" ]]; then
        _review+=("Заголовки подписки изменятся:")
        while IFS= read -r _n; do _review+=("$_n"); done <<< "$header_changes"
    fi
    _review+=("Старый каталог конфигов (удаляется после генерации нового):" " $old_dir")
    [[ -n "$token" ]] && _review+=("Подписка клиента будет обновлена.")
    [[ ${#awg_drop[@]} -gt 0 ]] && \
        _review+=("Клиент AmneziaWG '$target' будет удалён на нодах: ${awg_drop[*]}")
    [[ ${#affected_nodes[@]} -gt 0 ]] && \
        _review+=("Служба mihomo на затронутых нодах может быть перезапущена.")

    CORE_PLAN_LINES=("${_review[@]}")
    [[ ${#affected_nodes[@]} -gt 0 ]] && CLIENT_SET_GROUP_AFFECTED=("${affected_nodes[@]}")
    [[ ${#awg_drop[@]} -gt 0 ]] && CLIENT_SET_GROUP_AWG_DROP=("${awg_drop[@]}")
    CLIENT_SET_GROUP_OLD_DIR="$old_dir"
    CLIENT_SET_GROUP_TOKEN="$token"
    return 0
}

# core_client_set_group NAME GROUP — переносит клиента, регенерирует конфиги,
# синхронизирует ноды и переопубликует подписку. Сбой после записи → partial.
core_client_set_group() {
    local target="${1:-}" new_group="${2:-}" failed=0
    core_client_set_group_plan "$target" "$new_group" || return 1
    local affected_nodes=()
    [[ ${#CLIENT_SET_GROUP_AFFECTED[@]} -gt 0 ]] && affected_nodes=("${CLIENT_SET_GROUP_AFFECTED[@]}")
    local old_dir="$CLIENT_SET_GROUP_OLD_DIR" token="$CLIENT_SET_GROUP_TOKEN" _node
    local -a awg_drop=()
    [[ ${#CLIENT_SET_GROUP_AWG_DROP[@]} -gt 0 ]] && awg_drop=("${CLIENT_SET_GROUP_AWG_DROP[@]}")

    # Атомарное обновление group
    jq_w --arg n "$target" --arg g "$new_group" \
        '.clients |= map(if .name==$n then .group=$g else . end)' || return 1
    success "$target: группа — $new_group"

    # Регенерация. Prefetch явно на ВСЕХ affected_nodes (в т.ч. нодах старой
    # группы — иначе _sync_node_listeners на них тихо провалится: кеша нет).
    _reset_node_cache
    [[ ${#affected_nodes[@]} -gt 0 ]] && _prefetch_node_configs "${affected_nodes[@]}"
    _generate_group "$new_group" || failed=1
    if [[ ${#affected_nodes[@]} -gt 0 ]]; then
        _sync_listeners_on_nodes "${affected_nodes[@]}" || failed=1
    fi
    for _node in "${awg_drop[@]}"; do
        _awg_remove_peers_on_node "$_node" "$target" || failed=1
    done

    # Удаляем папку клиента в старой группе только ЕСЛИ новая успешно создана.
    # При пропуске генерации (дубликаты proxy-имён в новой группе и т.п.)
    # сохраняем старый config.yaml как fallback до ручного фикса.
    local new_dir
    if new_dir=$(_client_config_dir "$target") && [[ -f "$new_dir/config.yaml" ]]; then
        if [[ -d "$old_dir" && "$old_dir" != "$new_dir" ]]; then
            if _generated_path_safe "$old_dir"; then
                rm -rf -- "${old_dir:?}" || failed=1
            else
                warn "$target: старая папка вне каталога сгенерированных конфигов — не удалена: $old_dir"
                failed=1
            fi
        fi
    else
        warn "$target: новый config.yaml не сгенерирован — старая папка сохранена: $old_dir"
        failed=1
    fi

    # Republish подписки, если у клиента есть токен
    if [[ -n "$token" ]]; then
        echo ""
        info "Обновляю подписку для $target..."
        subscription_publish "$target" "" || failed=1
    else
        info "У клиента нет подписки — пропуск publish."
    fi

    if (( failed != 0 )); then
        rc_fail partial "Группа изменена, но обновление конфигов или нод завершено не полностью."
        return 1
    fi
    return 0
}

# core_client_rename_plan OLD NEW — проверки переименования (ничего не меняет).
# Заполняет CLIENT_RENAME_{OLD_DIR,NEW_DIR,AWG_NODES}; CORE_PLAN_LINES — только
# если у клиента есть AmneziaWG на нодах: клиент AmneziaWG со старым именем там
# удаляется (действие на серверах — по плану). Пустой план — подтверждение не нужно.
core_client_rename_plan() {
    local old_name="${1:-}" new_name="${2:-}" node addr
    CORE_PLAN_LINES=()
    CLIENT_RENAME_OLD_DIR="" CLIENT_RENAME_NEW_DIR="" CLIENT_RENAME_AWG_NODES=()
    _client_exists "$old_name" || { rc_fail not_found "Клиент '$old_name' не найден."; return 1; }
    if ! _validate_client_name "$new_name"; then
        rc_fail invalid "Имя может содержать только буквы, цифры, точку, - и _"
        return 1
    fi
    [[ "$new_name" == "$old_name" ]] && return 0
    if _client_exists "$new_name"; then
        rc_fail conflict "Клиент '$new_name' уже существует."
        return 1
    fi

    # Пути до jq_w: группа ещё привязана к old_name; новый каталог — рядом.
    local old_dir new_dir
    old_dir=$(_client_config_dir "$old_name") || { _client_dir_invalid "$old_name"; return 1; }
    new_dir="${old_dir%/*}/$new_name"
    if [[ -e "$old_dir" || -L "$old_dir" ]]; then
        _generated_dir_guard "$old_dir" || return 1
        _generated_dir_guard "$new_dir" || return 1
    fi
    if [[ -e "$new_dir" || -L "$new_dir" ]]; then
        rc_fail conflict "Каталог конфигов '$new_dir' уже существует — удалите его или выберите другое имя."
        return 1
    fi
    CLIENT_RENAME_OLD_DIR="$old_dir" CLIENT_RENAME_NEW_DIR="$new_dir"
    while IFS= read -r node; do
        [[ -n "$node" ]] && CLIENT_RENAME_AWG_NODES+=("$node")
    done < <(_client_awg_nodes "$old_name")
    (( ${#CLIENT_RENAME_AWG_NODES[@]} > 0 )) || return 0
    CORE_PLAN_LINES=("Клиент: $old_name → $new_name" "Клиент AmneziaWG '$old_name' будет удалён на нодах:")
    for node in "${CLIENT_RENAME_AWG_NODES[@]}"; do
        addr=$(jq_r --arg n "$node" '.nodes[] | select(.name==$n) | "\(.ip):\(.port)"')
        CORE_PLAN_LINES+=(" $node  ${addr:-не найдена}")
    done
    CORE_PLAN_LINES+=("Клиент AmneziaWG '$new_name' будет создан при следующей генерации конфигов.")
}

# core_client_rename OLD NEW — переименование записи и каталога конфигов; затем
# удаление клиента AmneziaWG со старым именем (см. core_client_rename_plan).
# Каталог переносится до записи конфигурации и возвращается при её сбое; сбой
# удаления AmneziaWG — partial. Результат: CLIENT_RENAME_RESULT (пусто при NEW==OLD).
core_client_rename() {
    local old_name="${1:-}" new_name="${2:-}" node moved=false
    local -a awg_nodes=() awg_failed=()
    CLIENT_RENAME_RESULT=""
    core_client_rename_plan "$old_name" "$new_name" || return 1
    [[ "$new_name" == "$old_name" ]] && return 0
    local old_dir="$CLIENT_RENAME_OLD_DIR" new_dir="$CLIENT_RENAME_NEW_DIR"
    (( ${#CLIENT_RENAME_AWG_NODES[@]} == 0 )) || awg_nodes=("${CLIENT_RENAME_AWG_NODES[@]}")
    if [[ -d "$old_dir" ]]; then
        if ! mv -- "$old_dir" "$new_dir"; then
            rc_fail failed "Не удалось перенести каталог конфигов клиента '$old_name'; клиент не переименован."
            return 1
        fi
        moved=true
    fi
    if ! jq_w --arg old "$old_name" --arg new "$new_name" \
        '.clients |= map(if .name==$old then .name=$new else . end)'; then
        if $moved && ! mv -- "$new_dir" "$old_dir"; then
            warn "Каталог конфигов не возвращён: перенесите '$new_dir' в '$old_dir' вручную."
        fi
        return 1
    fi

    CLIENT_RENAME_RESULT="$new_name"
    success "Клиент '$old_name' переименован в '$new_name'"
    for node in "${awg_nodes[@]}"; do
        _awg_remove_peers_on_node "$node" "$old_name" || awg_failed+=("$node")
    done
    if (( ${#awg_failed[@]} > 0 )); then
        rc_fail partial "Клиент переименован, но клиента AmneziaWG '$old_name' не удалось удалить на нодах: ${awg_failed[*]}. Удалите его через awg remove."
        return 1
    fi
}

# core_client_set_nodes NAME [NODE…] — свои ноды клиента (ноль нод допустим).
core_client_set_nodes() {
    local client_name="${1:-}" nname nodes_json='[]'
    [[ $# -gt 0 ]] && shift
    _client_exists "$client_name" || { rc_fail not_found "Клиент '$client_name' не найден."; return 1; }
    local selected_nodes=()
    for nname in "$@"; do
        _node_name_exists "$nname" || { rc_fail not_found "Нода '$nname' не найдена."; return 1; }
        array_contains "$nname" "${selected_nodes[@]}" || selected_nodes+=("$nname")
    done
    if [[ ${#selected_nodes[@]} -gt 0 ]]; then
        nodes_json=$(printf '%s\n' "${selected_nodes[@]}" | jq -R . | jq -s .) || return 1
    fi

    jq_w --arg n "$client_name" --argjson nodes "$nodes_json" \
        '.clients |= map(if .name==$n then .inherit_nodes_from_group=false | .nodes=$nodes else . end)' || return 1

    local nodes_display
    nodes_display=$(IFS=', '; echo "${selected_nodes[*]}")
    success "$client_name: свои ноды — ${nodes_display:-нет}"
}

# Возвращает CSV нод, назначенных клиенту (inherit от группы или custom)
_collect_client_nodes() {
    local cname="$1"
    local cgroup cinherit
    cgroup=$(jq_r --arg n "$cname" '.clients[] | select(.name==$n) | .group')
    cinherit=$(jq_r --arg n "$cname" '.clients[] | select(.name==$n) | if .inherit_nodes_from_group == false then false else true end')
    if [[ "$cinherit" == "true" ]]; then
        _group_nodes_csv "$cgroup"
    else
        jq_r --arg n "$cname" '.clients[] | select(.name==$n) | .nodes // [] | join(",")'
    fi
}

# _client_awg_nodes CLIENT [GROUP] — ноды клиента (по строке), где его собственные
# или групповые подключения включают AmneziaWG; GROUP вместо текущей группы клиента.
_client_awg_nodes() {
    jq_r --arg c "$1" --arg g "${2:-}" '
        . as $root | (.clients[] | select(.name==$c)) as $cl |
        (if $g == "" then $cl.group else $g end) as $grp |
        (if $cl.inherit_nodes_from_group == false then ($cl.nodes // [])
         else [$root.connections[]? | select(any(.groups[]?; .name == $grp)) | .node] | unique end)[] as $n |
        select([($cl.connections[]? | select(.node==$n) | .proxies[]?),
                ($root.connections[]? | select(.node==$n) | .groups[]? | select(.name==$grp) | .proxies[]?)]
               | any(. == "AWG" or startswith("awg-"))) | $n'
}

# _awg_capable_nodes — ноды конфигурации (по строке, в порядке .nodes), где хотя бы
# одно групповое или собственное подключение клиента включает AmneziaWG.
_awg_capable_nodes() {
    jq_r '. as $root | .nodes[]?.name as $n |
        select([($root.connections[]? | select(.node==$n) | .groups[]? | .proxies[]?),
                ($root.clients[]? | .connections[]? | select(.node==$n) | .proxies[]?)]
               | any(. == "AWG" or startswith("awg-"))) | $n'
}

# _awg_remove_peers_on_node NODE PEER… — удаляет клиентов AmneziaWG по имени одним
# SSH; отсутствующий клиент или неустановленный AmneziaWG — не ошибка. rc 1 — сбой.
_awg_remove_peers_on_node() {
    local node="$1" peer module cmd
    shift
    if ! node_load_by_name "$node" || ! ensure_remote_scripts_current; then
        warn "$node: не удалось подготовить удаление клиентов AmneziaWG."
        return 1
    fi
    array_contains "$node" "${SCRIPTS_READY[@]}" || SCRIPTS_READY+=("$node")
    printf -v module %q "$REMOTE_DIR/modules/amneziawg.sh"
    cmd="[ -f /etc/amnezia/amneziawg/awg0.conf ] || exit 0; source $module || exit 1; _remove_rc=0"
    for peer in "$@"; do
        cmd+="; remove_awg_peer_by_name $(printf '%q' "$peer") || _remove_rc=1"
    done
    cmd+='; exit "$_remove_rc"'
    if ! ssh_run -- "$cmd"; then
        warn "$node: не удалось удалить всех клиентов AmneziaWG."
        return 1
    fi
}

# _client_delete_scan NAME… — валидирует имена (дубли схлопываются) и заполняет
# CLIENT_DELETE_TARGETS, CLIENT_DELETE_PEER_NODES (все ноды с AmneziaWG в
# подключениях: клиент AmneziaWG мог остаться там после смены группы),
# CLIENT_DELETE_AFFECTED, CLIENT_DELETE_DIRS, CLIENT_DELETE_SUBSCRIPTIONS.
_client_delete_scan() {
    CLIENT_DELETE_TARGETS=()
    CLIENT_DELETE_PEER_NODES=()
    CLIENT_DELETE_AFFECTED=()
    CLIENT_DELETE_DIRS=()
    CLIENT_DELETE_SUBSCRIPTIONS=()
    [[ $# -gt 0 ]] || { rc_fail usage "Не указаны клиенты для удаления."; return 1; }
    local _cname _nodes_csv _nn _token
    local -a _cnodes
    for _cname in "$@"; do
        _client_exists "$_cname" || { rc_fail not_found "Клиент '$_cname' не найден."; return 1; }
        array_contains "$_cname" "${CLIENT_DELETE_TARGETS[@]}" || CLIENT_DELETE_TARGETS+=("$_cname")
    done

    # Затронутые ноды (синхронизация listeners) и ноды с AmneziaWG.
    for _cname in "${CLIENT_DELETE_TARGETS[@]}"; do
        _nodes_csv=$(_collect_client_nodes "$_cname")
        [[ -z "$_nodes_csv" ]] && continue
        IFS=',' read -ra _cnodes <<< "$_nodes_csv"
        for _nn in "${_cnodes[@]}"; do
            [[ -z "$_nn" ]] && continue
            if ! array_contains "$_nn" "${CLIENT_DELETE_AFFECTED[@]}"; then
                CLIENT_DELETE_AFFECTED+=("$_nn")
            fi
        done
    done
    while IFS= read -r _nn; do
        [[ -n "$_nn" ]] && CLIENT_DELETE_PEER_NODES+=("$_nn")
    done < <(_awg_capable_nodes)
    local _dir
    for _cname in "${CLIENT_DELETE_TARGETS[@]}"; do
        _dir=$(_client_config_dir "$_cname") || { _client_dir_invalid "$_cname"; return 1; }
        if [[ -e "$_dir" || -L "$_dir" ]]; then
            _generated_dir_guard "$_dir" || return 1
        fi
        CLIENT_DELETE_DIRS+=("$_dir")
        _token=$(jq_r --arg n "$_cname" '.clients[] | select(.name==$n) | .subscription.token // empty')
        [[ -n "$_token" ]] && CLIENT_DELETE_SUBSCRIPTIONS+=("$_cname")
    done
    return 0
}

core_client_delete_plan() {
    CORE_PLAN_LINES=()
    _client_delete_scan "$@" || return 1
    local _review=("Клиенты: ${CLIENT_DELETE_TARGETS[*]}") _host _addr _nn _i
    _host=$(jq_r '.subscription_host.node // "нет"')
    _review+=("Каталоги конфигов:")
    for (( _i=0; _i<${#CLIENT_DELETE_TARGETS[@]}; _i++ )); do
        _review+=(" ${CLIENT_DELETE_TARGETS[$_i]}: ${CLIENT_DELETE_DIRS[$_i]}")
    done
    _review+=("Затронутые ноды:")
    [[ ${#CLIENT_DELETE_AFFECTED[@]} -gt 0 ]] || _review+=(" нет")
    for _nn in "${CLIENT_DELETE_AFFECTED[@]}"; do
        _addr=$(jq_r --arg n "$_nn" '.nodes[] | select(.name==$n) | "\(.ip):\(.port)"')
        _review+=(" $_nn  ${_addr:-не найдена}")
    done
    _review+=("Клиенты AmneziaWG (${CLIENT_DELETE_TARGETS[*]}) удаляются на нодах:")
    [[ ${#CLIENT_DELETE_PEER_NODES[@]} -gt 0 ]] || _review+=(" нет")
    for _nn in "${CLIENT_DELETE_PEER_NODES[@]}"; do
        _review+=(" $_nn")
    done
    _review+=("Подписки: ${CLIENT_DELETE_SUBSCRIPTIONS[*]:-нет}" "Хост подписок: $_host"
        "Локальные записи и сгенерированные конфиги будут удалены."
        "Подписки будут отозваны."
        "Клиенты AmneziaWG будут удалены; доступ в mihomo будет убран."
        "Служба mihomo на затронутых нодах будет перезапущена.")
    CORE_PLAN_LINES=("${_review[@]}")
}

# core_client_delete NAME… — отзыв подписок и AWG-доступа, затем локальное
# удаление и синхронизация listeners. Результат: CLIENT_DELETE_TARGETS; при
# partial (часть изменений уже выполнена) — CLIENT_DELETE_REVOKED (отозванные
# подписки), CLIENT_DELETE_AWG_DONE (ноды, где клиенты AmneziaWG удалены),
# CLIENT_DELETE_REMOVED (true — локальные записи удалены).
core_client_delete() {
    CLIENT_DELETE_REVOKED=() CLIENT_DELETE_AWG_DONE=() CLIENT_DELETE_REMOVED=false
    # Готовность скриптов — только в пределах этой команды (serve живёт долго).
    SCRIPTS_READY=()
    _client_delete_scan "$@" || return 1
    local -a _targets=("${CLIENT_DELETE_TARGETS[@]}")
    local -a _peer_nodes=("${CLIENT_DELETE_PEER_NODES[@]}")
    local -a _affected_nodes=("${CLIENT_DELETE_AFFECTED[@]}")
    local -a _target_dirs=("${CLIENT_DELETE_DIRS[@]}")
    local -a _subscriptions=("${CLIENT_DELETE_SUBSCRIPTIONS[@]}")
    local _cname _nn _dir

    # Доступ отзывается до локального удаления: при сбое локальные клиенты сохраняются;
    # уже отозванные подписки удалены из конфигурации — тогда partial.
    for _cname in "${_subscriptions[@]}"; do
        if ! _subscription_revoke_silent "$_cname"; then
            if (( ${#CLIENT_DELETE_REVOKED[@]} > 0 )); then
                rc_fail partial "Удаление клиентов не завершено: подписка '$_cname' не отозвана; отозваны: ${CLIENT_DELETE_REVOKED[*]}. Локальные клиенты сохранены."
            else
                rc_fail remote_failed "Удаление клиентов не завершено: подписки не удалось отозвать. Локальные клиенты сохранены."
            fi
            return 1
        fi
        CLIENT_DELETE_REVOKED+=("$_cname")
    done
    local _failed=0
    for _nn in "${_peer_nodes[@]}"; do
        if _awg_remove_peers_on_node "$_nn" "${_targets[@]}"; then
            CLIENT_DELETE_AWG_DONE+=("$_nn")
        else
            _failed=1
        fi
    done
    if (( _failed != 0 )); then
        if (( ${#CLIENT_DELETE_REVOKED[@]} + ${#CLIENT_DELETE_AWG_DONE[@]} > 0 )); then
            rc_fail partial "Удаление клиентов не завершено: клиентов AmneziaWG удалось удалить не на всех нодах. Локальные клиенты сохранены."
        else
            rc_fail remote_failed "Удаление клиентов не завершено: клиентов AmneziaWG не удалось удалить. Локальные клиенты сохранены."
        fi
        return 1
    fi

    local names_json
    names_json=$(printf '%s\n' "${_targets[@]}" | jq -R . | jq -s .) || return 1
    if ! jq_w --argjson names "$names_json" \
        '.clients |= [.[] | select(.name as $n | $names | index($n) | not)]'; then
        if (( ${#CLIENT_DELETE_REVOKED[@]} + ${#CLIENT_DELETE_AWG_DONE[@]} > 0 )); then
            rc_fail partial "Доступ клиентов отозван, но локальные записи удалить не удалось."
        fi
        return 1
    fi
    CLIENT_DELETE_REMOVED=true
    for _dir in "${_target_dirs[@]}"; do
        [[ -e "$_dir" || -L "$_dir" ]] || continue
        if _generated_path_safe "$_dir"; then
            rm -rf -- "${_dir:?}" || _failed=1
        else
            warn "Каталог вне каталога сгенерированных конфигов не удалён: $_dir"
            _failed=1
        fi
    done
    local _payload _sync_cmd
    _sync_cmd=$(_listener_users_remote_cmd lenient)
    for _nn in "${_affected_nodes[@]}"; do
        if ! node_load_by_name "$_nn"; then _failed=1; continue; fi
        if ! _node_users_load "$_nn"; then _failed=1; continue; fi
        _payload=$(_listener_users_payload vless-tcp vless-xhttp vless-grpc hy2)
        if ! array_contains "$_nn" "${SCRIPTS_READY[@]}"; then
            if ! ensure_remote_scripts_current; then _failed=1; continue; fi
            SCRIPTS_READY+=("$_nn")
        fi
        if ssh_run -- "$_sync_cmd" <<< "$_payload"; then
            success "$_nn: входные подключения обновлены"
        else
            warn "$_nn: не удалось обновить входные подключения"
            _failed=1
        fi
    done
    if (( _failed != 0 )); then
        rc_fail partial "Локальные клиенты удалены, но очистка завершена не полностью."
        return 1
    fi
    success "Удалено клиентов: ${#_targets[@]} (${_targets[*]})"
    return 0
}

# _client_connections_check CLIENT NODE — подключения настраиваются только у
# клиента со своими нодами и только на назначенной ему ноде.
_client_connections_check() {
    local client="${1:-}" node="${2:-}" inherit
    _client_exists "$client" || { rc_fail not_found "Клиент '$client' не найден."; return 1; }
    inherit=$(jq_r --arg c "$client" '.clients[] | select(.name==$c) | .inherit_nodes_from_group != false')
    if [[ "$inherit" == true ]]; then
        rc_fail invalid "Подключения настраиваются только для клиента со своими нодами."
        return 1
    fi
    if [[ -z "$node" || "$(jq_r --arg c "$client" --arg n "$node" \
            '.clients[] | select(.name==$c) | any(.nodes[]?; . == $n)')" != true ]]; then
        rc_fail invalid "Нода '$node' не назначена клиенту '$client'."
        return 1
    fi
}

# core_client_set_connections CLIENT NODE [PROXY…] — собственные подключения
# клиента на ноде; без PROXY — сброс на групповые.
core_client_set_connections() {
    local client="${1:-}" node="${2:-}" proxies_json='[]'
    if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi
    _client_connections_check "$client" "$node" || return 1
    if [[ $# -gt 0 ]]; then
        proxies_json=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 1
    fi
    _save_client_connections "$client" "$node" "$proxies_json"
}

_save_client_connections() {
    jq_w --arg c "$1" --arg n "$2" --argjson p "$3" \
        '.clients |= map(if .name==$c then .connections = ((.connections // []) | [.[] | select(.node!=$n)]) + (if ($p|length)>0 then [{node:$n, proxies:$p}] else [] end) else . end)' || return 1
    success "$1 → $2: подключения сохранены"
}
