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
