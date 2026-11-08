#!/bin/bash
# ─── Подключения нод (per-group) ────────────────────────────────────────────

# Очищает .connections для ноды от proxy, которых нет в обнаруженном списке.
# Удаляет пустые группы и пустые ноды. Печатает удалённые proxy по строке.
# Args: $1 — имя ноды; остальные аргументы — обнаруженные подключения.
_purge_stale_connections() {
    local nname="$1" disc_json before after
    shift
    if (( $# == 0 )); then
        disc_json='[]'
    else
        disc_json=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
    fi
    before=$(jq_r -c --arg n "$nname" '[.connections[] | select(.node==$n) | .groups[].proxies[]] | unique') || return 1
    jq_w --arg n "$nname" --argjson valid "$disc_json" '
        .connections |= map(
            if .node==$n then
                .groups |= map(.proxies |= [.[] | select(. as $p | $valid | index($p))])
                | .groups |= [.[] | select(.proxies | length > 0)]
            else . end)
        | .connections |= [.[] | select(.groups | length > 0)]' || return 1
    after=$(jq_r -c --arg n "$nname" '[.connections[] | select(.node==$n) | .groups[].proxies[]] | unique') || return 1
    jq -rn --argjson b "${before:-[]}" --argjson a "${after:-[]}" '($b - $a)[]'
}

# core_conn_sync [NODE] — обнаружить подключения нод по SSH и убрать устаревшие.
# Недоступные ноды пропускаются, первая ошибка сохранения останавливает синхронизацию.
# Результат CONN_SYNC_JSON: {"nodes":[{"name","status","discovered","removed",
# "groups"}],"ok","failed","total","stopped_at"}; status — synced | unreachable |
# load_failed | save_failed | skipped. Ошибки нод → partial (данные сохраняются).
core_conn_sync() {
    local only="${1:-}" nname lines removed discovered groups status stopped="" ok=0 failed=0
    local -a nodes=() items=()
    CONN_SYNC_JSON=""
    if [[ -n "$only" ]] && ! _node_exists "$only"; then
        rc_fail not_found "Нода '${only}' не найдена."
        return 1
    fi
    while IFS= read -r nname; do
        [[ -n "$nname" ]] || continue
        [[ -z "$only" || "$nname" == "$only" ]] && nodes+=("$nname")
    done < <(jq_r '.nodes[].name')
    local _save_id="${NODE_ID:-}" _save_identity="${NODE_IDENTITY:-}" _save_tag="${NODE_TAG:-}"
    local _save_node="${NODE_NAME:-}" _save_ip="${SERVER_IP:-}" _save_port="${SERVER_PORT:-}"
    local _save_user="${SERVER_USER:-}" _save_pass="${SERVER_PASS:-}" _save_auth="${SERVER_AUTH:-}"
    (( ${#nodes[@]} == 0 )) || info "Синхронизирую подключения с нодами..."
    for nname in "${nodes[@]}"; do
        discovered=null removed='[]'
        if [[ -n "$stopped" ]]; then
            status=skipped
        elif ! node_load_by_name "$nname" >/dev/null; then
            warn "Не удалось загрузить ноду '${nname}'."
            status=load_failed
        elif ! ssh_probe >/dev/null || ! lines=$(_discover_connections); then
            warn "$nname: нода недоступна, пропуск"
            status=unreachable
        else
            local -a disc_arr=()
            while IFS= read -r removed; do
                [[ -n "$removed" ]] && disc_arr+=("$removed")
            done <<< "$lines"
            discovered=$(printf '%s\n' "${disc_arr[@]}" | jq -R 'select(length > 0)' | jq -sc .)
            if removed=$(_purge_stale_connections "$nname" "${disc_arr[@]}"); then
                removed=$(printf '%s\n' "$removed" | jq -R 'select(length > 0)' | jq -sc .)
                status=synced
            else
                warn "$nname: сохранение подключений не удалось; дальнейшая синхронизация остановлена."
                removed='[]'
                status=save_failed
                stopped="$nname"
            fi
        fi
        case "$status" in
            synced) ok=$((ok + 1)) ;;
            skipped) ;;
            *) failed=$((failed + 1)) ;;
        esac
        groups=$(jq_r -c --arg n "$nname" '[.connections[] | select(.node==$n) | .groups[]
            | {name, proxies:(.proxies // [])}]')
        items+=("$(jq -cn --arg n "$nname" --arg s "$status" --argjson d "$discovered" \
            --argjson r "$removed" --argjson g "${groups:-[]}" \
            '{name:$n, status:$s, discovered:$d, removed:$r, groups:$g}')")
    done
    NODE_ID="$_save_id" NODE_IDENTITY="$_save_identity" NODE_TAG="$_save_tag"
    NODE_NAME="$_save_node" SERVER_IP="$_save_ip" SERVER_PORT="$_save_port"
    SERVER_USER="$_save_user" SERVER_PASS="$_save_pass" SERVER_AUTH="$_save_auth"
    CONN_SYNC_JSON=$(printf '%s\n' "${items[@]}" | jq -sc --argjson ok "$ok" --argjson f "$failed" \
        --argjson t "${#nodes[@]}" --arg s "$stopped" \
        '{nodes:[.[] | select(. != null)], ok:$ok, failed:$f, total:$t,
          stopped_at:(if $s == "" then null else $s end)}')
    if (( failed > 0 )); then
        rc_fail partial "Синхронизировано: ${ok}/${#nodes[@]} нод."
        return 1
    fi
    (( ${#nodes[@]} == 0 )) || success "Синхронизировано: ${ok}/${#nodes[@]} нод"
    return 0
}

# core_conn_assign NODE GROUP_COUNT GROUP… PROXY…
# Назначает прокси ноды каждой группе; без прокси снимает назначение.
# Первая ошибка останавливает обработку; уже сохранённые группы остаются
# (partial). Сохранённые группы — CORE_CONN_ASSIGN_APPLIED.
core_conn_assign() {
    local node="${1:-}" count="${2:-}" i g p csv="" applied=0
    CORE_CONN_ASSIGN_APPLIED=()
    local -a groups=() proxies=()
    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( $# < count + 2 )); then
        rc_fail usage "Неверные аргументы назначения подключений."
        return 1
    fi
    shift 2
    for (( i = 0; i < count; i++ )); do
        groups+=("$1")
        shift
    done
    proxies=("$@")
    if (( count == 0 )); then
        rc_fail invalid "Не выбрана ни одна группа."
        return 1
    fi
    if [[ -z "$node" || "$(jq_r --arg n "$node" 'any(.nodes[]?; .name==$n)')" != true ]]; then
        rc_fail not_found "Нода '${node}' не найдена."
        return 1
    fi
    for g in "${groups[@]}"; do
        if [[ -z "$g" || "$(jq_r --arg g "$g" 'any(.groups[]?; .name==$g)')" != true ]]; then
            rc_fail not_found "Группа '${g}' не найдена."
            return 1
        fi
    done
    for p in "${proxies[@]}"; do
        if [[ -z "$p" || "$p" == *,* || "$p" == *$'\n'* ]]; then
            rc_fail invalid "Недопустимое имя подключения: '${p}'."
            return 1
        fi
        [[ -n "$csv" ]] && csv+=","
        csv+="$p"
    done
    for g in "${groups[@]}"; do
        if ! _save_connection "$node" "$g" "$csv"; then
            if (( applied > 0 )); then
                rc_fail partial "Назначение остановлено на группе '${g}'. Сохранено групп: $applied."
            else
                rc_fail failed "Назначение остановлено: группу '${g}' сохранить не удалось."
            fi
            return 1
        fi
        if [[ -n "$csv" ]]; then
            success "$node -> $g сохранено"
        else
            success "$node -> $g: назначение снято"
        fi
        applied=$((applied + 1))
        CORE_CONN_ASSIGN_APPLIED+=("$g")
    done
    return 0
}

_save_connection() {
    local nname="$1" group="$2" csv="$3"

    if [[ -z "$csv" ]]; then
        jq_w --arg n "$nname" --arg g "$group" '
            .connections |= map(if .node==$n then .groups |= [.[] | select(.name!=$g)] else . end)
            | .connections |= [.[] | select(.groups | length > 0)]'
        return
    fi

    local proxies_json
    proxies_json=$(echo "$csv" | tr ',' '\n' | jq -R . | jq -s .)

    jq_w --arg n "$nname" --arg g "$group" --argjson p "$proxies_json" '
        if any(.connections[]; .node==$n) then
            .connections |= map(if .node==$n then .groups = ([.groups[] | select(.name!=$g)] + [{name:$g, proxies:$p}]) else . end)
        else
            .connections += [{node:$n, groups:[{name:$g, proxies:$p}]}]
        end'
}

# ─── Вспомогательные функции ─────────────────────────────────────────────────

_extract_names_by_keyword() {
    local config="$1" keyword="$2"
    local names
    # Try PCRE first (extracts only quoted names)
    names=$(echo "$config" | grep -oP '(?<=name: ")[^"]+' 2>/dev/null | grep -i "$keyword")
    if [[ -z "$names" ]]; then
        # Fallback: try quoted names without PCRE
        names=$(echo "$config" | grep -i "name:.*\".*${keyword}" | sed 's/.*name: *"//;s/".*//' | sed 's/^ *//')
    fi
    if [[ -z "$names" ]]; then
        # Last resort: unquoted names
        names=$(echo "$config" | grep -i "name:.*${keyword}" | sed 's/.*name: *//;s/"//g' | sed 's/^ *//')
    fi
    echo "$names"
}


_discover_connections() {
    local remote_config
    # Нет client-config.txt (mihomo не настроен) — нода доступна, подключений нет.
    remote_config=$(ssh_run -- 'f=/etc/mihomo/client-config.txt; [ -e "$f" ] || exit 0; cat "$f"') || return

    {
        _extract_names_by_keyword "$remote_config" "vless"
        _extract_names_by_keyword "$remote_config" "hy2\|hysteria"
        echo "$remote_config" | grep -i 'name:.*cascade' | sed 's/.*name: *//;s/"//g' | sed 's/^ *//'
        if echo "$remote_config" | grep -q '^--- AmneziaWG ---'; then
            echo "AWG"
        fi
    } | grep -v '^$' | sort -u
}
