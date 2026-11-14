#!/usr/bin/env bats
# Исполнитель node-agent/apply.sh: заглушки команд через PATH, корень — ESSENCE_NODE_ROOT.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    ROOT="$BATS_TEST_TMPDIR/node"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CALLS="$BATS_TEST_TMPDIR/calls"
    AGENT="$ROOT/root/essence-node/agent/sha1"
    OPDIR="$ROOT/root/essence-node/ops/op1"
    export ESSENCE_NODE_ROOT="$ROOT" CALLS
    mkdir -p "$STUBS" "$AGENT/steps" "$AGENT/common" "$OPDIR/files" "$ROOT/usr/local/bin" "$ROOT/etc/mihomo"
    : >"$CALLS"
    cp "$PROJECT_ROOT/node-agent/apply.sh" "$AGENT/"
    cp "$PROJECT_ROOT/node-agent/steps/"*.sh "$AGENT/steps/"
    cp "$PROJECT_ROOT/common/common.sh" "$PROJECT_ROOT/common/cert.sh" "$AGENT/common/"
    write_manifest

    local cmd
    for cmd in apt-get nginx curl sysctl getent openssl wget; do
        stub "$cmd" 'exit 0'
    done
    stub fuser 'exit 1'
    stub systemctl '[[ "$*" == "start mihomo" && -n "${HUP_ON_START:-}" ]] && kill -HUP "$PPID"
exit 0'
    stub ufw 'case "$1 ${2:-}" in
    "status "*) echo "Status: ${UFW_STATE:-active}" ;;
    "show added") echo "Added user rules (see ufw status for running firewall):"
        [[ -n "${UFW_ADDED:-}" ]] && printf "%s\n" "$UFW_ADDED" ;;
esac
exit 0'
    # ss -Htln: LISTEN на портах SS_PORTS, кроме SS_OMIT.
    stub ss 'for p in ${SS_PORTS-443 8443}; do
    [[ "$p" == "${SS_OMIT:-}" ]] && continue
    printf "LISTEN 0 4096 [::]:%s [::]:*\n" "$p"
done'
    cat >"$ROOT/usr/local/bin/mihomo" <<'SH'
#!/bin/bash
printf 'mihomo %s\n' "$*" >>"$CALLS"
[[ "$1" == -v ]] && { echo "Mihomo Meta v1.19.18 linux amd64"; exit 0; }
[[ "$1" == -t ]] && exit "${MIHOMO_T_RC:-0}"
exit 0
SH
    chmod +x "$ROOT/usr/local/bin/mihomo"
    export PATH="$STUBS:$PATH"
    write_spec
}

teardown() {
    exec 8>&- 2>/dev/null || true
    teardown_test_env
}

stub() {
    printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$CALLS"\n%s\n' "$1" "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

write_manifest() {
    (cd "$AGENT" && find . -type f ! -name MANIFEST -printf '%P\n' | sort | xargs sha256sum >MANIFEST)
}

write_spec() {
    cat >"$OPDIR/spec.sh" <<EOF
OP_ID='op1'
OP_MODE='${MODE:-apply}'
SSH_PORTS='${SSH_PORTS_SPEC:-2222}'
LISTEN_TCP='443 8443'
MIHOMO_VERSION='v1.19.18'
NGINX='${NGINX_ON:-false}'
NGINX_STREAM='false'
SITE_NAME=''
SITE_SOURCE=''
SITE_REQUIRE_200=''
CERTS=''
ACME_EMAIL=''
DNS_DOMAINS=''
HY2_CERT='false'
HY2_CN=''
UFW_RULES='${RULES-443/tcp}'
RELEASE_CERTS='${RELEASE-}'
FEATURES=''
REMOVE_FEATURES=''
EOF
}

# line_of <точная строка> — номер первой такой строки в $CALLS.
line_of() {
    grep -nxF -- "$1" "$CALLS" | head -n1 | cut -d: -f1
}

# add_file <путь> <содержимое>
add_file() {
    mkdir -p "$OPDIR/files$(dirname "$1")"
    printf '%s\n' "$2" >"$OPDIR/files$1"
    printf '0600 %s %s %s\n' "$(id -un)" "$(id -gn)" "$1" >>"$OPDIR/files.list"
}

run_agent() {
    run bash "$AGENT/apply.sh" "$OPDIR"
}

status() { cat "$OPDIR/status"; }

# Остались только status и log.
assert_scrubbed() {
    [[ -f "$OPDIR/status" && -f "$OPDIR/log" ]]
    [[ ! -e "$OPDIR/files" && ! -e "$OPDIR/backup" ]]
}

@test "успешное применение фиксирует файлы и пишет committed" {
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    run status
    assert_line "stage=cleanup"
    assert_line "result=committed"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == new ]]
    [[ "$(stat -c %a "$ROOT/etc/mihomo/config.yaml")" == 600 ]]
    grep -qx "systemctl start mihomo" "$CALLS"
    grep -qx "ufw allow 443/tcp" "$CALLS"
    assert_scrubbed
    [[ "$(stat -c %a "$ROOT/root/essence-node")" == 700 ]]
    [[ "$(stat -c %a "$ROOT/root/essence-node/ops")" == 700 ]]
    [[ "$(stat -c %a "$OPDIR")" == 700 ]]
}

@test "mihomo -t с ошибкой откатывает транзакцию" {
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    add_file /etc/mihomo/extra.yaml "extra"
    MIHOMO_T_RC=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=config"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == old ]]
    [[ ! -e "$ROOT/etc/mihomo/extra.yaml" ]]
    ! grep -q "^ufw allow 443" "$CALLS"
    assert_scrubbed
}

@test "занятая блокировка даёт failed/locked" {
    exec 8>"$ROOT/root/essence-node/lock"
    flock -n 8
    run_agent
    assert_failure
    run status
    assert_line "result=failed"
    assert_line "error=locked"
    ! grep -q "^apt-get" "$CALLS"
}

@test "SIGHUP во время config откатывает изменения" {
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    HUP_ON_START=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "stage=config"
    assert_line "result=rolled_back"
    assert_line "error=config"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == old ]]
}

@test "правила UFW сходятся к списку и не трогают чужие" {
    printf '8443/tcp\n51820/udp\n' >"$ROOT/root/essence-node/ufw-rules"
    RULES="443/tcp 51820/udp" write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    grep -qx "ufw allow 443/tcp" "$CALLS"
    grep -qx "ufw delete allow 8443/tcp" "$CALLS"
    ! grep -q "51820" "$CALLS"
    ! grep -q -- "--force reset" "$CALLS"
    ! grep -q "ufw default" "$CALLS"
    [[ "$(sort "$ROOT/root/essence-node/ufw-rules")" == $'443/tcp\n51820/udp' ]]
}

@test "неактивный UFW включается со всеми SSH-портами" {
    SSH_PORTS_SPEC="2222 22" write_spec
    add_file /etc/mihomo/config.yaml "new"
    UFW_STATE=inactive run bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    [[ -n "$(line_of "ufw allow 2222/tcp")" && -n "$(line_of "ufw allow 22/tcp")" ]]
    (($(line_of "ufw allow 22/tcp") < $(line_of "ufw default deny incoming")))
    (($(line_of "ufw allow 2222/tcp") < $(line_of "ufw --force enable")))
}

@test "teardown удаляет каталог, mihomo и свои правила UFW" {
    printf '443/tcp\n' >"$ROOT/root/essence-node/ufw-rules"
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n' >"$OPDIR/remove.list"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    [[ ! -e "$ROOT/etc/mihomo" ]]
    [[ ! -e "$ROOT/usr/local/bin/mihomo" ]]
    grep -qx "systemctl disable --now mihomo" "$CALLS"
    grep -qx "ufw delete allow 443/tcp" "$CALLS"
}

@test "cleanup оставляет пять операций и только текущий исполнитель" {
    local i
    for i in 1 2 3 4 5 6 7; do
        mkdir -p "$ROOT/root/essence-node/ops/old$i"
        touch -d "2020-01-0$i" "$ROOT/root/essence-node/ops/old$i"
    done
    mkdir -p "$ROOT/root/essence-node/agent/stale"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ "$(ls "$ROOT/root/essence-node/ops" | wc -l)" == 5 ]]
    [[ -d "$OPDIR" && -d "$AGENT" ]]
    [[ ! -e "$ROOT/root/essence-node/agent/stale" ]]
}

@test "занятая блокировка apt по истечении ожидания даёт failed/packages" {
    stub fuser 'exit 0'
    AGENT_APT_WAIT_SECONDS=2 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "stage=packages"
    assert_line "result=failed"
    assert_line "error=packages"
    ! grep -q "^apt-get" "$CALLS"
}

@test "удаление файла /etc/nginx при NGINX=false перечитывает nginx" {
    mkdir -p "$ROOT/etc/nginx/sites-enabled"
    printf 'old\n' >"$ROOT/etc/nginx/sites-enabled/stale"
    printf '/etc/nginx/sites-enabled/stale\n' >"$OPDIR/remove.list"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ ! -e "$ROOT/etc/nginx/sites-enabled/stale" ]]
    grep -qx "nginx -t" "$CALLS"
    grep -qx "systemctl reload nginx" "$CALLS"
    ! grep -qx "systemctl restart nginx" "$CALLS"
}

@test "без HOME исполнитель применяет операцию" {
    add_file /etc/mihomo/config.yaml "new"
    run env -u HOME bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    run status
    assert_line "result=committed"
}

@test "teardown отключает mihomo до удаления файла юнита" {
    stub systemctl 'if [[ "$1" == disable && ! -e "$ESSENCE_NODE_ROOT/etc/systemd/system/mihomo.service" ]]; then
    echo "Failed to disable unit, unit mihomo.service does not exist." >&2
    exit 1
fi
exit 0'
    mkdir -p "$ROOT/etc/systemd/system"
    printf '[Unit]\n' >"$ROOT/etc/systemd/system/mihomo.service"
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n/etc/systemd/system/mihomo.service\n' >"$OPDIR/remove.list"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    [[ ! -e "$ROOT/etc/systemd/system/mihomo.service" && ! -e "$ROOT/etc/mihomo" ]]
    grep -qx "systemctl disable --now mihomo" "$CALLS"
    (($(line_of "systemctl disable --now mihomo") < $(line_of "systemctl daemon-reload")))
}

@test "порты передаются: stop mihomo → nginx → start mihomo → проверка LISTEN" {
    NGINX_ON=true write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    local stop restart start check
    stop=$(line_of "systemctl stop mihomo")
    restart=$(line_of "systemctl restart nginx")
    start=$(line_of "systemctl start mihomo")
    check=$(line_of "ss -Htln")
    [[ -n "$stop" && -n "$restart" && -n "$start" && -n "$check" ]]
    ((stop < restart && restart < start && start < check))
    ! grep -qx "systemctl restart mihomo" "$CALLS"
}

@test "порт из LISTEN_TCP не слушается — откат" {
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    SS_OMIT=8443 AGENT_LISTEN_WAIT_SECONDS=2 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=config"
    grep -qF "Порт 8443 не слушается." "$OPDIR/log"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == old ]]
    assert_scrubbed
}

@test "teardown удаляет чужие операции и все исполнители, оставляя status и log" {
    mkdir -p "$ROOT/root/essence-node/ops/old1/files" "$ROOT/root/essence-node/agent/stale"
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n' >"$OPDIR/remove.list"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    [[ "$(ls "$ROOT/root/essence-node/ops")" == op1 ]]
    [[ -z "$(ls "$ROOT/root/essence-node/agent")" ]]
    assert_scrubbed
}

@test "путь вне управляемого набора в remove.list отклоняется до удаления" {
    mkdir -p "$ROOT/root/x"
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    printf '/etc/mihomo/config.yaml\n/root/x\n' >"$OPDIR/remove.list"
    run_agent
    assert_failure
    run status
    assert_line "result=failed"
    assert_line "error=config"
    [[ -d "$ROOT/root/x" && "$(cat "$ROOT/etc/mihomo/config.yaml")" == cfg ]]
}

@test "teardown с «..» в remove.list ничего не удаляет" {
    mkdir -p "$ROOT/etc/x"
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n/etc/mihomo/../x\n' >"$OPDIR/remove.list"
    run_agent
    assert_failure
    run status
    assert_line "result=failed"
    [[ -d "$ROOT/etc/x" && -f "$ROOT/etc/mihomo/config.yaml" && -x "$ROOT/usr/local/bin/mihomo" ]]
    ! grep -q "^systemctl disable" "$CALLS"
}

@test "RELEASE_CERTS с пробелом или glob отклоняется без удаления" {
    mkdir -p "$ROOT/var/www/a" "$ROOT/var/www/keep"
    add_file /etc/mihomo/config.yaml "new"
    local bad
    for bad in 'a b:/var/www/a b' '*:/var/www/*' 'a:/var/www/a/../keep'; do
        RELEASE="$bad" write_spec
        add_file /etc/mihomo/config.yaml "new"
        run_agent
        assert_failure
        run status
        assert_line "result=failed"
        assert_line "error=cleanup"
        [[ -d "$ROOT/var/www/a" && -d "$ROOT/var/www/keep" ]]
    done
}

@test "существовавшее правило UFW не попадает в учёт и не удаляется teardown" {
    add_file /etc/mihomo/config.yaml "new"
    UFW_ADDED="ufw allow 443/tcp" run bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    ! grep -qx "ufw allow 443/tcp" "$CALLS"
    [[ ! -s "$ROOT/root/essence-node/ufw-rules" ]]
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n' >"$OPDIR/remove.list"
    UFW_ADDED="ufw allow 443/tcp" run bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    ! grep -q "ufw delete" "$CALLS"
}

@test "подключаются только этапы из MANIFEST, без MANIFEST — сбой init" {
    printf 'stage_packages() { : >"%s/evil"; }\n' "$BATS_TEST_TMPDIR" >"$AGENT/steps/zz-evil.sh"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/evil" ]]
    rm -f "$AGENT/MANIFEST"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_failure
    run status
    assert_line "stage=init"
    assert_line "result=failed"
}
