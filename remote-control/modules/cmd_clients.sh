#!/bin/bash
# ─── Команды клиентов: client, group, template, generate, sub ────────────────
# Спецификации, справка и обработчики по существительным (см. modules/cli.sh).

# ─── group ───────────────────────────────────────────────────────────────────

cli_spec_group() {
    case "$1" in
        list)         printf '' ;;
        add|delete)   printf 'name=' ;;
        set-template) printf 'name= template=' ;;
        *) return 1 ;;
    esac
}

_cli_help_group() {
    cat <<'EOF'
group list|Список групп
group add --name G|Добавить группу
group delete --name G [--yes]|Удалить группу
group set-template --name G --template T|Назначить шаблон группе
EOF
}

cli_cmd_group_list() {
    local g items=() nodes count template
    while IFS= read -r g; do
        [[ -n "$g" ]] || continue
        count=$(_group_client_count "$g")
        nodes=$(_group_nodes_csv "$g" | tr ',' '\n' | _cli_json_lines)
        template=$(_template_name_for_group "$g")
        items+=("$(jq -cn --arg n "$g" --arg t "$template" --argjson c "${count:-0}" --argjson nodes "$nodes" \
            '{name:$n, template:$t, clients:$c, nodes:$nodes}')")
    done < <(jq_r '.groups[].name')
    if (( ${#items[@]} == 0 )); then
        CLI_DATA='[]'
    else
        CLI_DATA=$(printf '%s\n' "${items[@]}" | jq -sc .)
    fi
}

cli_cmd_group_add() {
    cli_require_value name || return 1
    # Имя нормализует ядро (верхний регистр): в ответе — сохранённое имя.
    state_action add_group core_group_add "$(cli_opt name)" || return 1
    CLI_DATA=$(jq -cn --arg n "$CORE_GROUP_ADD_NAME" '{name:$n}')
}

cli_cmd_group_delete() {
    cli_require_value name || return 1
    local name
    name=$(cli_opt name)
    CORE_PLAN_LINES=()
    core_group_delete_plan "$name" || return 1
    rc_confirm_gate || return 1
    state_action delete_group core_group_delete "$name" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" '{name:$n}')
}

cli_cmd_group_set_template() {
    cli_require_value name template || return 1
    local name template
    name=$(cli_opt name)
    template=$(_cli_template_name "$(cli_opt template)")
    state_action assign_template core_group_set_template "$name" "$template" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --arg t "$template" '{name:$n, template:$t}')
}

# ─── template ────────────────────────────────────────────────────────────────

cli_spec_template() {
    case "$1" in
        list)   printf '' ;;
        show)   printf 'name=' ;;
        create) printf 'name= from= group=' ;;
        export) printf 'name= output=' ;;
        import) printf 'name= file=' ;;
        *) return 1 ;;
    esac
}

_cli_help_template() {
    cat <<'EOF'
template list|Список шаблонов
template show --name T|Показать шаблон
template create --name N [--from T] [--group G]|Создать шаблон на основе другого
template export --name T --output PATH [--yes]|Сохранить шаблон в файл
template import --name T --file PATH [--yes]|Загрузить шаблон из файла
EOF
}

# Имя шаблона с обязательным суффиксом .yaml.
_cli_template_name() {
    local name="$1"
    [[ "$name" == *.yaml ]] || name="$name.yaml"
    printf '%s' "$name"
}

_cli_template_source() {
    [[ -f "$TEMPLATES_DIR/$1" ]] && printf 'user' || printf 'builtin'
}

# Путь к шаблону по имени из --name; not_found при отсутствии.
_cli_template_path() {
    local name path
    name=$(_cli_template_name "$1")
    path=$(_find_template "$name")
    if [[ -z "$path" ]]; then
        rc_fail not_found "Шаблон '$name' не найден."
        return 1
    fi
    printf '%s' "$path"
}

cli_cmd_template_list() {
    local t items=() groups
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        groups=$(jq_r -c --arg t "$t" '[.groups[] | select((.template // "default.yaml") == $t) | .name]')
        items+=("$(jq -cn --arg n "$t" --arg s "$(_cli_template_source "$t")" --argjson g "$groups" \
            '{name:$n, source:$s, groups:$g}')")
    done < <(_list_templates)
    if (( ${#items[@]} == 0 )); then
        CLI_DATA='[]'
    else
        CLI_DATA=$(printf '%s\n' "${items[@]}" | jq -sc .)
    fi
}

cli_cmd_template_show() {
    cli_require_value name || return 1
    local name path
    name=$(_cli_template_name "$(cli_opt name)")
    path=$(_cli_template_path "$name") || return 1
    CLI_DATA=$(jq -Rsc --arg n "$name" --arg s "$(_cli_template_source "$name")" --arg p "$path" \
        '{name:$n, source:$s, path:$p, content:.}' < "$path")
}

cli_cmd_template_create() {
    cli_require_value name || return 1
    local name from="" group=""
    name=$(cli_opt name)
    cli_has from && { cli_require_value from || return 1; from=$(_cli_template_name "$(cli_opt from)"); }
    if cli_has group; then
        cli_require_value group || return 1
        group=$(cli_opt group)
        _cli_require_group "$group" || return 1
    fi
    state_action template_create core_template_create "$name" "$from" "$group" || return 1
    CLI_DATA=$(jq -cn --arg n "$CORE_TEMPLATE_CREATE_NAME" --arg b "$CORE_TEMPLATE_CREATE_BASE" --arg g "$group" \
        '{name:$n, based_on:(if $b == "" then null else $b end), group:(if $g == "" then null else $g end)}')
}

cli_cmd_template_export() {
    cli_require_value name output || return 1
    local name path output
    name=$(_cli_template_name "$(cli_opt name)")
    output=$(cli_opt output)
    path=$(_cli_template_path "$name") || return 1
    if [[ -d "$output" ]]; then
        rc_fail invalid "Путь $output — каталог; укажите файл."
        return 1
    fi
    if [[ -e "$output" || -L "$output" ]]; then
        CORE_PLAN_LINES=("Файл $output будет перезаписан шаблоном $name.")
        rc_confirm_gate || return 1
    fi
    if ! cp -- "$path" "$output"; then
        rc_fail failed "Не удалось записать $output."
        return 1
    fi
    CLI_DATA=$(jq -cn --arg n "$name" --arg o "$output" '{name:$n, output:$o}')
    success "Шаблон $name сохранён в $output"
}

cli_cmd_template_import() {
    cli_require_value name file || return 1
    local name
    name=$(cli_opt name)
    name="${name%.yaml}"
    if [[ -f "$TEMPLATES_DIR/$name.yaml" ]]; then
        CORE_PLAN_LINES=("Шаблон $name.yaml будет перезаписан.")
        rc_confirm_gate || return 1
    fi
    state_action template_import core_template_import "$name" "$(cli_opt file)" || return 1
    CLI_DATA=$(jq -cn --arg n "$name.yaml" '{name:$n}')
}

# ─── client ──────────────────────────────────────────────────────────────────

cli_spec_client() {
    case "$1" in
        list)        printf 'group=' ;;
        show)        printf 'name=' ;;
        connections) printf 'name= node= proxy+ reset' ;;
        add)         printf 'name= group=' ;;
        rename)      printf 'name= new-name=' ;;
        nodes)       printf 'name= inherit node+' ;;
        set-group)   printf 'name= group=' ;;
        delete)      printf 'name+' ;;
        *) return 1 ;;
    esac
}

_cli_help_client() {
    cat <<'EOF'
client list [--group G]|Список клиентов
client show --name C|Подробности клиента (с секретами)
client connections --name C [--node N (--proxy P… | --reset [--yes])]|Подключения клиента
client add --name C --group G|Добавить клиента
client rename --name C --new-name D [--yes]|Переименовать клиента
client nodes --name C (--inherit [--yes] | --node N…)|Ноды клиента
client set-group --name C --group G [--yes]|Сменить группу клиента
client delete --name C… [--yes]|Удалить клиентов
EOF
}

# CSV эффективных нод клиента → JSON-массив.
_cli_client_nodes_json() {
    _collect_client_nodes "$1" | tr ',' '\n' | _cli_json_lines
}

_cli_client_json() {
    local name="$1" nodes
    nodes=$(_cli_client_nodes_json "$name")
    jq_r -c --arg c "$name" --argjson nodes "$nodes" '
        .clients[] | select(.name==$c) | {
            name, group,
            inherit_nodes: (.inherit_nodes_from_group != false),
            nodes: $nodes,
            subscription: {published: (.subscription.token != null),
                           expires_at: (.subscription.expires_at // null)}
        }'
}

# Подключения клиента по нодам без SSH: собственные или групповые.
_cli_client_connections_json() {
    local name="$1" nodes
    nodes=$(_cli_client_nodes_json "$name")
    jq_r -c --arg c "$name" --argjson nodes "$nodes" '
        . as $root | ($root.clients[] | select(.name==$c)) as $cl |
        $nodes | map(. as $n |
            ([$cl.connections[]? | select(.node==$n)] | first) as $own |
            if $own != null then {node:$n, mode:"own", proxies:($own.proxies // [])}
            else {node:$n, mode:"group",
                  proxies:([$root.connections[]? | select(.node==$n) | .groups[]?
                            | select(.name==$cl.group) | .proxies[]?])}
            end)'
}

cli_cmd_client_list() {
    local c items=() filter=""
    if cli_has group; then
        filter=$(cli_opt group)
        _cli_require_group "$filter" || return 1
    fi
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        items+=("$(_cli_client_json "$c")")
    done < <(jq_r --arg g "$filter" '.clients[] | select($g == "" or .group == $g) | .name')
    if (( ${#items[@]} == 0 )); then
        CLI_DATA='[]'
    else
        CLI_DATA=$(printf '%s\n' "${items[@]}" | jq -sc .)
    fi
}

cli_cmd_client_show() {
    cli_require_value name || return 1
    local name base conns config exists=false headers='[]'
    name=$(cli_opt name)
    _cli_require_client "$name" || return 1
    base=$(_cli_client_json "$name")
    conns=$(_cli_client_connections_json "$name")
    config=$(_client_config_file "$name") || { _client_dir_invalid "$name"; return 1; }
    [[ -f "$config" ]] && exists=true
    if [[ "$(jq_r --arg c "$name" 'any(.clients[]; .name==$c and (.subscription.token // "") != "")')" == true ]]; then
        headers=$(_resolve_headers "$name")
        [[ -n "$headers" ]] || headers='[]'
    fi
    # Учётные данные и ссылка с токеном собираются в jq из config.json — не через argv.
    CLI_DATA=$(jq_r -c --arg c "$name" --argjson base "$base" --argjson cn "$conns" --arg p "$config" \
        --argjson ex "$exists" --argjson h "$headers" '
        (.subscription_host.base_url // "") as $b |
        first(.clients[] | select(.name==$c)) as $cl |
        ($cl.credentials // {}) as $cr |
        ($cl.subscription.token // "") as $t |
        ($cl.subscription.expires_at // "") as $e |
        $base | del(.subscription) + {
            credentials:{vless_uuid:($cr.vless_uuid // null), hy2_password:($cr.hy2_password // null)},
            connections:$cn, config:{path:$p, exists:$ex},
            subscription:(if $t == "" then null else
                {url:(if $b == "" then null else "\($b)/sub/\($t)" end),
                 expires_at:(if $e == "" then null else $e end), headers:$h} end)}')
}

cli_cmd_client_add() {
    cli_require_value name group || return 1
    local name group
    name=$(cli_opt name)
    group=$(cli_opt group)
    state_action add_client core_client_add "$name" "$group" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --arg g "$group" '{name:$n, group:$g}')
}

cli_cmd_client_rename() {
    cli_require_value name new-name || return 1
    local name new rc=0
    name=$(cli_opt name)
    new=$(cli_opt new-name)
    # Клиент AmneziaWG со старым именем удаляется на серверах — только по плану.
    CORE_PLAN_LINES=()
    core_client_rename_plan "$name" "$new" || return 1
    if (( ${#CORE_PLAN_LINES[@]} > 0 )); then
        rc_confirm_gate || return 1
    fi
    state_action rename_client core_client_rename "$name" "$new" || rc=$?
    # partial: клиент переименован, не удалён только клиент AmneziaWG со старым именем.
    (( rc == 0 )) || [[ "$RC_ERROR_CODE" == partial ]] || return 1
    CLI_DATA=$(jq -cn --arg n "$new" '{name:$n}')
    return "$rc"
}

cli_cmd_client_nodes() {
    cli_require_value name || return 1
    cli_require_one inherit node || return 1
    local name nodes=()
    name=$(cli_opt name)
    if cli_has inherit; then
        _cli_require_client "$name" || return 1
        # Свои ноды и подключения клиента будут сброшены — только по плану.
        CORE_PLAN_LINES=()
        core_client_inherit_plan "$name" || return 1
        if (( ${#CORE_PLAN_LINES[@]} > 0 )); then
            rc_confirm_gate || return 1
        fi
        state_action inherit_client_nodes _inherit_client_nodes "$name" || return 1
    else
        _cli_unique_lines < <(cli_list node)
        (( ${#CLI_UNIQUE[@]} == 0 )) || nodes=("${CLI_UNIQUE[@]}")
        state_action set_client_nodes core_client_set_nodes "$name" "${nodes[@]}" || return 1
    fi
    CLI_DATA=$(_cli_client_json "$name" | jq -c '{name, inherit_nodes, nodes}')
}

cli_cmd_client_connections() {
    cli_require_value name || return 1
    local name node proxies=()
    name=$(cli_opt name)
    if ! cli_has node && ! cli_has proxy && ! cli_has reset; then
        _cli_require_client "$name" || return 1
        CLI_DATA=$(_cli_client_connections_json "$name")
        return 0
    fi
    cli_require_value node || return 1
    cli_require_one proxy reset || return 1
    node=$(cli_opt node)
    if cli_has reset; then
        # Проверки ядра — до подтверждения: план для неприменимого сброса не нужен.
        _client_connections_check "$name" "$node" || return 1
        CORE_PLAN_LINES=("Клиент: $name" "Нода: $node"
            "Собственные подключения будут удалены; будут применены подключения группы.")
        rc_confirm_gate || return 1
    else
        _cli_unique_lines < <(cli_list proxy)
        (( ${#CLI_UNIQUE[@]} == 0 )) || proxies=("${CLI_UNIQUE[@]}")
    fi
    state_action set_client_connections core_client_set_connections "$name" "$node" "${proxies[@]}" || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --arg node "$node" --argjson p "$(_cli_json_array "${proxies[@]}")" \
        '{name:$n, node:$node, proxies:$p}')
}

cli_cmd_client_set_group() {
    cli_require_value name group || return 1
    local name group rc=0
    name=$(cli_opt name)
    group=$(cli_opt group)
    CORE_PLAN_LINES=()
    core_client_set_group_plan "$name" "$group" || return 1
    rc_confirm_gate || return 1
    state_action change_client_group core_client_set_group "$name" "$group" || rc=$?
    (( rc == 0 )) || [[ "$RC_ERROR_CODE" == partial ]] || return 1
    CLI_DATA=$(jq -cn --arg n "$name" --arg g "$group" '{name:$n, group:$g}')
    return "$rc"
}

cli_cmd_client_delete() {
    cli_require name || return 1
    _cli_unique_lines < <(cli_list name)
    if (( ${#CLI_UNIQUE[@]} == 0 )); then
        rc_fail usage "Флаг --name не может быть пустым. $(_cli_usage_hint)"
        return 1
    fi
    local names=("${CLI_UNIQUE[@]}")
    CORE_PLAN_LINES=()
    core_client_delete_plan "${names[@]}" || return 1
    rc_confirm_gate || return 1
    local rc=0
    state_action delete_client core_client_delete "${names[@]}" || rc=$?
    if (( rc == 0 )); then
        CLI_DATA=$(jq -cn --argjson d "$(_cli_json_array "${names[@]}")" '{deleted:$d}')
        return 0
    fi
    [[ "$RC_ERROR_CODE" == partial ]] || return 1
    # partial: что уже выполнено — удалённые записи, отозванные подписки, ноды без клиентов AmneziaWG.
    local -a deleted=()
    [[ "$CLIENT_DELETE_REMOVED" == true ]] && deleted=("${names[@]}")
    CLI_DATA=$(jq -cn --argjson d "$(_cli_json_array "${deleted[@]}")" \
        --argjson r "$(_cli_json_array "${CLIENT_DELETE_REVOKED[@]}")" \
        --argjson a "$(_cli_json_array "${CLIENT_DELETE_AWG_DONE[@]}")" \
        '{deleted:$d, revoked:$r, awg_nodes:$a}')
    return 1
}

# ─── generate ────────────────────────────────────────────────────────────────

cli_spec_generate() {
    case "$1" in
        "") printf 'all group= client=' ;;
        *) return 1 ;;
    esac
}

_cli_help_generate() {
    cat <<'EOF'
generate (--all | --group G | --client C)|Сгенерировать конфиги
EOF
}

cli_cmd_generate() {
    cli_require_one all group client || return 1
    local rc=0
    if cli_has all; then
        rc_locked generate generate_all || rc=$?
    elif cli_has group; then
        cli_require_value group || return 1
        _cli_require_group "$(cli_opt group)" || return 1
        rc_locked generate core_generate_group "$(cli_opt group)" || rc=$?
    else
        cli_require_value client || return 1
        _cli_require_client "$(cli_opt client)" || return 1
        rc_locked generate core_generate_client "$(cli_opt client)" || rc=$?
    fi
    # Сбой предусловия — без данных генерации; ошибки отдельных нод ниже → partial.
    [[ "$RC_ERROR_CODE" == locked ]] && return 1
    CLI_DATA=$(jq -cn \
        --argjson ok "$(_cli_json_array "${GENERATE_CLIENT_OK[@]}")" \
        --argjson skipped "$(_cli_json_array "${GENERATE_CLIENT_SKIPPED[@]}")" \
        --argjson failed "$(_cli_json_array "${GENERATE_CLIENT_FAILED[@]}")" \
        --argjson nodes_ok "$(_cli_json_array "${GENERATE_NODE_OK[@]}")" \
        --argjson nodes_failed "$(_cli_json_array "${GENERATE_NODE_FAILED[@]}")" \
        --arg dir "${GENERATED_DIR:-}" \
        '{ok:$ok, skipped:$skipped, failed:$failed, nodes_ok:$nodes_ok, nodes_failed:$nodes_failed, dir:$dir}')
    if (( rc != 0 )); then
        rc_fail partial "Генерация завершена с ошибками."
        return 1
    fi
}

# ─── sub ─────────────────────────────────────────────────────────────────────

cli_spec_sub() {
    case "$1" in
        host)          printf 'node=' ;;
        list)          printf '' ;;
        show)          printf 'client=' ;;
        headers)       printf 'client= group= default set+ unset+' ;;
        publish)       printf 'client= ttl=' ;;
        publish-all)   printf '' ;;
        rotate|revoke) printf 'client=' ;;
        migrate)       printf 'node=' ;;
        *) return 1 ;;
    esac
}

_cli_help_sub() {
    cat <<'EOF'
sub host [--node N]|Хост-нода подписок (с --node — задать)
sub list|Список подписок
sub show --client C|Ссылка и заголовки подписки
sub headers (--client C | --group G | --default) [--set NAME=VALUE…] [--unset NAME…]|Заголовки подписки
sub publish --client C [--ttl 30d]|Опубликовать подписку (TTL: 12h, 30d, 2w)
sub publish-all [--yes]|Опубликовать все готовые подписки и удалить с хоста подписки без клиента
sub rotate --client C [--yes]|Перевыпустить ссылку
sub revoke --client C [--yes]|Отозвать подписку
sub migrate --node N [--yes]|Перенести подписки на другую ноду
EOF
}

cli_cmd_sub_host() {
    if ! cli_has node; then
        CLI_DATA=$(jq_r -c '.subscription_host // null')
        return 0
    fi
    cli_require_value node || return 1
    state_action subscription_set_host core_sub_set_host "$(cli_opt node)" || return 1
    CLI_DATA=$(jq_r -c '.subscription_host // null')
}

cli_cmd_sub_list() {
    local now name expires state items=() exp_ts
    now=$(date +%s)
    while IFS=$'\t' read -r name expires; do
        [[ -n "$name" ]] || continue
        if [[ -z "$expires" ]]; then
            state=unlimited
        elif ! exp_ts=$(_sub_iso_to_epoch "$expires"); then
            state=unknown
        elif (( exp_ts <= now )); then
            state=expired
        else
            state=active
        fi
        items+=("$(jq -cn --arg c "$name" --arg e "$expires" --arg s "$state" \
            '{client:$c, expires_at:(if $e == "" then null else $e end), state:$s}')")
    done < <(jq_r '.clients[] | select(.subscription.token) | [.name, (.subscription.expires_at // "")] | @tsv')
    if (( ${#items[@]} == 0 )); then
        CLI_DATA='[]'
    else
        CLI_DATA=$(printf '%s\n' "${items[@]}" | jq -sc .)
    fi
}

cli_cmd_sub_show() {
    cli_require_value client || return 1
    local client token base_url headers
    client=$(cli_opt client)
    _cli_require_client "$client" || return 1
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    if [[ -z "$token" ]]; then
        rc_fail invalid "У клиента '$client' нет подписки."
        return 1
    fi
    base_url=$(jq_r '.subscription_host.base_url // empty')
    if [[ -z "$base_url" ]]; then
        rc_fail not_ready "Хост-нода подписок не задана."
        return 1
    fi
    headers=$(_resolve_headers "$client")
    [[ -n "$headers" ]] || headers='[]'
    # Ссылка с токеном собирается в jq из config.json — не через argv.
    CLI_DATA=$(jq_r -c --arg c "$client" --argjson h "$headers" '
        (.subscription_host.base_url // "") as $b |
        first(.clients[] | select(.name==$c)) as $cl |
        ($cl.subscription.expires_at // "") as $e |
        {client:$c, url:"\($b)/sub/\($cl.subscription.token)",
         expires_at:(if $e == "" then null else $e end), headers:$h}')
}

# Текущие заголовки цели: client → с источником, group/default → как есть.
_cli_sub_headers_json() {
    local kind="$1" target="$2" line items=() value name source rest
    case "$kind" in
        client)
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                source="${line##*|}"
                rest="${line%|*}"
                name="${rest##*|}"
                value="${rest%|*}"
                items+=("$(jq -cn --arg n "$name" --arg v "$value" --arg s "$source" '{name:$n, value:$v, source:$s}')")
            done < <(_resolve_headers_annotated "$target")
            if (( ${#items[@]} == 0 )); then printf '[]'; else printf '%s\n' "${items[@]}" | jq -sc .; fi
            ;;
        group)
            jq_r -c --arg g "$target" '[.groups[] | select(.name==$g) | .subscription_headers // [] | .[] | {name, value}]'
            ;;
        default)
            jq_r -c --argjson dflt "$_SUB_DEFAULT_HEADERS_JSON" '[(.subscription_default_headers // $dflt)[] | {name, value}]'
            ;;
    esac
}

cli_cmd_sub_headers() {
    cli_require_one client group default || return 1
    local kind target line hname
    local -a sets=() unsets=()
    if cli_has client; then
        kind=client; target=$(cli_opt client)
        _cli_require_client "$target" || return 1
    elif cli_has group; then
        kind=group; target=$(cli_opt group)
        _cli_require_group "$target" || return 1
    else
        kind=default; target=""
    fi
    if cli_has set || cli_has unset; then
        if [[ "$kind" == default ]]; then
            rc_fail usage "Заголовки по умолчанию не изменяются; укажите --client или --group."
            return 1
        fi
        # Все пары разбираются до записи; проверка и запись — одним действием.
        while IFS= read -r line; do
            if [[ "$line" != *=* || -z "${line%%=*}" ]]; then
                rc_fail usage "Флаг --set ожидает NAME=VALUE, получено: ${line}."
                return 1
            fi
            sets+=("${line%%=*}" "${line#*=}")
        done < <(cli_list set)
        while IFS= read -r hname; do
            if [[ -z "$hname" ]]; then
                rc_fail usage "Флаг --unset ожидает имя заголовка."
                return 1
            fi
            unsets+=("$hname")
        done < <(cli_list unset)
        state_action subscription_headers subscription_headers_apply "$kind" "$target" \
            "$(( ${#sets[@]} / 2 ))" "${sets[@]}" "${unsets[@]}" || return 1
        CLI_DATA=$(jq -cn --arg k "$kind" --arg t "$target" --argjson h "$(_cli_sub_headers_json "$kind" "$target")" \
            '{target:{kind:$k, name:$t}, headers:$h}')
        return 0
    fi
    CLI_DATA=$(_cli_sub_headers_json "$kind" "$target")
}

cli_cmd_sub_publish() {
    cli_require_value client || return 1
    local client rc=0
    client=$(cli_opt client)
    SUB_PUBLISH_URL="" SUB_PUBLISH_EXPIRES_AT=""
    state_action subscription_publish subscription_publish "$client" "$(cli_opt ttl)" || rc=$?
    # partial: подписка сохранена, не прошла только проверка HTTP — ссылка в данных.
    (( rc == 0 )) || [[ "$RC_ERROR_CODE" == partial ]] || return 1
    # Ссылка с токеном — через stdin jq, не argv.
    CLI_DATA=$(printf '%s' "$SUB_PUBLISH_URL" | jq -Rsc --arg c "$client" --arg e "$SUB_PUBLISH_EXPIRES_AT" \
        '{client:$c, url:., expires_at:(if $e == "" then null else $e end)}')
    return "$rc"
}

cli_cmd_sub_publish_all() {
    local rc=0
    SUB_PUBLISH_OK=() SUB_PUBLISH_SKIPPED=() SUB_PUBLISH_FAILED=() SUB_PUBLISH_REMOVED=0
    # План: цели публикации и осиротевшие подписки хоста (read-only SSH) — до записи.
    CORE_PLAN_LINES=()
    core_sub_publish_all_plan || return 1
    if (( SUB_PUBLISH_PLAN_COUNT > 0 )); then
        rc_confirm_gate || { SUB_PUBLISH_PRUNE=(); return 1; }
    fi
    state_action subscription_publish_all subscription_publish_all || rc=$?
    SUB_PUBLISH_PRUNE=()
    [[ "$RC_ERROR_CODE" == not_ready || "$RC_ERROR_CODE" == locked || "$RC_ERROR_CODE" == invalid ]] && return 1
    CLI_DATA=$(jq -cn \
        --argjson ok "$(_cli_json_array "${SUB_PUBLISH_OK[@]}")" \
        --argjson skipped "$(_cli_json_array "${SUB_PUBLISH_SKIPPED[@]}")" \
        --argjson failed "$(_cli_json_array "${SUB_PUBLISH_FAILED[@]}")" \
        --argjson removed "${SUB_PUBLISH_REMOVED:-0}" \
        '{published:$ok, skipped:$skipped, failed:$failed, removed:$removed}')
    if (( rc != 0 )); then
        [[ -n "$RC_ERROR_CODE" ]] || rc_fail partial "Публикация подписок завершена с ошибками."
        return 1
    fi
}

cli_cmd_sub_rotate() {
    cli_require_value client || return 1
    local client rc=0
    client=$(cli_opt client)
    CORE_PLAN_LINES=()
    core_sub_rotate_plan "$client" || return 1
    rc_confirm_gate || return 1
    SUB_ROTATE_URL=""
    state_action subscription_rotate core_sub_rotate "$client" || rc=$?
    # partial: новый токен сохранён, не прошла только проверка HTTP — ссылка в данных.
    (( rc == 0 )) || [[ "$RC_ERROR_CODE" == partial ]] || return 1
    CLI_DATA=$(printf '%s' "$SUB_ROTATE_URL" | jq -Rsc --arg c "$client" '{client:$c, url:.}')
    return "$rc"
}

cli_cmd_sub_revoke() {
    cli_require_value client || return 1
    local client
    client=$(cli_opt client)
    CORE_PLAN_LINES=()
    core_sub_revoke_plan "$client" || return 1
    rc_confirm_gate || return 1
    state_action subscription_revoke core_sub_revoke "$client" || return 1
    CLI_DATA=$(jq -cn --arg c "$client" '{client:$c}')
}

cli_cmd_sub_migrate() {
    cli_require_value node || return 1
    local node rc=0
    node=$(cli_opt node)
    SUB_MIGRATE_BASE_URL="" SUB_MIGRATE_COUNT=0
    CORE_PLAN_LINES=()
    core_sub_migrate_plan "$node" || return 1
    if [[ "${SUB_MIGRATE_COUNT:-0}" == 0 ]]; then
        info "Нет опубликованных подписок для переноса; хост не изменён."
        CLI_DATA=$(jq -cn --arg n "$node" '{node:$n, base_url:null, migrated:0}')
        return 0
    fi
    rc_confirm_gate || return 1
    state_action subscription_migrate core_sub_migrate "$node" || rc=$?
    if [[ -n "$SUB_MIGRATE_BASE_URL" ]]; then
        CLI_DATA=$(jq -cn --arg n "$node" --arg u "$SUB_MIGRATE_BASE_URL" --argjson c "${SUB_MIGRATE_COUNT:-0}" \
            '{node:$n, base_url:$u, migrated:$c}')
    fi
    return "$rc"
}
