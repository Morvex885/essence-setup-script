#!/bin/bash
# ─── AWG Peers: обзор, создание, удаление, очистка ─────────────────────────

# Получить список клиентов, которым нужен AWG peer на ноде
_awg_expected_peers() {
    local nname="$1"
    # Клиенты, у которых в connections (групповых или своих) есть awg-* для этой ноды
    local peers=()

    # Групповые: ноды группы содержат nname + connections содержат awg-*
    while IFS='|' read -r cname cgroup cinherit cnodes; do
        local client_nodes="$cnodes"
        if [[ "$cinherit" == "true" ]]; then
            client_nodes=$(_group_nodes_csv "$cgroup")
        fi
        # Нода в списке клиента?
        echo ",$client_nodes," | grep -qF ",$nname," || continue
        # Есть awg-* подключение для этой ноды?
        local has_awg=false
        # Проверяем клиентские подключения
        local client_awg
        client_awg=$(jq_r --arg c "$cname" --arg n "$nname" \
            '.clients[] | select(.name==$c) | .connections // [] | .[] | select(.node==$n) | .proxies[] | select(. == "AWG" or startswith("awg-"))')
        if [[ -n "$client_awg" ]]; then
            has_awg=true
        else
            # Проверяем групповые подключения
            local group_awg
            group_awg=$(jq_r --arg n "$nname" --arg g "$cgroup" \
                '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies[] | select(. == "AWG" or startswith("awg-"))')
            [[ -n "$group_awg" ]] && has_awg=true
        fi
        $has_awg && peers+=("$cname")
    done < <(jq_r '.clients[] | "\(.name)|\(.group)|\(if .inherit_nodes_from_group == false then false else true end)|\(.nodes // [] | join(","))"')

    printf '%s\n' "${peers[@]}" | sort -u
}

_awg_peers_mutate() {
    ensure_remote_scripts_current || {
        warn "Не удалось подготовить скрипты для ноды '$NODE_NAME'."
        return 1
    }
    ssh_run -- "$1"
}

# Классифицирует peers ноды: EXISTING — имена на ноде, EXPECTED — имена из конфигурации.
# Заполняет AWG_STATUS_NAMES и AWG_STATUS_STATES (used | orphan | missing).
_awg_peers_classify() {
    local existing="$1" expected="$2" p
    AWG_STATUS_NAMES=()
    AWG_STATUS_STATES=()
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        AWG_STATUS_NAMES+=("$p")
        if printf '%s\n' "$expected" | grep -qxF "$p"; then
            AWG_STATUS_STATES+=("used")
        else
            AWG_STATUS_STATES+=("orphan")
        fi
    done <<< "$existing"
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! printf '%s\n' "$existing" | grep -qxF "$p"; then
            AWG_STATUS_NAMES+=("$p")
            AWG_STATUS_STATES+=("missing")
        fi
    done <<< "$expected"
}

# Загружает ноду по имени для AWG-core и проверяет SSH; ошибки — через rc_fail.
_awg_core_load_node() {
    local nname="$1" rc=0
    [[ -n "$nname" ]] || { rc_fail usage "Не указана нода."; return 1; }
    if [[ "$(jq_r --arg n "$nname" 'any(.nodes[]?; .name == $n)')" != true ]]; then
        rc_fail not_found "Нода '$nname' не найдена."
        return 1
    fi
    node_load_by_name "$nname" >/dev/null || rc=$?
    case "$rc" in
        0) ssh_probe; return ;;
        2) rc_fail missing_secret "Пароль SSH ноды '$nname' недоступен." ;;
        *) rc_fail failed "Не удалось загрузить ноду '$nname'." ;;
    esac
    return 1
}

# core_awg_status NODE — статус AmneziaWG и peers ноды без интерактивного подключения.
# Выставляет AWG_STATUS_INSTALLED (true|false), AWG_STATUS_NAMES, AWG_STATUS_STATES.
core_awg_status() {
    local nname="$1" check_result existing="" expected
    AWG_STATUS_INSTALLED=false
    AWG_STATUS_NAMES=()
    AWG_STATUS_STATES=()
    _awg_core_load_node "$nname" || return 1
    check_result=$(ssh_run -- "if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then echo NO_AWG; else echo AWG_OK; ls /etc/mihomo/amnezia/; fi") || {
        rc_fail remote_failed "Не удалось получить статус AmneziaWG на $nname."
        return 1
    }
    check_result="${check_result//$'\r'/}"
    [[ "$check_result" == NO_AWG ]] && return 0
    if [[ "$check_result" != AWG_OK && "$check_result" != AWG_OK$'\n'* ]]; then
        rc_fail remote_failed "Неожиданный ответ о статусе AmneziaWG на $nname."
        return 1
    fi
    [[ "$check_result" == *$'\n'* ]] && existing="${check_result#*$'\n'}"
    AWG_STATUS_INSTALLED=true
    expected=$(_awg_expected_peers "$nname")
    _awg_peers_classify "$existing" "$expected"
    return 0
}

# core_awg_create NODE NAME… — создать peers на ноде.
core_awg_create() {
    local nname="$1" cmd p
    shift
    _awg_core_load_node "$nname" || return 1
    [[ $# -gt 0 ]] || { rc_fail usage "Не указаны клиенты AmneziaWG."; return 1; }
    cmd="source $(printf '%q' "$REMOTE_DIR/modules/amneziawg.sh")"
    for p in "$@"; do
        [[ -n "$p" ]] || { rc_fail usage "Пустое имя клиента AmneziaWG."; return 1; }
        cmd="$cmd && add_awg_peer_auto $(printf '%q' "$p")"
    done
    _awg_peers_mutate "$cmd" || {
        rc_fail remote_failed "Не удалось создать клиентов AmneziaWG на $nname."
        return 1
    }
}

# Проверка целей удаления по свежему статусу ноды.
_awg_remove_validate() {
    local nname="$1" p i found
    shift
    [[ $# -gt 0 ]] || { rc_fail usage "Не указаны клиенты AmneziaWG."; return 1; }
    core_awg_status "$nname" || return 1
    if [[ "$AWG_STATUS_INSTALLED" != true ]]; then
        rc_fail invalid "AmneziaWG не установлен на $nname."
        return 1
    fi
    for p in "$@"; do
        [[ -n "$p" ]] || { rc_fail usage "Пустое имя клиента AmneziaWG."; return 1; }
        found=""
        for (( i=0; i<${#AWG_STATUS_NAMES[@]}; i++ )); do
            [[ "${AWG_STATUS_NAMES[$i]}" == "$p" ]] && found="${AWG_STATUS_STATES[$i]}"
        done
        if [[ -z "$found" || "$found" == missing ]]; then
            rc_fail invalid "Клиент $p ещё не создан на ноде."
            return 1
        fi
    done
}

# core_awg_remove_plan NODE NAME… — CORE_PLAN_LINES для удаления peers.
core_awg_remove_plan() {
    local nname="$1"
    shift
    CORE_PLAN_LINES=()
    _awg_remove_validate "$nname" "$@" || return 1
    CORE_PLAN_LINES=(
        "Нода: $nname ($SERVER_IP:$SERVER_PORT)"
        "Клиенты: $*"
        "Ключи будут удалены, доступ прекратится."
    )
}

# core_awg_remove NODE NAME… — удалить peers с ноды.
core_awg_remove() {
    local nname="$1" cmd p
    shift
    _awg_remove_validate "$nname" "$@" || return 1
    cmd="source $(printf '%q' "$REMOTE_DIR/modules/amneziawg.sh")"
    for p in "$@"; do
        cmd="$cmd && remove_awg_peer_by_name $(printf '%q' "$p")"
    done
    _awg_peers_mutate "$cmd" || {
        rc_fail remote_failed "Не удалось удалить клиентов AmneziaWG на $nname."
        return 1
    }
}
