#!/bin/bash
# ─── Генерация клиентских конфигов ─────────────────────────────────────────

GENERATE_CLIENT_OK=()
GENERATE_CLIENT_SKIPPED=()
GENERATE_CLIENT_FAILED=()
GENERATE_NODE_OK=()
GENERATE_NODE_FAILED=()

_generate_reset_results() {
    GENERATE_CLIENT_OK=()
    GENERATE_CLIENT_SKIPPED=()
    GENERATE_CLIENT_FAILED=()
    GENERATE_NODE_OK=()
    GENERATE_NODE_FAILED=()
}

# Генерация конфигов всех клиентов группы и синхронизация listeners на её нодах.
core_generate_group() {
    local group="$1"
    _generate_reset_results
    _reset_node_cache
    [[ -n "$group" ]] || { rc_fail usage "Не указана группа."; return 1; }
    if [[ "$(jq_r --arg g "$group" 'any(.groups[]?; .name == $g)')" != true ]]; then
        rc_fail not_found "Группа '$group' не найдена."
        return 1
    fi
    _generate_group "$group" || true

    # Синхронизация per-client users на нодах группы
    local _group_nodes=()
    local _gn_csv _cn _ex
    _gn_csv=$(_group_nodes_csv "$group")
    IFS=',' read -ra _group_nodes <<< "$_gn_csv"
    # Добавляем кастомные ноды клиентов группы
    while IFS= read -r _cn; do
        [[ -z "$_cn" ]] && continue
        local _already=false
        for _ex in "${_group_nodes[@]}"; do [[ "$_ex" == "$_cn" ]] && _already=true; done
        $_already || _group_nodes+=("$_cn")
    done < <(jq_r --arg g "$group" '.clients[] | select(.group==$g and .inherit_nodes_from_group==false) | .nodes // [] | .[]')
    if [[ ${#_group_nodes[@]} -gt 0 ]]; then
        _sync_listeners_on_nodes "${_group_nodes[@]}" || true
    fi

    _generate_result
}

# Генерация конфига одного клиента и синхронизация listeners на его нодах.
core_generate_client() {
    local client="$1" group nodes_csv
    local -a nodes=()
    _generate_reset_results
    _reset_node_cache
    [[ -n "$client" ]] || { rc_fail usage "Не указан клиент."; return 1; }
    group=$(jq_r --arg n "$client" 'first(.clients[] | select(.name==$n) | .group) // empty')
    if [[ -z "$group" ]]; then
        rc_fail not_found "Клиент '$client' не найден."
        return 1
    fi
    _generate_group "$group" "$client" || true

    nodes_csv=$(_collect_client_nodes "$client")
    IFS=',' read -ra nodes <<< "$nodes_csv"
    if [[ ${#nodes[@]} -gt 0 ]]; then
        _sync_listeners_on_nodes "${nodes[@]}" || true
    fi

    _generate_result
}

# rc 1, если есть ошибки по клиентам или нодам.
_generate_result() {
    [[ ${#GENERATE_CLIENT_FAILED[@]} -eq 0 && ${#GENERATE_NODE_FAILED[@]} -eq 0 ]]
}

generate_all() {
    local -a groups=()
    local g
    _generate_reset_results
    _reset_node_cache
    while IFS= read -r g; do
        [[ -n "$g" ]] && groups+=("$g")
    done < <(jq_r '.groups[].name')
    if [[ ${#groups[@]} -eq 0 ]]; then
        warn "Нет групп."
        return 0
    fi

    # Собрать все уникальные ноды и клиентов по всем группам заранее,
    # чтобы сделать AWG peers + prefetch конфигов одним проходом
    local all_client_names=()
    local all_unique_nodes=()

    for g in "${groups[@]}"; do
        local _gnodes_csv
        _gnodes_csv=$(_group_nodes_csv "$g")
        local -a _gnodes
        IFS=',' read -ra _gnodes <<< "$_gnodes_csv"
        for _n in "${_gnodes[@]}"; do
            [[ -z "$_n" ]] && continue
            if ! array_contains "$_n" "${all_unique_nodes[@]}"; then
                all_unique_nodes+=("$_n")
            fi
        done

        while IFS= read -r _cl; do
            local _cname="${_cl%%|*}"
            if ! array_contains "$_cname" "${all_client_names[@]}"; then
                all_client_names+=("$_cname")
            fi
            local _rest="${_cl#*|}"
            local _inherit="${_rest%%|*}"
            local _own="${_rest#*|}"
            if [[ "$_inherit" != "true" && -n "$_own" ]]; then
                local -a _cnodes
                IFS=',' read -ra _cnodes <<< "$_own"
                for _n in "${_cnodes[@]}"; do
                    [[ -z "$_n" ]] && continue
                    if ! array_contains "$_n" "${all_unique_nodes[@]}"; then
                        all_unique_nodes+=("$_n")
                    fi
                done
            fi
        done < <(jq_r --arg g "$g" \
            '.clients[] | select(.group==$g) | "\(.name)|\(if .inherit_nodes_from_group == false then false else true end)|\(.nodes // [] | join(","))"')
    done

    # Один проход: AWG peers на всех нодах для всех клиентов
    _ensure_all_awg_peers "${#all_client_names[@]}" "${all_client_names[@]}" "${all_unique_nodes[@]}"
    # Один проход: предзагрузка конфигов
    _prefetch_node_configs "${all_unique_nodes[@]}"

    # Генерация (0 SSH — всё в кеше)
    for g in "${groups[@]}"; do
        _generate_group "$g" || true
    done

    # Синхронизация per-client users на нодах
    _sync_listeners_on_nodes "${all_unique_nodes[@]}" || true
    _generate_result
}

# ─── Проверка данных из конфигурации ────────────────────────────────────────
# generate.sh подключается и без clients.sh (тесты генерации), поэтому правила
# путей и учётных данных живут здесь; clients.sh использует их во время работы.

# Имя группы или клиента как компонент пути в $GENERATED_DIR — то же правило,
# что _validate_client_name (clients.sh).
_generated_name_valid() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9._-]+$ && ! "$1" =~ ^\.+$ ]]
}

# Учётные данные клиента проверяются при каждом чтении: конфигурация может
# прийти из GitHub, а значения попадают в YAML клиента и listener'ов нод.
# uuid — канонический вид uuidgen; пароль Hysteria2 генерируется как 32 hex,
# допускаются и прежние значения из [A-Za-z0-9_-] (без метасимволов).
_client_vless_uuid_valid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

_client_hy2_password_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

# 0, если PATH лежит строго внутри $GENERATED_DIR: без компонентов . и .., а
# физический каталог-родитель (cd -P, симлинки раскрыты) — внутри физического
# $GENERATED_DIR. Проверяется перед mv/rm -rf каталогов клиентов.
_generated_path_safe() {
    local path="${1:-}" rel root parent
    [[ -n "${GENERATED_DIR:-}" && "$path" == "$GENERATED_DIR"/?* ]] || return 1
    rel="${path#"$GENERATED_DIR"/}"
    case "/$rel/" in */./*|*/../*|*//*) return 1 ;; esac
    root=$(CDPATH='' cd -P -- "$GENERATED_DIR" 2>/dev/null && pwd) || return 1
    parent=$(CDPATH='' cd -P -- "${path%/*}" 2>/dev/null && pwd) || return 1
    [[ "$parent" == "$root" || "$parent" == "$root"/* ]]
}

# ─── Кеш конфигов нод ──────────────────────────────────────────────────────
NODE_CONFIG_CACHE_KEYS=()
NODE_CONFIG_CACHE_VALUES=()
NODE_CONFIG_FAILED=()
SCRIPTS_READY=()
AWG_PEERS_CHECKED=()
AWG_PEERS_FAILED=()

_reset_node_cache() {
    NODE_CONFIG_CACHE_KEYS=()
    NODE_CONFIG_CACHE_VALUES=()
    NODE_CONFIG_FAILED=()
    SCRIPTS_READY=()
    AWG_PEERS_CHECKED=()
    AWG_PEERS_FAILED=()
}

# Получить client-config.txt из кеша (без SSH)
_get_node_config() {
    local nname="$1"
    local i

    for i in "${!NODE_CONFIG_CACHE_KEYS[@]}"; do
        if [[ "${NODE_CONFIG_CACHE_KEYS[$i]}" == "$nname" ]]; then
            echo "${NODE_CONFIG_CACHE_VALUES[$i]}"
            return 0
        fi
    done

    array_contains "$nname" "${NODE_CONFIG_FAILED[@]}" && return 1

    # Не должно вызываться напрямую — только после _prefetch
    return 1
}

_node_config_cache_set() {
    local nname="$1" value="$2"
    local i
    for i in "${!NODE_CONFIG_CACHE_KEYS[@]}"; do
        if [[ "${NODE_CONFIG_CACHE_KEYS[$i]}" == "$nname" ]]; then
            NODE_CONFIG_CACHE_VALUES[$i]="$value"
            return 0
        fi
    done
    NODE_CONFIG_CACHE_KEYS+=("$nname")
    NODE_CONFIG_CACHE_VALUES+=("$value")
}

_node_config_cache_delete() {
    local nname="$1"
    local i
    for i in "${!NODE_CONFIG_CACHE_KEYS[@]}"; do
        if [[ "${NODE_CONFIG_CACHE_KEYS[$i]}" == "$nname" ]]; then
            unset "NODE_CONFIG_CACHE_KEYS[$i]" "NODE_CONFIG_CACHE_VALUES[$i]"
            return 0
        fi
    done
    return 1
}

# Предзагрузка конфигов со всех нод (один SSH на ноду)
_prefetch_node_configs() {
    local nodes=("$@")

    for nname in "${nodes[@]}"; do
        # Уже в кеше или уже провалилась
        if array_contains "$nname" "${NODE_CONFIG_CACHE_KEYS[@]}" ||
           array_contains "$nname" "${NODE_CONFIG_FAILED[@]}"; then
            continue
        fi

        if ! node_load_by_name "$nname"; then
            warn "Не удалось загрузить ноду '${nname}'."
            NODE_CONFIG_FAILED+=("$nname")
            continue
        fi

        info "Подключаюсь к $nname..."

        local remote_config
        remote_config=$(ssh_run -- "cat /etc/mihomo/client-config.txt 2>/dev/null; cat /etc/mihomo/amnezia/*/mihomo-proxy.yaml 2>/dev/null; true") || {
            warn "Не удалось получить конфиг с $nname"
            NODE_CONFIG_FAILED+=("$nname")
            continue
        }

        _node_config_cache_set "$nname" "$remote_config"
        success "$nname — конфиг загружен"
    done
}

# Батч создание AWG peers на всех нодах для всех клиентов группы.
# Первый аргумент — число клиентских имён, затем клиентские имена и ноды.
_ensure_all_awg_peers() {
    [[ $# -ge 1 ]] || return 1

    local client_count="$1"
    [[ "$client_count" =~ ^[0-9]+$ ]] || return 1
    client_count=$((10#$client_count))
    shift
    (( $# >= client_count )) || return 1

    local -a client_names=()
    local i
    for (( i=0; i<client_count; i++ )); do
        client_names+=("$1")
        shift
    done
    local nodes=("$@")

    for nname in "${nodes[@]}"; do
        array_contains "$nname" "${NODE_CONFIG_FAILED[@]}" && continue
        array_contains "$nname" "${AWG_PEERS_CHECKED[@]}" && continue

        if ! node_load_by_name "$nname"; then
            continue
        fi

        # Проверяем AWG + какие peers уже существуют — одним SSH
        local check_result
        check_result=$(ssh_run -- "if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then echo NO_AWG; else echo AWG_OK; ls /etc/mihomo/amnezia/; fi") || {
            AWG_PEERS_FAILED+=("$nname")
            continue
        }

        # AWG не установлен на ноде
        if [[ "$check_result" == "NO_AWG" ]]; then
            AWG_PEERS_CHECKED+=("$nname")
            continue
        fi

        # Собираем имена существующих peers
        local existing_peers
        existing_peers=$(echo "$check_result" | tail -n +2 | tr -d '\r')

        # Определяем какие peers нужно создать
        local missing=()
        local cname
        for cname in "${client_names[@]}"; do
            if ! echo "$existing_peers" | grep -qxF "$cname"; then
                missing+=("$cname")
            fi
        done

        if [[ ${#missing[@]} -eq 0 ]]; then
            AWG_PEERS_CHECKED+=("$nname")
            continue
        fi

        # Создаём все недостающие peers за один SSH
        info "Создаю клиентов AmneziaWG на $nname: ${missing[*]}..."
        if ! array_contains "$nname" "${SCRIPTS_READY[@]}"; then
            if ! ensure_remote_scripts_current; then
                warn "$nname: не удалось подготовить скрипты; клиенты AmneziaWG не изменены."
                AWG_PEERS_FAILED+=("$nname")
                continue
            fi
            SCRIPTS_READY+=("$nname")
        fi

        local peers_cmd="source ${REMOTE_DIR}/modules/amneziawg.sh"
        for cname in "${missing[@]}"; do
            peers_cmd="$peers_cmd && add_awg_peer_auto $(printf '%q' "$cname")"
        done

        ssh_run -- "$peers_cmd" || {
            warn "Ошибка при создании клиентов AmneziaWG на $nname"
            AWG_PEERS_FAILED+=("$nname")
        }

        # Инвалидируем кеш — конфиг ноды изменился (новые peers)
        _node_config_cache_delete "$nname"
        AWG_PEERS_CHECKED+=("$nname")
    done
}

_render_client_config() {
    local processed_template="$1"
    local proxy_entries="$2"
    local found_anchor=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        if [[ "$line" == "proxies:" ]]; then
            found_anchor=1
            if [[ -n "$proxy_entries" ]]; then
                printf '%s\n' "$proxy_entries"
            fi
        fi
    done <<< "$processed_template"

    [[ -z "$proxy_entries" || "$found_anchor" -eq 1 ]]
}

# _generate_group GROUP [ONLY_CLIENT] — с ONLY_CLIENT обрабатывается только этот клиент группы.
_generate_group() {
    local group="$1" only_client="${2:-}"
    if ! _generated_name_valid "$group"; then
        warn "Недопустимое имя группы '$group' в конфигурации — конфиги группы не сгенерированы."
        local invalid
        while IFS= read -r invalid; do
            [[ -n "$invalid" ]] && GENERATE_CLIENT_FAILED+=("$invalid")
        done < <(jq_r --arg g "$group" --arg only "$only_client" '.clients[] | select(.group==$g and ($only == "" or .name == $only)) | .name')
        return 1
    fi
    local tpl_name
    tpl_name=$(_template_name_for_group "$group")
    local template
    template=$(_template_for_group "$group")

    if [[ -z "$template" ]]; then
        warn "Шаблон '$tpl_name' не найден для группы $group. Поместите файл в $TEMPLATES_DIR/"
        local skipped
        while IFS= read -r skipped; do
            [[ -n "$skipped" ]] && GENERATE_CLIENT_SKIPPED+=("$skipped")
        done < <(jq_r --arg g "$group" --arg only "$only_client" '.clients[] | select(.group==$g and ($only == "" or .name == $only)) | .name')
        return 0
    fi

    # Ноды группы
    local group_nodes_csv
    group_nodes_csv=$(_group_nodes_csv "$group")

    # Клиенты группы
    local group_clients=()
    while IFS= read -r client_line; do
        group_clients+=("$client_line")
    done < <(jq_r --arg g "$group" --arg only "$only_client" \
        '.clients[] | select(.group==$g and ($only == "" or .name == $only)) | "\(.name)|\(.group)|\(if .inherit_nodes_from_group == false then false else true end)|\(.nodes // [] | join(","))"')

    if [[ ${#group_clients[@]} -eq 0 ]]; then
        if [[ -n "$only_client" ]]; then
            warn "Клиент $only_client не найден в группе $group — пропускаю."
        else
            warn "В группе $group нет клиентов — пропускаю."
        fi
        return 0
    fi

    info "Группа $group ($tpl_name)..."

    # Фаза 1: собираем уникальные ноды и имена клиентов
    local all_nodes_csv="$group_nodes_csv"
    [[ -n "$only_client" ]] && all_nodes_csv=""
    local client_names=()
    for client_line in "${group_clients[@]}"; do
        local cname="${client_line%%|*}"
        client_names+=("$cname")
        local rest="${client_line#*|}"
        rest="${rest#*|}"
        local client_inherit="${rest%%|*}"
        local client_own_nodes="${rest#*|}"
        if [[ "$client_inherit" != "true" && -n "$client_own_nodes" ]]; then
            all_nodes_csv="${all_nodes_csv},${client_own_nodes}"
        elif [[ "$client_inherit" == "true" && -n "$only_client" ]]; then
            all_nodes_csv="${all_nodes_csv},${group_nodes_csv}"
        fi
    done

    # Дедупликация нод
    local unique_nodes=()
    local -a _all
    local _n
    IFS=',' read -ra _all <<< "$all_nodes_csv"
    for _n in "${_all[@]}"; do
        [[ -z "$_n" ]] && continue
        if ! array_contains "$_n" "${unique_nodes[@]}"; then
            unique_nodes+=("$_n")
        fi
    done

    # Фаза 2: батч AWG peers (до загрузки конфигов)
    _ensure_all_awg_peers "${#client_names[@]}" "${client_names[@]}" "${unique_nodes[@]}"
    _prefetch_node_configs "${unique_nodes[@]}"

    # Обрабатываем шаблон
    local processed
    if ! processed=$(process_template "$template" "$group"); then
        GENERATE_CLIENT_FAILED+=("${client_names[@]}")
        return 1
    fi
    local rc=0

    # Фаза 4: генерация клиентов (0 SSH)
    for client_line in "${group_clients[@]}"; do
        local client_name="${client_line%%|*}"
        local rest="${client_line#*|}"
        local client_group="${rest%%|*}"
        rest="${rest#*|}"
        local client_inherit="${rest%%|*}"
        local client_own_nodes="${rest#*|}"

        local client_nodes
        if [[ "$client_inherit" == "true" ]]; then
            client_nodes="$group_nodes_csv"
        else
            client_nodes="$client_own_nodes"
        fi

        if ! _generated_name_valid "$client_name"; then
            warn "Недопустимое имя клиента '$client_name' в конфигурации — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi
        local client_dir="$GENERATED_DIR/$group/$client_name"
        if ! mkdir -p "$client_dir" || ! _generated_path_safe "$client_dir"; then
            warn "$client_name — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi

        # Получаем прокси из кеша
        local proxy_entries=""
        if [[ -n "$client_nodes" ]]; then
            if ! proxy_entries=$(_fetch_proxies_for_client "$client_name" "$client_group" "$client_nodes"); then
                warn "$client_name — не удалось получить все подключения; конфиг сохранён без изменений"
                GENERATE_CLIENT_FAILED+=("$client_name")
                rc=1
                continue
            fi
        fi

        # Проверяем уникальность имён прокси
        if [[ -n "$proxy_entries" ]]; then
            local dup_names
            dup_names=$(printf '%s\n' "$proxy_entries" | sed -n 's/^  - name: "\([^"]*\)"$/\1/p' | sort | uniq -d)
            if [[ -n "$dup_names" ]]; then
                warn "$client_name: повторяющиеся имена прокси:" >&2
                while IFS= read -r dn; do
                    warn "  '$dn' — задайте псевдоним через «Подключения» → «Переименовать»" >&2
                done <<< "$dup_names"
                warn "$client_name — пропущен (повторяющиеся имена прокси)" >&2
                GENERATE_CLIENT_SKIPPED+=("$client_name")
                continue
            fi
        fi

        local config=""
        if ! config=$(_render_client_config "$processed" "$proxy_entries"); then
            warn "$client_name — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi

        # Убираем дублирующиеся пустые строки (артефакты удалённых блоков)
        local config_tmp=""
        if ! config_tmp=$(umask 077; mktemp "$client_dir/.config.yaml.XXXXXX"); then
            warn "$client_name — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi
        if ! cat -s > "$config_tmp" <<< "$config"; then
            rm -f "$config_tmp"
            warn "$client_name — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi
        if ! grep -q '[^[:space:]]' "$config_tmp"; then
            rm -f "$config_tmp"
            warn "$client_name — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi
        if ! mv "$config_tmp" "$client_dir/config.yaml"; then
            rm -f "$config_tmp"
            warn "$client_name — config.yaml не сгенерирован"
            GENERATE_CLIENT_FAILED+=("$client_name")
            rc=1
            continue
        fi

        GENERATE_CLIENT_OK+=("$client_name")
        success "$client_name — сгенерирован"
    done
    return "$rc"
}

# _yaml_set_field FIELD VALUE — stdin → stdout: в строках с «    FIELD: …» всё от
# первого вхождения заменяется на «    FIELD: VALUE» (как sed s/…/…/, но значение
# не интерпретируется и не попадает в argv).
_yaml_set_field() {
    local field="$1" value="$2" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"    $field: "* ]]; then
            line="${line%%"    $field: "*}    $field: $value"
        fi
        printf '%s\n' "$line"
    done
}

_fetch_proxies_for_client() {
    local client_name="$1"
    local client_group="$2"
    local nodes_csv="$3"

    local all_proxies="" rc=0
    local -a node_names _cc allowed
    local nname _p conn_name

    # Per-client credentials для подстановки в proxy-блоки (проверяются: значения
    # из конфигурации попадают в YAML клиента)
    local _client_vless_uuid _client_hy2_pass
    _client_vless_uuid=$(jq_r --arg c "$client_name" '.clients[] | select(.name==$c) | .credentials.vless_uuid // ""')
    _client_hy2_pass=$(jq_r --arg c "$client_name" '.clients[] | select(.name==$c) | .credentials.hy2_password // ""')
    if { [[ -n "$_client_vless_uuid" ]] && ! _client_vless_uuid_valid "$_client_vless_uuid"; } ||
        { [[ -n "$_client_hy2_pass" ]] && ! _client_hy2_password_valid "$_client_hy2_pass"; }; then
        warn "$client_name: недопустимые учётные данные в конфигурации" >&2
        return 1
    fi

    IFS=',' read -ra node_names <<< "$nodes_csv"
    for nname in "${node_names[@]}"; do
        # Подключения: клиентские > групповые
        local allowed_connections=""
        local client_conns
        client_conns=$(jq_r --arg c "$client_name" --arg n "$nname" \
            '.clients[] | select(.name==$c) | .connections // [] | .[] | select(.node==$n) | .proxies | join(",")')

        local group_conns
        group_conns=$(jq_r --arg n "$nname" --arg g "$client_group" \
            '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies | join(",")')

        if [[ -n "$client_conns" ]]; then
            allowed_connections="$client_conns"
            if [[ -n "$group_conns" ]]; then
                IFS=',' read -ra _cc <<< "$client_conns"
                for _p in "${_cc[@]}"; do
                    if ! echo ",$group_conns," | grep -qF ",$_p,"; then
                        warn "$client_name: подключение '$_p' на $nname отсутствует в группе $client_group" >&2
                    fi
                done
            fi
        else
            allowed_connections="$group_conns"
        fi

        # Конфиг из кеша
        local remote_config
        remote_config=$(_get_node_config "$nname") || { rc=1; continue; }

        # Парсим proxy блоки
        local proxy_block
        proxy_block=$(echo "$remote_config" | sed -n '/^proxies:/,/^---/p' | grep -v '^---' | grep -v '^proxies:' \
            | sed 's/^  - name: \([^"]\)\(.*\)/  - name: "\1\2"/')

        # Фильтр выполняется и при пустом ответе ноды: иначе сбой AWG peer не заметен.
        if [[ -n "$allowed_connections" ]]; then
            local filtered=""
            IFS=',' read -ra allowed <<< "$allowed_connections"
            for conn_name in "${allowed[@]}"; do
                # AWG: generic connection → client-specific proxy
                local match_name="$conn_name"
                [[ "$conn_name" == "AWG" ]] && match_name="awg-${client_name}"

                local block
                block=$(echo "$proxy_block" | awk -v name="$match_name" '
                    /^  - name:/ {
                        if (found) print buf
                        buf = $0
                        n = $0
                        sub(/^  - name: *"?/, "", n)
                        sub(/"? *$/, "", n)
                        found = (n == name)
                        next
                    }
                    { if (buf != "") buf = buf "\n" $0 }
                    END { if (found) print buf }
                ')
                # Per-client credentials: подставляем uuid/password клиента
                if [[ -n "$block" ]]; then
                    local _proxy_type
                    _proxy_type=$(echo "$block" | grep '    type:' | awk '{print $2}' | head -1)
                    case "$_proxy_type" in
                        vless)
                            [[ -n "$_client_vless_uuid" ]] && \
                                block=$(printf '%s\n' "$block" | _yaml_set_field uuid "$_client_vless_uuid")
                            if declare -F _normalize_vless_xhttp_proxy_yaml >/dev/null; then
                                block=$(printf '%s\n' "$block" | _normalize_vless_xhttp_proxy_yaml)
                            fi
                            ;;
                        hysteria2)
                            [[ -n "$_client_hy2_pass" ]] && \
                                block=$(printf '%s\n' "$block" | _yaml_set_field password "$_client_hy2_pass")
                            ;;
                    esac
                fi
                # AWG: переименовать proxy → "AmneziaWG 3.1"
                if [[ -n "$block" && "$conn_name" == "AWG" ]]; then
                    local awg_display="AmneziaWG 3.1"
                    block="  - name: \"${awg_display}\""$'\n'"$(echo "$block" | tail -n +2)"
                fi
                # AWG peer не создан на этой ноде — не сохраняем конфиг без AWG
                if [[ -z "$block" && "$conn_name" == "AWG" ]] && array_contains "$nname" "${AWG_PEERS_FAILED[@]}"; then
                    warn "$client_name: клиент AmneziaWG на $nname не создан" >&2
                    rc=1
                fi
                [[ -n "$block" ]] && filtered="${filtered}${block}"$'\n'
            done
            proxy_block="$filtered"
        fi

        # Aliases
        if [[ -n "$proxy_block" ]]; then
            local aliases_json
            aliases_json=$(jq_r --arg n "$nname" '.nodes[] | select(.name==$n) | .aliases // {}')
            if [[ -n "$aliases_json" && "$aliases_json" != "{}" && "$aliases_json" != "null" ]]; then
                local orig repl
                while IFS=$'\t' read -r orig repl; do
                    local search="  - name: \"$orig\""
                    local replace="  - name: \"$repl\""
                    proxy_block="${proxy_block//"$search"/"$replace"}"
                done < <(printf '%s\n' "$aliases_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | tr -d '\r')
            fi

            # Tag prefix
            local tag
            tag=$(jq_r --arg n "$nname" '.nodes[] | select(.name==$n) | .tag // ""')
            if [[ -n "$tag" ]]; then
                proxy_block="${proxy_block//  - name: \"/  - name: \"${tag} }"
            fi

            all_proxies="${all_proxies}${proxy_block}"$'\n'
        fi
    done

    [[ -z "$all_proxies" ]] || echo "$all_proxies" | awk '/^  - name:/ && NR>1 {print ""} 1'
    return "$rc"
}

# ─── Синхронизация users в listener'ах на нодах ──────────────────────────────

# _node_users_load NODE → NODE_USERS_DATA: строки «имя|uuid|пароль» клиентов,
# назначенных ноде (через группу или свои ноды). rc 1 — конфигурация не читается
# или имя/учётные данные клиента недопустимы: на ноду ничего не отправляется.
_node_users_load() {
    local nname="$1" data name uuid pass
    NODE_USERS_DATA=""
    data=$(set -o pipefail
        jq_r --arg n "$nname" '
            . as $root |
            .clients[] |
            select(
                (.inherit_nodes_from_group != false and
                    (.group as $g | any(
                        $root.connections[];
                        .node == $n and any(.groups[]?; .name == $g)
                    ))) or
                (.inherit_nodes_from_group == false and
                    (.nodes // [] | index($n)))
            ) |
            "\(.name)|\(.credentials.vless_uuid // "")|\(.credentials.hy2_password // "")"
        ' 2>/dev/null
    ) || return 1
    while IFS='|' read -r name uuid pass; do
        [[ -n "$name" ]] || continue
        if ! _generated_name_valid "$name" ||
            { [[ -n "$uuid" ]] && ! _client_vless_uuid_valid "$uuid"; } ||
            { [[ -n "$pass" ]] && ! _client_hy2_password_valid "$pass"; }; then
            warn "$nname: недопустимое имя или учётные данные клиента в конфигурации — пользователи на ноде не изменены."
            return 1
        fi
    done <<< "$data"
    NODE_USERS_DATA="$data"
}

# _listener_users_payload MARKER… — stdin для _listener_users_remote_cmd: на каждый
# маркер строка «маркер число_строк» и YAML-блок пользователей из NODE_USERS_DATA.
# uuid и пароли клиентов передаются только так — не в argv ssh и удалённого bash.
_listener_users_payload() {
    local marker block count name uuid pass
    for marker in "$@"; do
        block="" count=0
        while IFS='|' read -r name uuid pass; do
            [[ -n "$name" ]] || continue
            case "$marker" in
                hy2)
                    [[ -n "$pass" ]] || continue
                    block+="      ${name}: ${pass}"$'\n'
                    count=$((count + 1))
                    ;;
                *)
                    [[ -n "$uuid" ]] || continue
                    block+="      - username: ${name}"$'\n'"        uuid: ${uuid}"$'\n'
                    count=$((count + 2))
                    if [[ "$marker" == vless-tcp ]]; then
                        block+="        flow: xtls-rprx-vision"$'\n'
                        count=$((count + 1))
                    fi
                    ;;
            esac
        done <<< "$NODE_USERS_DATA"
        printf '%s %s\n%s' "$marker" "$count" "$block"
    done
}

# _listener_users_remote_cmd strict|lenient — постоянная SSH-команда, читающая
# пользователей listener'ов из stdin (_listener_users_payload).
# strict: первый сбой останавливает до перезапуска mihomo (генерация);
# lenient: маркеры, которых нет на ноде, пропускаются, сбои копятся (удаление).
_listener_users_remote_cmd() {
    local mode="$1" module tail
    printf -v module %q "$REMOTE_DIR/common/listener-users.sh"
    if [[ "$mode" == strict ]]; then
        tail=$(cat <<'EOF'
    _sync_listener_users "$_m" "$_u" || exit 1
done
systemctl restart mihomo
EOF
)
    else
        tail=$(cat <<'EOF'
    if grep -q "^# --- $_m ---\$" /etc/mihomo/config.yaml 2>/dev/null; then
        _sync_listener_users "$_m" "$_u" || _sync_rc=1
    fi
done
if [ -f /etc/mihomo/config.yaml ]; then systemctl restart mihomo || _sync_rc=1; fi
exit "$_sync_rc"
EOF
)
    fi
    printf 'source %s || exit 1\n' "$module"
    cat <<'EOF'
_sync_rc=0
while IFS=' ' read -r _m _n; do
    case "$_m" in vless-tcp|vless-xhttp|vless-grpc|hy2) ;; *) exit 1 ;; esac
    case "$_n" in ''|*[!0-9]*) exit 1 ;; esac
    _u=''
    while [ "$_n" -gt 0 ]; do
        IFS= read -r _l || exit 1
        _u="$_u$_l
"
        _n=$((_n - 1))
    done
    _u=${_u%?}
EOF
    printf '%s\n' "$tail"
}

# Собирает per-client users для указанной ноды и синхронизирует listener'ы.
# Пользователи (uuid/пароли) уходят в stdin SSH, команда постоянна.
# Args: nname — имя ноды
_sync_node_listeners() {
    local nname="$1" remote_config payload
    local -a markers=()

    if ! node_load_by_name "$nname"; then
        return 1
    fi

    # Клиенты, привязанные к этой ноде (через группы и кастомные ноды)
    _node_users_load "$nname" || return 1
    # Определяем какие listener'ы есть на ноде (из кешированного конфига)
    remote_config=$(_get_node_config "$nname") || return 1
    echo "$remote_config" | grep -q '^--- VLESS TCP ---' && markers+=(vless-tcp)
    echo "$remote_config" | grep -q '^--- VLESS xHTTP ---' && markers+=(vless-xhttp)
    echo "$remote_config" | grep -q '^--- VLESS gRPC ---' && markers+=(vless-grpc)
    echo "$remote_config" | grep -q '^--- Hysteria2 ---' && markers+=(hy2)
    payload=$(_listener_users_payload "${markers[@]}")

    # Подготовка скриптов один раз за операцию
    if ! array_contains "$nname" "${SCRIPTS_READY[@]}"; then
        if ! ensure_remote_scripts_current; then
            warn "$nname: не удалось подготовить скрипты; входные подключения не изменены."
            return 1
        fi
        SCRIPTS_READY+=("$nname")
    fi

    # Sync каждого listener'а, затем restart mihomo; первый сбой — без restart
    if ssh_run -- "$(_listener_users_remote_cmd strict)" 2>/dev/null <<< "$payload"; then
        success "$nname — входные подключения обновлены"
        return 0
    fi
    warn "$nname — не удалось обновить входные подключения"
    return 1
}

# Синхронизирует listeners на всех указанных нодах
_sync_listeners_on_nodes() {
    local nodes=("$@") nname rc=0

    echo ""
    info "Синхронизация пользователей на нодах..."

    for nname in "${nodes[@]}"; do
        [[ -n "$nname" ]] || continue
        if array_contains "$nname" "${NODE_CONFIG_FAILED[@]}" || ! _sync_node_listeners "$nname"; then
            GENERATE_NODE_FAILED+=("$nname")
            rc=1
        else
            GENERATE_NODE_OK+=("$nname")
        fi
    done
    return "$rc"
}
