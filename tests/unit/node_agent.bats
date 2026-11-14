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

    local cmd
    for cmd in apt-get nginx curl sysctl getent openssl wget; do
        stub "$cmd" 'exit 0'
    done
    stub fuser 'exit 1'
    stub systemctl '[[ "$*" == "restart mihomo" && -n "${HUP_ON_RESTART:-}" ]] && { unset HUP_ON_RESTART; kill -HUP "$PPID"; }
exit 0'
    stub ufw '[[ "$1" == status ]] && { echo "Status: ${UFW_STATE:-active}"; }
exit 0'
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

write_spec() {
    cat >"$OPDIR/spec.sh" <<EOF
OP_ID='op1'
OP_MODE='${MODE:-apply}'
SSH_PORT='2222'
MIHOMO_VERSION='v1.19.18'
NGINX='false'
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
RELEASE_CERTS=''
FEATURES=''
REMOVE_FEATURES=''
EOF
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

@test "успешное применение фиксирует файлы и пишет committed" {
    add_file /etc/mihomo/config.yaml "new"
    run_agent
    assert_success
    run status
    assert_line "stage=cleanup"
    assert_line "result=committed"
    [[ "$(cat "$ROOT/etc/mihomo/config.yaml")" == new ]]
    [[ "$(stat -c %a "$ROOT/etc/mihomo/config.yaml")" == 600 ]]
    grep -qx "systemctl restart mihomo" "$CALLS"
    grep -qx "ufw allow 443/tcp" "$CALLS"
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
    HUP_ON_RESTART=1 run bash "$AGENT/apply.sh" "$OPDIR"
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

@test "неактивный UFW включается с разрешённым SSH-портом" {
    add_file /etc/mihomo/config.yaml "new"
    UFW_STATE=inactive run bash "$AGENT/apply.sh" "$OPDIR"
    assert_success
    grep -qx "ufw allow 2222/tcp" "$CALLS"
    grep -qx "ufw --force enable" "$CALLS"
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
