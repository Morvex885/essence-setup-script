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
MIHOMO_VERSION='${MIHOMO_SPEC:-v1.19.18}'
NGINX='${NGINX_ON:-false}'
NGINX_STREAM='false'
SITE_NAME='${SITE-}'
SITE_SOURCE=''
SITE_REQUIRE_200=''
CERTS=''
ACME_EMAIL=''
DNS_DOMAINS=''
HY2_CERT='false'
HY2_CN=''
UFW_RULES='${RULES-443/tcp}'
RELEASE_CERTS='${RELEASE-}'
FEATURES='${FEATURES_SPEC-}'
REMOVE_FEATURES='${REMOVE_SPEC-}'
${SPEC_EXTRA-}
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

@test "apt-get исполнителя идёт с NEEDRESTART_MODE=l и NEEDRESTART_SUSPEND=1" {
    stub apt-get 'printf "apt-env %s %s\n" "${NEEDRESTART_MODE:-unset}" "${NEEDRESTART_SUSPEND:-unset}" >>"$CALLS"; exit 0'
    add_file /etc/mihomo/config.yaml "new"
    NEEDRESTART_MODE= NEEDRESTART_SUSPEND= run_agent
    assert_success
    grep -q "^apt-env " "$CALLS"
    # Ни одного вызова без обеих переменных.
    if grep "^apt-env " "$CALLS" | grep -vqx "apt-env l 1"; then return 1; fi
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
    ! grep -q "^ufw allow 443" "$CALLS" || return 1
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
    UFW_ADDED="ufw allow 51820/udp" run bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    grep -qx "ufw allow 443/tcp" "$CALLS"
    grep -qx "ufw delete allow 8443/tcp" "$CALLS"
    ! grep -q "51820" "$CALLS" || return 1
    ! grep -q -- "--force reset" "$CALLS" || return 1
    ! grep -q "ufw default" "$CALLS" || return 1
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
    mkdir -p "$ROOT/etc/systemd/system"
    printf '[Unit]\n' >"$ROOT/etc/systemd/system/mihomo.service"
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
    ln -s /etc/nginx/sites-available/stale "$ROOT/etc/nginx/sites-enabled/stale"
    printf '/etc/nginx/sites-enabled/stale\n' >"$OPDIR/remove.list"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ ! -e "$ROOT/etc/nginx/sites-enabled/stale" && ! -L "$ROOT/etc/nginx/sites-enabled/stale" ]]
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

@test "teardown без юнита mihomo (первое применение прервалось до config) завершается" {
    stub systemctl 'if [[ "$1" == disable && ! -e "$ESSENCE_NODE_ROOT/etc/systemd/system/mihomo.service" ]]; then
    echo "Failed to disable unit, unit mihomo.service does not exist." >&2
    exit 1
fi
exit 0'
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n/etc/systemd/system/mihomo.service\n' >"$OPDIR/remove.list"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    [[ ! -e "$ROOT/etc/mihomo" ]]
    ! grep -q "^systemctl disable" "$CALLS" || return 1
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
        assert_line "result=rolled_back"
        assert_line "error=cleanup"
        [[ -d "$ROOT/var/www/a" && -d "$ROOT/var/www/keep" ]]
    done
}

@test "существовавшее правило UFW не попадает в учёт и не удаляется teardown" {
    add_file /etc/mihomo/config.yaml "new"
    UFW_ADDED="ufw allow 443/tcp" run bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    ! grep -qx "ufw allow 443/tcp" "$CALLS" || return 1
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

@test "сбой ufw delete не теряет добавленное правило: teardown убирает всё" {
    # ufw с правилами в файле: show added печатает «ufw allow <правило>».
    stub ufw 'db="$(dirname "$CALLS")/ufw.db"; touch "$db"
case "$1" in
    status) echo "Status: active" ;;
    show) sed "s/^/ufw allow /" "$db" ;;
    allow) grep -qxF -- "$2" "$db" || printf "%s\n" "$2" >>"$db" ;;
    delete) [[ -n "${UFW_DELETE_FAIL:-}" ]] && exit 1
        grep -vxF -- "$3" "$db" >"$db.tmp"; mv "$db.tmp" "$db" ;;
esac
exit 0'
    local db="$BATS_TEST_TMPDIR/ufw.db" ledger="$ROOT/root/essence-node/ufw-rules"
    RULES="1111/tcp" write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ "$(cat "$ledger")" == 1111/tcp ]]

    RULES="2222/tcp" write_spec
    add_file /etc/mihomo/config.yaml "new"
    UFW_DELETE_FAIL=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "error=firewall"
    [[ "$(cat "$ledger")" == $'1111/tcp\n2222/tcp' ]]

    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ "$(cat "$ledger")" == 2222/tcp && "$(cat "$db")" == 2222/tcp ]]

    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n' >"$OPDIR/remove.list"
    run_agent
    assert_success
    [[ ! -s "$ledger" && ! -s "$db" ]]
}

@test "чужие сайты nginx в remove.list пропускаются, свои удаляются" {
    local av="$ROOT/etc/nginx/sites-available" en="$ROOT/etc/nginx/sites-enabled"
    mkdir -p "$av" "$en"
    printf '# Essence site ours.example\nserver {}\n' >"$av/ours.example"
    printf 'server {}\n' >"$av/shop.example"
    printf '# Essence site other.example\n' >"$av/wrong.example"
    ln -s /etc/nginx/sites-available/ours.example "$en/ours.example"
    ln -s /etc/nginx/sites-available/other "$en/shop.example"
    printf '%s\n' /etc/nginx/sites-available/ours.example /etc/nginx/sites-enabled/ours.example \
        /etc/nginx/sites-available/shop.example /etc/nginx/sites-enabled/shop.example \
        /etc/nginx/sites-available/wrong.example /etc/nginx/sites-available/absent.example >"$OPDIR/remove.list"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    [[ ! -e "$av/ours.example" && ! -L "$en/ours.example" ]]
    [[ -f "$av/shop.example" && -L "$en/shop.example" && -f "$av/wrong.example" ]]
    grep -qF "Пропускаю /etc/nginx/sites-available/shop.example" "$OPDIR/log"
    grep -qF "Пропускаю /etc/nginx/sites-enabled/shop.example" "$OPDIR/log"
}

@test "RELEASE_CERTS без .essence-site не снимает сертификат и не удаляет webroot" {
    mkdir -p "$ROOT/var/www/shop.example"
    RELEASE="shop.example:/var/www/shop.example" write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    [[ -d "$ROOT/var/www/shop.example" ]]
    grep -qF "Пропускаю сертификат shop.example" "$OPDIR/log"
}

@test "modules-enabled кроме 90-essence-stream.conf отклоняется" {
    mkdir -p "$ROOT/etc/nginx/modules-enabled"
    printf 'x\n' >"$ROOT/etc/nginx/modules-enabled/other.conf"
    printf '/etc/nginx/modules-enabled/other.conf\n' >"$OPDIR/remove.list"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_failure
    run status
    assert_line "result=failed"
    assert_line "error=config"
    [[ -f "$ROOT/etc/nginx/modules-enabled/other.conf" ]]
}

@test "учтённое правило, которого нет в UFW, добавляется заново" {
    printf '443/tcp\n' >"$ROOT/root/essence-node/ufw-rules"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    grep -qx "ufw allow 443/tcp" "$CALLS"
    [[ "$(cat "$ROOT/root/essence-node/ufw-rules")" == 443/tcp ]]
}

@test "сбой ufw allow откатывает конфигурацию" {
    stub ufw 'case "$1" in
    status) echo "Status: active" ;;
    allow) exit 1 ;;
esac
exit 0'
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=firewall"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == old ]]
    assert_scrubbed
}

@test "сбой ufw delete в teardown возвращает mihomo и конфигурацию" {
    stub ufw 'case "$1" in
    status) echo "Status: active" ;;
    delete) exit 1 ;;
esac
exit 0'
    printf '443/tcp\n' >"$ROOT/root/essence-node/ufw-rules"
    printf 'cfg\n' >"$ROOT/etc/mihomo/config.yaml"
    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n' >"$OPDIR/remove.list"
    run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=firewall"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == cfg && -x "$ROOT/usr/local/bin/mihomo" ]]
    grep -qx "systemctl enable mihomo" "$CALLS"
}

@test "незавершённый откат пишет rollback_failed и сохраняет backup" {
    # cp отказывает после sysctl этапа config: восстановление файла не удаётся.
    local real_cp flag="$BATS_TEST_TMPDIR/cp-fail"
    real_cp=$(command -v cp)
    stub cp "[[ -e '$flag' ]] && exit 1
exec '$real_cp' \"\$@\""
    stub sysctl ": >'$flag'"
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    MIHOMO_T_RC=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rollback_failed"
    assert_line "error=config"
    [[ "$(cat "$OPDIR/backup/etc/mihomo/config.yaml")" == old ]]
    [[ ! -e "$OPDIR/files" ]]
    grep -qF "Откат не завершён" "$OPDIR/log"
}

@test "новый бинарник mihomo заменяется в транзакции и возвращается откатом" {
    # curl отдаёт «новый» mihomo, у которого проверка конфигурации падает.
    cat >"$STUBS/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$CALLS"
if [[ "$1" == -fLo ]]; then
    printf '#!/bin/bash\nprintf "new-mihomo %%s\\n" "$*" >>"$CALLS"\n[[ "$1" == -t ]] && exit 1\nexit 0\n' | gzip >"$2"
fi
exit 0
SH
    chmod +x "$STUBS/curl"
    local bin="$ROOT/usr/local/bin/mihomo"
    cp "$bin" "$BATS_TEST_TMPDIR/old-mihomo"
    MIHOMO_SPEC=v1.20.0 write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=config"
    grep -q "^new-mihomo -t" "$CALLS"
    cmp -s "$bin" "$BATS_TEST_TMPDIR/old-mihomo"
    [[ ! -e "$bin.new" && ! -e "$OPDIR/mihomo.new" ]]
    assert_scrubbed
}

@test "чужой сайт без .essence-site не заменяется" {
    mkdir -p "$ROOT/var/www/shop.example"
    printf 'shop\n' >"$ROOT/var/www/shop.example/index.html"
    SITE=shop.example write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_failure
    run status
    assert_line "result=failed"
    assert_line "error=site"
    [[ "$(cat "$ROOT/var/www/shop.example/index.html")" == shop ]]
    ! grep -q "^wget" "$CALLS"
}

# add_site <имя> — файл сайта и ссылка sites-enabled в files.list.
add_site() {
    add_file "/etc/nginx/sites-available/$1" "# Essence site $1"
    mkdir -p "$OPDIR/files/etc/nginx/sites-enabled"
    printf '/etc/nginx/sites-available/%s' "$1" >"$OPDIR/files/etc/nginx/sites-enabled/$1"
    printf 'link root root /etc/nginx/sites-enabled/%s\n' "$1" >>"$OPDIR/files.list"
}

@test "чужой сайт nginx с тем же именем не заменяется, свой обновляется" {
    local av="$ROOT/etc/nginx/sites-available" en="$ROOT/etc/nginx/sites-enabled"
    mkdir -p "$av" "$en"
    printf 'server { shop }\n' >"$av/shop.example"
    add_file /etc/mihomo/config.yaml "new"
    add_site shop.example
    run_agent
    assert_failure
    run status
    assert_line "result=failed"
    assert_line "error=config"
    [[ "$(cat "$av/shop.example")" == "server { shop }" && ! -e "$en/shop.example" && ! -L "$en/shop.example" ]]
    grep -qF "В /etc/nginx/sites-available/shop.example уже есть сайт nginx без отметки Essence" "$OPDIR/log"

    # Ссылка sites-enabled не на наш сайт — тоже чужая.
    printf '# Essence site shop.example\nold\n' >"$av/shop.example"
    ln -s /etc/nginx/sites-available/other "$en/shop.example"
    : >"$OPDIR/files.list"; rm -f "$OPDIR/status"
    add_file /etc/mihomo/config.yaml "new"
    add_site shop.example
    run_agent
    assert_failure
    [[ "$(readlink "$en/shop.example")" == /etc/nginx/sites-available/other ]]

    rm "$en/shop.example"
    : >"$OPDIR/files.list"; rm -f "$OPDIR/status"
    add_file /etc/mihomo/config.yaml "new"
    add_site shop.example
    run_agent
    assert_success
    [[ "$(cat "$av/shop.example")" == "# Essence site shop.example" ]]
    [[ "$(readlink "$en/shop.example")" == /etc/nginx/sites-available/shop.example ]]
}

@test "откат возвращает правила UFW: удалённое добавляется, добавленное снимается" {
    # ufw с правилами в файле; delete отказывает только для UFW_DELETE_FAIL_RULE.
    stub ufw 'db="$(dirname "$CALLS")/ufw.db"; touch "$db"
case "$1" in
    status) echo "Status: active" ;;
    show) sed "s/^/ufw allow /" "$db" ;;
    allow) grep -qxF -- "$2" "$db" || printf "%s\n" "$2" >>"$db" ;;
    delete) [[ "$3" == "${UFW_DELETE_FAIL_RULE:-}" ]] && exit 1
        grep -vxF -- "$3" "$db" >"$db.tmp"; mv "$db.tmp" "$db" ;;
esac
exit 0'
    local db="$BATS_TEST_TMPDIR/ufw.db" ledger="$ROOT/root/essence-node/ufw-rules"
    printf '1111/tcp\n2222/tcp\n' >"$db"
    printf '1111/tcp\n2222/tcp\n' >"$ledger"
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    RULES="3333/tcp" write_spec
    add_file /etc/mihomo/config.yaml "new"
    UFW_DELETE_FAIL_RULE=2222/tcp run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=firewall"
    grep -qx "ufw allow 3333/tcp" "$CALLS"
    grep -qx "ufw delete allow 1111/tcp" "$CALLS"
    [[ "$(sort "$db")" == $'1111/tcp\n2222/tcp' ]]
    [[ "$(cat "$ledger")" == $'1111/tcp\n2222/tcp' ]]
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == old ]]
}

@test "cleanup не удаляет операцию с rollback_failed ни в apply, ни в teardown" {
    local ops="$ROOT/root/essence-node/ops" i
    for i in 1 2 3 4 5 6 7; do
        mkdir -p "$ops/old$i"
        touch -d "2020-01-0$i" "$ops/old$i"
    done
    mkdir -p "$ops/bad/backup/etc/mihomo"
    printf 'stage=config\nresult=rollback_failed\nerror=config\n' >"$ops/bad/status"
    printf 'old\n' >"$ops/bad/backup/etc/mihomo/config.yaml"
    touch -d "2019-01-01" "$ops/bad"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ -f "$ops/bad/backup/etc/mihomo/config.yaml" && ! -e "$ops/old1" ]]

    MODE=teardown RULES="" write_spec
    printf '/etc/mihomo\n' >"$OPDIR/remove.list"
    run_agent
    assert_success
    [[ -f "$ops/bad/backup/etc/mihomo/config.yaml" && ! -e "$ops/old7" ]]
    grep -qF "Оставляю операцию bad" "$OPDIR/log"
}

@test "сбой до committed не трогает снимаемые сертификат, webroot и фичи" {
    stub ufw 'case "$1" in
    status) echo "Status: active" ;;
    allow) exit 1 ;;
esac
exit 0'
    mkdir -p "$ROOT/var/www/shop.example"
    : >"$ROOT/var/www/shop.example/.essence-site"
    RELEASE="shop.example:/var/www/shop.example" write_spec
    printf '%s\n' "REMOVE_FEATURES='boom'" 'boom_remove() { : >"$ESSENCE_NODE_ROOT/removed"; }' >>"$OPDIR/spec.sh"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=firewall"
    [[ -e "$ROOT/var/www/shop.example/.essence-site" && ! -e "$ROOT/removed" ]]
}

@test "сбой очистки после committed — предупреждение, итог committed" {
    printf '%s\n' "REMOVE_FEATURES='boom'" 'boom_remove() { return 1; }' >>"$OPDIR/spec.sh"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    grep -qF "Не удалось снять фичу boom." "$OPDIR/log"
}

# systemctl с состоянием mihomo в файле; MIHOMO_START_FAIL — start не поднимает.
stub_stateful_systemctl() {
    stub systemctl 'f="$(dirname "$CALLS")/mihomo.on"
case "$1 ${2:-} ${3:-}" in
    "is-active --quiet mihomo") [[ -e "$f" ]]; exit ;;
    "stop mihomo "*) rm -f "$f" ;;
    "start mihomo "*) [[ -n "${MIHOMO_START_FAIL:-}" ]] || touch "$f" ;;
esac
exit 0'
}

@test "mihomo работал до операции и не поднялся после отката — rollback_failed" {
    stub_stateful_systemctl
    : >"$BATS_TEST_TMPDIR/mihomo.on"
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    add_file /etc/mihomo/config.yaml "new"
    MIHOMO_T_RC=1 MIHOMO_START_FAIL=1 AGENT_ACTIVE_WAIT_SECONDS=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rollback_failed"
    assert_line "error=config"
    grep -qF "Служба mihomo работала до операции" "$OPDIR/log"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == old ]]
}

@test "mihomo не работал до операции — откат без него считается завершённым" {
    stub_stateful_systemctl
    add_file /etc/mihomo/config.yaml "new"
    MIHOMO_T_RC=1 MIHOMO_START_FAIL=1 AGENT_ACTIVE_WAIT_SECONDS=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=config"
    ! grep -qF "Служба mihomo работала до операции" "$OPDIR/log"
}

# ─── Фича awg: awg_activate ─────────────────────────────────────────────────

# awg_call <код> — функции исполнителя с $R, $OP в окружении теста.
awg_call() {
    run bash -c 'R="$1"; OP="$2"; source "$3/common/common.sh"; for f in "$3"/steps/*.sh; do source "$f"; done; eval "$4"' \
        _ "$ROOT" "$OPDIR" "$AGENT" "$1"
}

awg_files() {
    stub ip '[[ "$*" == "link show awg0" ]] && exit "${AWG_DOWN:-0}"; exit 0'
    stub awg 'exit 0'
    stub awg-quick '[[ "$1" == strip ]] && echo stripped; exit 0'
    mkdir -p "$ROOT/etc/amnezia/amneziawg" "$OPDIR/backup/etc/amnezia/amneziawg"
    printf '[Interface]\nListenPort = %s\n# peer: b\n[Peer]\nPublicKey = B\n' "$1" >"$ROOT/etc/amnezia/amneziawg/awg0.conf"
    printf '[Interface]\nListenPort = 40000\n# peer: a\n[Peer]\nPublicKey = A\n' >"$OPDIR/backup/etc/amnezia/amneziawg/awg0.conf"
}

@test "awg_activate: изменились только пиры — syncconf без перезапуска" {
    awg_files 40000
    awg_call awg_activate
    assert_success
    grep -qx "awg syncconf awg0 /dev/fd/63" "$CALLS" || grep -q "^awg syncconf awg0" "$CALLS"
    ! grep -q "restart awg-quick@awg0" "$CALLS" || return 1
    grep -qx "sysctl -w net.ipv4.ip_forward=1" "$CALLS"
}

@test "awg_activate: изменился интерфейс или он не поднят — перезапуск" {
    awg_files 41000
    awg_call awg_activate
    assert_success
    grep -qx "systemctl restart awg-quick@awg0" "$CALLS"
    ! grep -q "^awg syncconf" "$CALLS" || return 1
    : >"$CALLS"
    awg_files 40000
    AWG_DOWN=1 awg_call awg_activate
    grep -qx "systemctl restart awg-quick@awg0" "$CALLS"
    ! grep -q "^awg syncconf" "$CALLS"
}

@test "awg_rollback: перезапуск только при изменённом транзакцией awg0.conf; awg_remove удаляет каталог" {
    awg_files 41000
    mkdir -p "$OPDIR/files/etc/amnezia/amneziawg"
    cp "$ROOT/etc/amnezia/amneziawg/awg0.conf" "$OPDIR/files/etc/amnezia/amneziawg/awg0.conf"
    # awg0.conf вне транзакции — AWG не трогается.
    awg_call 'TX_PATHS=(/etc/mihomo/config.yaml); TX_DEACTIVATED=""; awg_rollback'
    assert_success
    ! grep -q "awg-quick@awg0" "$CALLS" || return 1
    # В транзакции и изменён (порт 41000 против копии с 40000) — прежний конфиг перезапускается.
    awg_call 'TX_PATHS=(/etc/amnezia/amneziawg/awg0.conf); TX_DEACTIVATED=""; awg_rollback'
    grep -qx "systemctl enable awg-quick@awg0" "$CALLS"
    grep -qx "systemctl restart awg-quick@awg0" "$CALLS"
    # В транзакции, но совпадает с копией — перезапуска нет.
    : >"$CALLS"
    cp "$OPDIR/backup/etc/amnezia/amneziawg/awg0.conf" "$OPDIR/files/etc/amnezia/amneziawg/awg0.conf"
    awg_call 'TX_PATHS=(/etc/amnezia/amneziawg/awg0.conf); TX_DEACTIVATED=""; awg_rollback'
    ! grep -q "awg-quick@awg0" "$CALLS" || return 1
    awg_call awg_remove
    assert_success
    [[ ! -e "$ROOT/etc/amnezia" ]]
}

@test "откат по чужой причине не перезапускает работающий awg0" {
    awg_real_stubs
    printf 'awg_prepare() { :; }\n' >>"$AGENT/steps/awg.sh"
    write_manifest
    mkdir -p "$ROOT/etc/amnezia/amneziawg"
    printf '[Interface]\n' >"$ROOT/etc/amnezia/amneziawg/awg0.conf"
    add_file /etc/mihomo/config.yaml "new"
    add_file /etc/amnezia/amneziawg/awg0.conf "[Interface]"
    FEATURES_SPEC=awg write_spec
    MIHOMO_T_RC=1 run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    ! grep -q "awg-quick@awg0" "$CALLS" || return 1
    [[ -e "$AWG_UP" ]]
}

@test "откат после awg_deactivate поднимает AmneziaWG с восстановленным конфигом" {
    awg_real_stubs
    mkdir -p "$ROOT/etc/amnezia/amneziawg"
    printf '[Interface]\nListenPort = 40000\n' >"$ROOT/etc/amnezia/amneziawg/awg0.conf"
    printf '/etc/amnezia/amneziawg/awg0.conf\n' >"$OPDIR/remove.list"
    add_file /etc/mihomo/config.yaml "new"
    RULES="" REMOVE_SPEC=awg write_spec
    # mihomo -t отклоняет конфиг уже после снятия и удаления awg0.conf.
    MIHOMO_T_RC=1 run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    assert_line "error=config"
    [[ "$(cat "$ROOT/etc/amnezia/amneziawg/awg0.conf")" == $'[Interface]\nListenPort = 40000' ]]
    local down restart
    down=$(line_of "systemctl disable --now awg-quick@awg0")
    restart=$(line_of "systemctl restart awg-quick@awg0")
    [[ -n "$down" && -n "$restart" && "$down" -lt "$restart" ]]
    grep -qx "systemctl enable awg-quick@awg0" "$CALLS"
}

# awg_real_stubs — awg-quick, как настоящий, без конфига в /etc не находит
# интерфейс; ExecStop юнита (`disable --now`) — тот же `awg-quick down awg0`.
awg_real_stubs() {
    export AWG_UP="$BATS_TEST_TMPDIR/awg0-up"
    stub awg-quick 'conf="$2"; [[ "$conf" == */* ]] || conf="$ESSENCE_NODE_ROOT/etc/amnezia/amneziawg/$conf.conf"
[[ -f "$conf" ]] || { echo "FAILED $*" >>"$CALLS"; exit 1; }
rm -f "$AWG_UP"; exit 0'
    stub ip '[[ "$*" == "link show awg0" && -e "$AWG_UP" ]]'
    stub systemctl 'if [[ "$*" == "disable --now awg-quick@awg0" && -e "$AWG_UP" ]]; then awg-quick down awg0 || true; fi
exit 0'
    : >"$AWG_UP"
}

@test "снятие awg: интерфейс опускается до удаления awg0.conf (apply и teardown)" {
    local mode
    for mode in apply teardown; do
        : >"$CALLS"
        rm -rf "$OPDIR"; mkdir -p "$OPDIR/files"
        awg_real_stubs
        mkdir -p "$ROOT/etc/amnezia/amneziawg"
        printf '[Interface]\nListenPort = 40000\n' >"$ROOT/etc/amnezia/amneziawg/awg0.conf"
        printf '/etc/amnezia/amneziawg/awg0.conf\n' >"$OPDIR/remove.list"
        [[ "$mode" == apply ]] && add_file /etc/mihomo/config.yaml "new"
        MODE=$mode RULES="" REMOVE_SPEC=awg write_spec
        run_agent
        assert_success
        run status
        assert_line "result=committed"
        ! grep -q "^FAILED" "$CALLS" || return 1
        grep -qx "awg-quick down awg0" "$CALLS"
        [[ ! -e "$AWG_UP" && ! -e "$ROOT/etc/amnezia" ]]
    done
}

@test "сбой первой установки awg опускает интерфейс по конфигу операции" {
    awg_real_stubs
    # Пакеты и подъём интерфейса — вне теста; интерфейс уже поднят.
    printf 'awg_prepare() { :; }\nawg_activate() { :; }\n' >>"$AGENT/steps/awg.sh"
    write_manifest
    add_file /etc/mihomo/config.yaml "new"
    add_file /etc/amnezia/amneziawg/awg0.conf "[Interface]"
    FEATURES_SPEC=awg write_spec
    # Готовность (ss) не прошла: откат.
    SS_OMIT=8443 AGENT_LISTEN_WAIT_SECONDS=1 run_agent
    assert_failure
    run status
    assert_line "result=rolled_back"
    ! grep -q "^FAILED" "$CALLS" || return 1
    grep -q "^awg-quick down .*/files/etc/amnezia/amneziawg/awg0.conf$" "$CALLS"
    grep -qx "systemctl disable --now awg-quick@awg0" "$CALLS"
    [[ ! -e "$AWG_UP" && ! -e "$ROOT/etc/amnezia/amneziawg/awg0.conf" ]]
}

@test "ключ PPA: в keyring попадает только ключ с закреплённым отпечатком" {
    command -v gpg >/dev/null || skip "нет gpg"
    local home="$BATS_TEST_TMPDIR/gpg" fpr
    mkdir -m 700 "$home"
    gpg --batch --homedir "$home" --passphrase '' --quick-gen-key 'Pinned <p@example.com>' ed25519 sign never 2>/dev/null
    gpg --batch --homedir "$home" --passphrase '' --quick-gen-key 'Extra <e@example.com>' ed25519 sign never 2>/dev/null
    fpr=$(gpg --batch --homedir "$home" --with-colons --list-keys p@example.com | awk -F: '$1 == "fpr" { print $10; exit }')
    gpg --batch --homedir "$home" --armor --export >"$BATS_TEST_TMPDIR/both.asc"
    gpg --batch --homedir "$home" --armor --export e@example.com >"$BATS_TEST_TMPDIR/extra.asc"
    mkdir -p "$BATS_TEST_TMPDIR/tx"
    awg_call "AWG_PPA_FINGERPRINT=$fpr; _awg_pinned_keyring '$BATS_TEST_TMPDIR/both.asc' '$BATS_TEST_TMPDIR/out.gpg' '$BATS_TEST_TMPDIR/tx'"
    assert_success
    [[ "$(gpg --batch --show-keys --with-colons "$BATS_TEST_TMPDIR/out.gpg" | awk -F: '$1 == "pub"' | wc -l)" -eq 1 ]]
    gpg --batch --show-keys --with-colons "$BATS_TEST_TMPDIR/out.gpg" | grep -q "^fpr:::::::::$fpr:"
    [[ -z "$(ls -A "$BATS_TEST_TMPDIR/tx")" ]]
    awg_call "AWG_PPA_FINGERPRINT=$fpr; _awg_pinned_keyring '$BATS_TEST_TMPDIR/extra.asc' '$BATS_TEST_TMPDIR/out.gpg' '$BATS_TEST_TMPDIR/tx'"
    assert_failure
}

@test "awg: в репозиториях нет headers текущего ядра — подсказка kernel_headers в status" {
    stub gpg 'exit 0'
    stub apt-cache 'echo "  Candidate: (none)"'
    awg_call 'AWG_KERNEL=9.9.9-test; _awg_bootstrap_dependencies; echo "rc=$? hint=$HINT"'
    [[ "$output" == *"rc=1 hint=kernel_headers"* ]]
    [[ "$output" == *"перезагрузите сервер"* ]]
}

@test "awg: из .sources уходит только строфа Amnezia, поля остальных не разделяются" {
    local src="$ROOT/etc/apt/sources.list.d/mixed.sources"
    mkdir -p "$(dirname "$src")"
    printf '%s\n' 'Types: deb' 'URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu' 'Suites: noble' \
        'Components: main' '' 'Types: deb' 'URIs: http://archive.ubuntu.com/ubuntu' 'Suites: noble noble-updates' \
        'Components: main universe' >"$src"
    awg_call 'AWG_TMP_BASE="$R"; _awg_repo_begin && _awg_remove_conflicting_sources && _awg_repo_commit'
    assert_success
    [[ "$(cat "$src")" == $'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble noble-updates\nComponents: main universe' ]]
}

@test "awg: сигнал посреди транзакции PPA возвращает sources, после неё — прежний обработчик" {
    local dir="$ROOT/etc/apt/sources.list.d"
    mkdir -p "$dir"
    printf 'old amnezia\n' >"$dir/amnezia.sources"
    # Как в apply.sh: сигнал — exit 1, затем EXIT-обработчик.
    awg_call 'AWG_TMP_BASE="$R"; trap "exit 1" HUP INT TERM; trap "echo finish" EXIT
        _awg_repo_begin && _awg_prepare_repository_sources || exit 3
        [[ ! -e "$R/etc/apt/sources.list.d/amnezia.sources" ]] || exit 4
        kill -TERM $$; echo "не прервано"'
    [[ "$status" -eq 1 ]]
    [[ "$output" == finish ]]
    [[ "$(cat "$dir/amnezia.sources")" == "old amnezia" ]]
    [[ -z "$(find "$ROOT" -maxdepth 1 -name 'awg-repo.*')" ]]

    awg_call 'AWG_TMP_BASE="$R"; trap "exit 1" HUP INT TERM
        _awg_repo_begin && _awg_repo_commit && trap -p TERM'
    assert_success
    [[ "$output" == "trap -- 'exit 1' SIGTERM" ]]
}

@test "подсказка шага попадает в status вместе с ошибкой этапа" {
    printf 'awg_prepare() { HINT=kernel_headers; return 1; }\n' >"$AGENT/steps/zz-hint.sh"
    write_manifest
    FEATURES_SPEC=awg write_spec
    run_agent
    run status
    assert_line "result=failed"
    assert_line "error=prepare"
    assert_line "hint=kernel_headers"
}

# ─── Фича sub: хост подписок ────────────────────────────────────────────────

@test "sub_prepare: каталоги данных, сниппетов и webroot; без SUB_HOST — отказ" {
    stub chown 'exit 0'
    stub setfacl 'exit 0'
    awg_call 'SUB_HOST=sub.example.com; sub_prepare'
    assert_success
    [[ -d "$ROOT/var/www/sub.example.com" && -d "$ROOT/etc/nginx/snippets/essence-sub" ]]
    [[ "$(stat -c %a "$ROOT/var/lib/essence-sub")" == 2750 ]]
    [[ "$(stat -c %a "$ROOT/etc/nginx/snippets/essence-sub")" == 755 ]]
    grep -qx "chown root:www-data $ROOT/var/lib/essence-sub" "$CALLS"
    grep -qx "setfacl -d -m g:www-data:r $ROOT/var/lib/essence-sub" "$CALLS"
    awg_call 'SUB_HOST=; sub_prepare'
    assert_failure
}

# sub_timer_stub — systemctl, как настоящий, не включает и не отключает таймер
# без файла юнита.
sub_timer_stub() {
    stub systemctl 'if [[ "$*" == *able*essence-sub-cleanup.timer && ! -f "$ESSENCE_NODE_ROOT/etc/systemd/system/essence-sub-cleanup.timer" ]]; then
    echo "FAILED $*" >>"$CALLS"; exit 1
fi
exit 0'
}

@test "sub_activate включает таймер; откат первой установки останавливает его и убирает ссылку" {
    sub_timer_stub
    mkdir -p "$ROOT/etc/systemd/system/timers.target.wants"
    : >"$ROOT/etc/systemd/system/essence-sub-cleanup.timer"
    awg_call sub_activate
    assert_success
    grep -qx "systemctl enable --now essence-sub-cleanup.timer" "$CALLS"
    # Транзакция уже удалила новый юнит.
    rm "$ROOT/etc/systemd/system/essence-sub-cleanup.timer"
    ln -s /etc/systemd/system/essence-sub-cleanup.timer "$ROOT/etc/systemd/system/timers.target.wants/essence-sub-cleanup.timer"
    : >"$CALLS"
    awg_call sub_rollback
    grep -qx "systemctl stop essence-sub-cleanup.timer" "$CALLS"
    ! grep -q "^FAILED" "$CALLS" || return 1
    [[ ! -L "$ROOT/etc/systemd/system/timers.target.wants/essence-sub-cleanup.timer" ]]
}

@test "снятие sub: таймер отключается до удаления юнитов, каталоги удаляются" {
    sub_timer_stub
    mkdir -p "$ROOT/var/lib/essence-sub" "$ROOT/etc/nginx/snippets/essence-sub" "$ROOT/etc/systemd/system"
    : >"$ROOT/etc/systemd/system/essence-sub-cleanup.timer"
    : >"$ROOT/etc/systemd/system/essence-sub-cleanup.service"
    printf '%s\n' /etc/systemd/system/essence-sub-cleanup.timer /etc/systemd/system/essence-sub-cleanup.service >"$OPDIR/remove.list"
    add_file /etc/mihomo/config.yaml "new"
    REMOVE_SPEC=sub write_spec
    run_agent
    assert_success
    run status
    assert_line "result=committed"
    ! grep -q "^FAILED" "$CALLS" || return 1
    grep -qx "systemctl disable --now essence-sub-cleanup.timer" "$CALLS"
    [[ ! -e "$ROOT/etc/systemd/system/essence-sub-cleanup.timer" ]]
    [[ ! -e "$ROOT/var/lib/essence-sub" && ! -e "$ROOT/etc/nginx/snippets/essence-sub" ]]
}

@test "отметка .essence-sub не удаляется в config и подтверждает снятие сертификата хоста подписок" {
    mkdir -p "$ROOT/var/www/sub.example" "$ROOT/var/www/shop.example"
    : >"$ROOT/var/www/sub.example/.essence-sub"
    awg_call 'removable /var/www/sub.example/.essence-sub'
    assert_failure
    awg_call 'release_cert() { printf "release %s\n" "$1" >>"$CALLS"; }
        AGENT_DIR="$3"; NODE_DIR="$R/root/essence-node"; OP_MODE=apply; HY2_CERT=true; WARP=""; REMOVE_FEATURES=""
        RELEASE_CERTS="sub.example:/var/www/sub.example shop.example:/var/www/shop.example"; stage_cleanup && cleanup_committed'
    assert_success
    grep -qx "release sub.example" "$CALLS"
    ! grep -qx "release shop.example" "$CALLS" || return 1
    [[ ! -e "$ROOT/var/www/sub.example" && -d "$ROOT/var/www/shop.example" ]]
}

@test "essence-sub-cleanup: истёкшая ссылка снимается с YAML и сниппетом, запись срока остаётся" {
    local sub="$ROOT/var/lib/essence-sub" snip="$ROOT/etc/nginx/snippets/essence-sub" script="$BATS_TEST_TMPDIR/cleanup"
    local old new list
    old=$(printf 'a%.0s' {1..64}) new=$(printf 'b%.0s' {1..64})
    sed -e "s#{{sub_dir}}#$sub#" -e "s#^SNIP_DIR=.*#SNIP_DIR=$snip#" \
        "$PROJECT_ROOT/remote-control/core/src/server/assets/essence-sub-cleanup.sh" >"$script"
    stub flock 'exit 0'
    mkdir -p "$sub" "$snip"
    list=$(printf '%s 1\n%s 99999999999\nbad 1\n' "$old" "$new")
    printf '%s\n' "$list" >"$sub/expiry.list"
    touch "$sub/$old.yaml" "$snip/sub-$old.conf" "$sub/$new.yaml" "$snip/sub-$new.conf"
    run bash "$script"
    assert_success
    [[ ! -e "$sub/$old.yaml" && ! -e "$snip/sub-$old.conf" && -e "$sub/$new.yaml" && -e "$snip/sub-$new.conf" ]]
    [[ "$(cat "$sub/expiry.list")" == "$list" ]]
    [[ "$(grep -c '^nginx -t$' "$CALLS")" -eq 1 && "$(grep -cx 'systemctl reload nginx' "$CALLS")" -eq 1 ]]

    # Снимать нечего — nginx не трогается.
    : >"$CALLS"
    run bash "$script"
    assert_success
    ! grep -q nginx "$CALLS" || return 1

    # Повторная публикация без нового срока снова снимается; сбой nginx — код 1.
    touch "$sub/$old.yaml"
    stub nginx 'exit 1'
    run bash "$script"
    assert_failure
    [[ ! -e "$sub/$old.yaml" ]]
}

@test "отметка .essence-telegram не удаляется в config и подтверждает снятие сертификата Telegram" {
    mkdir -p "$ROOT/var/www/tg.example" "$ROOT/var/www/shop.example"
    : >"$ROOT/var/www/tg.example/.essence-telegram"
    awg_call 'removable /var/www/tg.example/.essence-telegram'
    assert_failure
    awg_call 'release_cert() { printf "release %s\n" "$1" >>"$CALLS"; }
        AGENT_DIR="$3"; NODE_DIR="$R/root/essence-node"; OP_MODE=apply; HY2_CERT=true; WARP=""; REMOVE_FEATURES=""
        RELEASE_CERTS="tg.example:/var/www/tg.example shop.example:/var/www/shop.example"; stage_cleanup && cleanup_committed'
    assert_success
    grep -qx "release tg.example" "$CALLS"
    if grep -qx "release shop.example" "$CALLS"; then return 1; fi
    [[ ! -e "$ROOT/var/www/tg.example" && -d "$ROOT/var/www/shop.example" ]]
}

# ─── Фича telegram в полном применении ──────────────────────────────────────

TG_SPEC="TG_HOST='tg.example' TG_REPO='https://example.com/t.git' TG_REVISION='rev1' TG_GO_VERSION='1.26.5' TG_GO_SHA256='x'"

# Компоненты ревизии rev1 уже стоят (сборка пропускается) и заглушки шага telegram.
telegram_node() {
    local path unit
    mkdir -p "$ROOT/opt/tproxy-server-source" "$ROOT/opt/MTProxy/objs/bin" "$ROOT/usr/local/sbin" "$ROOT/etc/mtproxy" \
        "$ROOT/srv/tproxy-site" "$ROOT/etc/systemd/system"
    echo rev1 >"$ROOT/opt/tproxy-server-source/.essence-revision"
    for path in usr/local/bin/tproxy-server opt/MTProxy/objs/bin/mtproto-proxy usr/local/sbin/refresh-mtproxy-config; do
        printf '#!/bin/bash\n' >"$ROOT/$path"; chmod +x "$ROOT/$path"
    done
    for unit in mtproxy.service tproxy-server.service tproxy-firewall.service refresh-mtproxy-config.service refresh-mtproxy-config.timer; do
        : >"$ROOT/etc/systemd/system/$unit"
    done
    echo s >"$ROOT/etc/mtproxy/proxy-secret"; echo c >"$ROOT/etc/mtproxy/proxy-multi.conf"
    echo site >"$ROOT/srv/tproxy-site/index.html"
    stub uname '[[ "$1" == -m ]] && echo x86_64; exit 0'
    # id <пользователь> — есть; id -un/-gn (владелец в add_file) — настоящий.
    stub id '[[ "${1:-}" == -* ]] && exec /usr/bin/id "$@"; exit 0'
    stub getent '[[ "$1" == passwd ]] && echo "$2:x:990:990::/nonexistent:/usr/sbin/nologin"; exit 0'
    stub chown 'exit 0'
    stub nft 'exit 0'
    stub install 'for a; do last="$a"; done; [[ " $* " == *" -d "* ]] && mkdir -p "$last"; exit 0'
    stub curl '[[ "$*" == *readyz* ]] && exit 7; exit 0'
}

@test "telegram: сбой первой активации выключает службы, метка фичи снимает компоненты следующим применением" {
    telegram_node
    FEATURES_SPEC=telegram SPEC_EXTRA="$TG_SPEC" write_spec
    add_file /etc/mtproxy/mtproxy.env "MTPROXY_SECRET=x"
    TG_READY_ATTEMPTS=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    grep -qx "systemctl enable --now tproxy-firewall.service mtproxy.service refresh-mtproxy-config.timer tproxy-server.service" "$CALLS"
    local enable disable
    enable=$(line_of "systemctl enable --now tproxy-firewall.service mtproxy.service refresh-mtproxy-config.timer tproxy-server.service")
    disable=$(line_of "systemctl disable --now refresh-mtproxy-config.timer tproxy-server.service mtproxy.service tproxy-firewall.service")
    [[ -n "$disable" ]] && ((enable < disable))
    [[ ! -e "$ROOT/etc/mtproxy/mtproxy.env" && -f "$ROOT/root/essence-node/features/telegram" ]]

    # Роль так и не зафиксирована и из описания ушла: cleanup снимает её по метке.
    rm -rf "$OPDIR"; mkdir -p "$OPDIR/files"; : >"$CALLS"
    write_spec
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    [[ ! -e "$ROOT/root/essence-node/features/telegram" && ! -e "$ROOT/usr/local/bin/tproxy-server" && ! -e "$ROOT/opt/MTProxy" ]]
    grep -qx "nft delete table inet tproxy_backend" "$CALLS"
}

@test "telegram: откат не из-за Telegram не трогает его службы" {
    telegram_node
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    FEATURES_SPEC=telegram SPEC_EXTRA="$TG_SPEC" write_spec
    add_file /etc/mihomo/config.yaml "new"
    MIHOMO_T_RC=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    if grep -q "mtproxy.service" "$CALLS"; then return 1; fi
    [[ -f "$ROOT/root/essence-node/features/telegram" ]]
}

@test "telegram: сборка MTProxy доступна пользователю mtproxy и после сборки под umask 077" {
    telegram_node
    chmod 0700 "$ROOT/opt/MTProxy/objs" "$ROOT/opt/MTProxy/objs/bin" "$ROOT/opt/MTProxy/objs/bin/mtproto-proxy"
    awg_call 'TG_HOST=tg.example TG_REPO=r TG_REVISION=rev1 TG_GO_VERSION=1 TG_GO_SHA256=x; NODE_DIR="$R/root/essence-node"; umask 077; telegram_prepare'
    assert_success
    [[ "$(stat -c %a "$ROOT/opt/MTProxy/objs/bin")" == 755 && "$(stat -c %a "$ROOT/opt/MTProxy/objs/bin/mtproto-proxy")" == 755 ]]
    grep -q "umask 022; bash \"\$backend_source/deploy/install-mtproxy.sh\"" "$AGENT/steps/telegram.sh"
}

@test "telegram: откат применения, снимавшего незафиксированные остатки, не включает службы снова" {
    telegram_node
    mkdir -p "$ROOT/root/essence-node/features" && : >"$ROOT/root/essence-node/features/telegram"
    printf 'old\n' >"$ROOT/etc/mihomo/config.yaml"
    write_spec
    add_file /etc/mihomo/config.yaml "new"
    MIHOMO_T_RC=1 run bash "$AGENT/apply.sh" "$OPDIR"
    assert_failure
    run status
    assert_line "result=rolled_back"
    local disable
    disable=$(grep -nxF "systemctl disable --now refresh-mtproxy-config.timer tproxy-server.service mtproxy.service tproxy-firewall.service" "$CALLS" | tail -n1 | cut -d: -f1)
    [[ -n "$disable" ]]
    # Повторного включения нет (`! grep` посреди теста bats не проверяет).
    if grep -q "enable --now tproxy-firewall.service\|restart mtproxy.service" "$CALLS"; then return 1; fi
    [[ -f "$ROOT/root/essence-node/features/telegram" ]]
}

# ─── Прогресс: progress= и detail= в status ─────────────────────────────────

# progress_call <код> — steps/progress.sh с write_status, дописывающим
# «progress|detail» в $WRITES; spec — по умолчанию без nginx и фич.
progress_call() {
    WRITES="$BATS_TEST_TMPDIR/writes"
    : >"$WRITES"
    run bash -c 'OP_MODE=apply NGINX=false SITE_NAME= CERTS= HY2_CERT=false FEATURES= WRITES="$2"
        source "$1/steps/progress.sh"
        write_status() { printf "%s|%s\n" "$PROGRESS" "$DETAIL" >>"$WRITES"; }
        progress_plan
        eval "$3"' _ "$PROJECT_ROOT/node-agent" "$WRITES" "$1"
}

@test "прогресс: полное применение пишет растущий progress до 100" {
    REAL_MV="$(command -v mv)"
    export REAL_MV PROGRESS_LOG="$BATS_TEST_TMPDIR/progress"
    # Каждая запись status (tmp → status) — снимок progress= в $PROGRESS_LOG.
    cat >"$STUBS/mv" <<'SH'
#!/bin/bash
target="${*: -1}"
if [[ "$target" == */status ]]; then
    sed -n 's/^progress=//p' "${*: -2:1}" >>"$PROGRESS_LOG"
fi
exec "$REAL_MV" "$@"
SH
    chmod +x "$STUBS/mv"
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    run status
    assert_line "progress=100"
    mapfile -t values <"$PROGRESS_LOG"
    ((${#values[@]} > 10))
    local previous=0 value
    for value in "${values[@]}"; do
        [[ "$value" =~ ^[0-9]+$ ]] && ((value >= previous && value <= 100)) || { echo "не монотонно: ${values[*]}"; return 1; }
        previous="$value"
    done
    [[ "${values[0]}" == 0 && "${values[-1]}" == 100 ]]
}

@test "прогресс: веса этапов растут с nginx, сертификатами и фичами и дают 0…100" {
    progress_call 'printf "%s\n" "${PROGRESS_STAGES[*]}" "${PROGRESS_BOUNDS[*]}"'
    assert_success
    assert_line --index 0 "packages system mihomo dns site certificate prepare config firewall cleanup"
    local bounds=(${lines[1]})
    [[ "${#bounds[@]}" == 11 && "${bounds[0]}" == 0 && "${bounds[10]}" == 100 ]]
    run bash -c 'OP_MODE=apply NGINX=true SITE_NAME=s CERTS="a:/var/www/a b:/var/www/b" HY2_CERT=true FEATURES="awg telegram"
        source "$1/steps/progress.sh"; progress_plan
        packages=$((PROGRESS_BOUNDS[1] - PROGRESS_BOUNDS[0])); prepare=$((PROGRESS_BOUNDS[7] - PROGRESS_BOUNDS[6]))
        certificate=$((PROGRESS_BOUNDS[6] - PROGRESS_BOUNDS[5])); system=$((PROGRESS_BOUNDS[2] - PROGRESS_BOUNDS[1]))
        ((prepare > packages && packages > certificate && certificate > system)) && echo ok' _ "$PROJECT_ROOT/node-agent"
    assert_output ok
    run bash -c 'OP_MODE=teardown; source "$1/steps/progress.sh"; progress_plan; echo "${PROGRESS_STAGES[*]}|${PROGRESS_BOUNDS[*]}"' \
        _ "$PROJECT_ROOT/node-agent"
    assert_output "config firewall cleanup|0 60 80 100"
}

@test "прогресс: apt Status-Fd ведёт процент этапа и detail «пакет: действие», процент не падает" {
    # apt-get пишет строки статуса в дескриптор из -o APT::Status-Fd=N.
    stub apt-get 'fd=""
for a; do [[ "$a" == APT::Status-Fd=* ]] && fd="${a#APT::Status-Fd=}"; done
[[ -n "$fd" ]] || exit 3
emit() { printf "%s\n" "$1" >&"$fd"; sleep 1.1; }
emit "dlstatus:1:50.0:Retrieving file 1 of 2"
emit "pmstatus:nginx:20.0:Preparing nginx (amd64)"
emit "pmstatus:nginx:amd64:60.5:Unpacking nginx (1.24.0-2)"
emit "pmstatus:amneziawg-dkms:80:Configuring amneziawg-dkms"
emit "pmstatus:x:10.0:Unpacking x"
emit "мусор без процента"
exit 0'
    progress_call 'progress_stage packages; agent_apt 0 100 install -y -q nginx; echo "rc=$? progress=$PROGRESS hi=$PROGRESS_STAGE_HI"'
    assert_success
    # Успех apt доводит процент до конца доли шага (здесь — всего этапа packages).
    [[ "$output" =~ rc=0\ progress=([0-9]+)\ hi=([0-9]+) ]]
    local final="${BASH_REMATCH[1]}"
    [[ "$final" == "${BASH_REMATCH[2]}" && "$final" -gt 0 ]]
    grep -q -- "^apt-get install -o APT::Status-Fd=3 -y -q nginx$" "$CALLS"
    local writes
    writes="$(cat "$WRITES")"
    [[ "$writes" == *"|загрузка пакетов"* ]]
    [[ "$writes" == *"|nginx: подготовка"* ]]
    [[ "$writes" == *"|nginx: распаковка"* ]]
    [[ "$writes" == *"|сборка модуля ядра amneziawg"* ]]
    mapfile -t values < <(cut -d'|' -f1 "$WRITES")
    local previous=0 value
    for value in "${values[@]}"; do
        ((value >= previous)) || { echo "не монотонно: ${values[*]}"; return 1; }
        previous="$value"
    done
    # Отложенное (та же секунда) дописывает progress_flush: последняя запись — конец доли.
    [[ "${values[-1]}" == "$final" ]]
}

@test "прогресс: сбой apt возвращает его код, процент не доходит до конца доли" {
    stub apt-get 'exit 100'
    progress_call 'progress_stage packages; agent_apt 0 100 update -q; echo "rc=$? progress=$PROGRESS lo=$PROGRESS_STAGE_LO"'
    assert_success
    [[ "$output" =~ rc=100\ progress=([0-9]+)\ lo=([0-9]+) ]]
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]
}

@test "прогресс: потомок apt с унаследованным Status-Fd не задерживает шаг" {
    # Скрипт пакета оставил фоновый процесс с дескриптором статуса (stdout/stderr закрыты, чтобы run не ждал его).
    stub apt-get 'fd=""
for a; do [[ "$a" == APT::Status-Fd=* ]] && fd="${a#APT::Status-Fd=}"; done
printf "%s\n" "pmstatus:nginx:50:Unpacking nginx" >&"$fd"
sleep 6 >/dev/null 2>&1 &
exit 7'
    progress_call 'progress_stage packages; start=$SECONDS; agent_apt 0 100 install -y nginx; rc=$?; echo "rc=$rc elapsed=$((SECONDS - start))"'
    assert_success
    [[ "$output" =~ rc=7\ elapsed=([0-9]+) ]]
    ((BASH_REMATCH[1] <= 3))
    grep -q "|nginx: распаковка" "$WRITES"
}

@test "прогресс: detail без управляющих символов и не длиннее 120 символов" {
    progress_call 'progress_detail "$(printf "nginx:\033[31m распаковка\a\r\n")"; long=$(printf "д%.0s" {1..200}); progress_detail "$long"'
    assert_success
    run cat "$WRITES"
    assert_line --index 0 "0|nginx:[31m распаковка"
    local second="${lines[1]#0|}"
    [[ "$(LC_ALL=C.UTF-8 bash -c 'printf %s "${#1}"' _ "$second")" == 120 ]]
    ! grep -q $'\033' "$WRITES"
}

@test "прогресс: только проценты пишутся не чаще раза в секунду, flush дописывает отложенное" {
    progress_call 'progress_stage packages; for i in $(seq 1 60); do progress_in "$i"; done; before=$(wc -l <"$WRITES"); progress_flush; echo "$before $PROGRESS"'
    assert_success
    local before="${output% *}" percent="${output#* }"
    ((before <= 2))
    [[ "$(tail -n1 "$WRITES" | cut -d'|' -f1)" == "$percent" ]]
}
