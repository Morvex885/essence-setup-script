#!/bin/bash
# ─── Essence node executor ──────────────────────────────────────────────────
# bash apply.sh <каталог операции>
# Сводит ноду к описанию из <op>/spec.sh, <op>/files.list, <op>/remove.list.
# Без вопросов и чтения stdin. Состояние — <op>/status, журнал — <op>/log.
# Все абсолютные пути ноды идут через префикс ${ESSENCE_NODE_ROOT:-} (тесты).

set -uo pipefail
umask 077
# systemd-run без User= не задаёт HOME, а cert.sh читает его под set -u.
: "${HOME:=/root}"
export HOME

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
# Службы, работавшие до открытия транзакции (tx_open).
TX_ACTIVE=""
# Свои правила UFW, добавленные и удалённые этой операцией («правило\n»).
FW_ADDED=""
FW_DELETED=""

# status: запись целиком через tmp + mv.
write_status() {
    local tmp="$OP/.status.tmp"
    {
        printf 'stage=%s\n' "$STAGE"
        if [[ -n "$RESULT" ]]; then printf 'result=%s\n' "$RESULT"; fi
        if [[ -n "$ERROR" ]]; then printf 'error=%s\n' "$ERROR"; fi
    } >"$tmp" && mv -f "$tmp" "$OP/status"
}

# После записи результата в каталоге операции остаются только status и log:
# files/ и backup/ содержат ключи и пароли, mihomo.new — скачанный бинарник.
# После незавершённого отката backup/ остаётся: это последняя копия прежних файлов.
scrub_op() {
    rm -rf -- "$OP/files" "$OP/mihomo.new"
    if [[ "$RESULT" != rollback_failed ]]; then
        rm -rf -- "$OP/backup"
    fi
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
            if tx_rollback; then
                RESULT=rolled_back
            else
                RESULT=rollback_failed
                warn "Откат не завершён: резервные копии сохранены в $OP/backup."
            fi
        else
            RESULT=failed
        fi
        write_status
        warn "Операция завершилась: $RESULT ($ERROR)"
    fi
    scrub_op
    exit "$rc"
}

trap 'exit 1' HUP INT TERM
trap finish EXIT
write_status

mkdir -p "$NODE_DIR" || exit 1
NODE_DIR="$(cd "$NODE_DIR" && pwd -P)" || exit 1
chmod 700 "$NODE_DIR" "$OP" || exit 1
if [[ -d "$NODE_DIR/ops" ]]; then
    chmod 700 "$NODE_DIR/ops" || exit 1
fi
chmod -R go-rwx "$OP" || exit 1

# shellcheck source=/dev/null
source "$AGENT_DIR/common/common.sh" || exit 1
# shellcheck source=/dev/null
source "$AGENT_DIR/common/cert.sh" || exit 1
# Подключаются только этапы из MANIFEST («<sha256>  <относительный путь>»).
if [[ ! -f "$AGENT_DIR/MANIFEST" ]]; then
    warn "Нет MANIFEST исполнителя."
    exit 1
fi
_steps=()
while IFS= read -r _step; do
    _steps+=("$_step")
done < <(awk '$2 ~ /^steps\/[A-Za-z0-9_.-]+\.sh$/ { print $2 }' "$AGENT_DIR/MANIFEST" | sort -u)
for _step in "${_steps[@]}"; do
    # shellcheck source=/dev/null
    source "$AGENT_DIR/$_step" || exit 1
done
unset _step _steps

if [[ ! -f "$OP/spec.sh" ]]; then
    warn "Нет spec.sh."
    exit 1
fi
# shellcheck source=/dev/null
source "$OP/spec.sh" || exit 1
: "${OP_ID:=}" "${OP_MODE:=apply}" "${SSH_PORTS:=22}" "${LISTEN_TCP:=}" "${MIHOMO_VERSION:=}" "${NGINX:=false}"
: "${NGINX_STREAM:=false}" "${SITE_NAME:=}" "${SITE_SOURCE:=random}" "${SITE_REQUIRE_200:=false}" "${CERTS:=}"
: "${ACME_EMAIL:=}" "${DNS_DOMAINS:=}" "${HY2_CERT:=false}" "${HY2_CN:=}" "${UFW_RULES:=}" "${RELEASE_CERTS:=}"
: "${FEATURES:=}" "${REMOVE_FEATURES:=}" "${WARP:=}"

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

# Транзакция, открытая этапом config, закрывается только здесь: сбой firewall
# или проверки cleanup откатывает конфигурацию. Необратимая очистка — после
# записи committed и на итог не влияет.
TX_OPEN=false
RESULT=committed
write_status
scrub_op
cleanup_committed
# Teardown убирает и сам исполнитель: функции уже загружены, а bash
# дочитывает этот скрипт из открытого дескриптора.
if [[ "$OP_MODE" == teardown && "$AGENT_DIR" == "$NODE_DIR/agent/"* ]]; then
    rm -rf -- "$AGENT_DIR"
fi
success "Операция $OP_ID применена."
exit 0
