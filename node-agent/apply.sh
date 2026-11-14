#!/bin/bash
# ─── Essence node executor ──────────────────────────────────────────────────
# bash apply.sh <каталог операции>
# Сводит ноду к описанию из <op>/spec.sh, <op>/files.list, <op>/remove.list.
# Без вопросов и чтения stdin. Состояние — <op>/status, журнал — <op>/log.
# Все абсолютные пути ноды идут через префикс ${ESSENCE_NODE_ROOT:-} (тесты).

set -uo pipefail
umask 077

OP="${1:-}"
if [[ -z "$OP" || ! -d "$OP" ]]; then
    printf 'usage: apply.sh <каталог операции>\n' >&2
    exit 2
fi
OP="$(cd "$OP" && pwd -P)"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
R="${ESSENCE_NODE_ROOT:-}"
NODE_DIR="$R/root/essence-node"

exec </dev/null >>"$OP/log" 2>&1

STAGE=init
RESULT=""
ERROR=""
TX_OPEN=false
TX_PATHS=()

# status: запись целиком через tmp + mv.
write_status() {
    local tmp="$OP/.status.tmp"
    {
        printf 'stage=%s\n' "$STAGE"
        if [[ -n "$RESULT" ]]; then printf 'result=%s\n' "$RESULT"; fi
        if [[ -n "$ERROR" ]]; then printf 'error=%s\n' "$ERROR"; fi
    } >"$tmp" && mv -f "$tmp" "$OP/status"
}

stage() {
    STAGE="$1"
    write_status
    info "Этап: $STAGE"
}

# feature_hook <фича> <prepare|activate|rollback|remove> — только если определён.
feature_hook() {
    local fn="${1}_${2}"
    declare -F "$fn" >/dev/null || return 0
    "$fn"
}

finish() {
    local rc=$?
    trap '' HUP INT TERM
    trap - EXIT
    if [[ -z "$RESULT" ]]; then
        ERROR="${ERROR:-$STAGE}"
        if [[ "$TX_OPEN" == true ]]; then
            tx_rollback
            RESULT=rolled_back
        else
            RESULT=failed
        fi
        write_status
        warn "Операция завершилась: $RESULT ($ERROR)"
    fi
    exit "$rc"
}

trap 'exit 1' HUP INT TERM
trap finish EXIT
write_status

# shellcheck source=/dev/null
source "$AGENT_DIR/common/common.sh" || exit 1
# shellcheck source=/dev/null
source "$AGENT_DIR/common/cert.sh" || exit 1
for _step in "$AGENT_DIR"/steps/*.sh; do
    # shellcheck source=/dev/null
    source "$_step" || exit 1
done
unset _step

if [[ ! -f "$OP/spec.sh" ]]; then
    warn "Нет spec.sh."
    exit 1
fi
# shellcheck source=/dev/null
source "$OP/spec.sh" || exit 1
: "${OP_ID:=}" "${OP_MODE:=apply}" "${SSH_PORT:=22}" "${MIHOMO_VERSION:=}" "${NGINX:=false}" "${NGINX_STREAM:=false}"
: "${SITE_NAME:=}" "${SITE_SOURCE:=random}" "${SITE_REQUIRE_200:=false}" "${CERTS:=}" "${ACME_EMAIL:=}"
: "${DNS_DOMAINS:=}" "${HY2_CERT:=false}" "${HY2_CN:=}" "${UFW_RULES:=}" "${RELEASE_CERTS:=}"
: "${FEATURES:=}" "${REMOVE_FEATURES:=}" "${WARP:=}"

mkdir -p "$NODE_DIR" || exit 1
exec 9>"$NODE_DIR/lock" || exit 1
if ! flock -n 9; then
    RESULT=failed
    ERROR=locked
    write_status
    warn "Другая операция уже выполняется."
    exit 1
fi

case "$OP_MODE" in
    apply)
        stage packages;    stage_packages    || exit 1
        stage system;      stage_system      || exit 1
        stage mihomo;      stage_mihomo      || exit 1
        stage dns;         stage_dns         || exit 1
        stage site;        stage_site        || exit 1
        stage certificate; stage_certificate || exit 1
        stage prepare;     stage_prepare     || exit 1
        stage config;      stage_config      || exit 1
        stage firewall;    stage_firewall "$UFW_RULES" || exit 1
        stage cleanup;     stage_cleanup     || exit 1
        ;;
    teardown)
        stage config;      stage_teardown_config || exit 1
        stage firewall;    stage_firewall "" || exit 1
        stage cleanup;     stage_cleanup     || exit 1
        ;;
    *)
        warn "Неизвестный OP_MODE: $OP_MODE"
        exit 1
        ;;
esac

RESULT=committed
write_status
success "Операция $OP_ID применена."
exit 0
