#!/bin/bash
# Проверка настоящего systemd argv без production-служб и секретов.
set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/common/common.sh"
source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"

if [[ "${TPROXY_SMOKE_CONFIRM:-}" != isolated-unit ]]; then
    warn "Запуск заблокирован: задайте TPROXY_SMOKE_CONFIRM=isolated-unit."
    exit 2
fi
if [[ "$(uname -s)" != Linux || "$EUID" -ne 0 || ! -d /run/systemd/system ]]; then
    warn "Нужны root, Linux и работающий systemd; ничего не изменено."
    exit 2
fi
for bin in systemctl journalctl awk cmp mktemp; do
    command -v "$bin" >/dev/null 2>&1 || { warn "Не найден $bin; ничего не изменено."; exit 2; }
done
systemctl show --property=Version >/dev/null 2>&1 || {
    warn "systemd недоступен; ничего не изменено."
    exit 2
}
umask 077
smoke_dir=$(mktemp -d /tmp/essence-mtproxy-argv.XXXXXXXX) || exit 1
smoke_units=()
cleanup() {
    local unit rc=0
    for unit in "${smoke_units[@]}"; do
        systemctl stop "$unit" >/dev/null 2>&1 || rc=1
        rm -f "/run/systemd/system/$unit" || rc=1
        systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    done
    if [[ ${#smoke_units[@]} -gt 0 ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || rc=1
    fi
    rm -rf "$smoke_dir" || rc=1
    if [[ $rc -ne 0 ]]; then warn "Не удалось полностью очистить изолированные smoke units."; return 1; fi
}
trap 'rc=$?; trap - EXIT; cleanup || rc=1; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TPROXY_ENV_FILE="$smoke_dir/mtproxy.env"
secret=0123456789abcdef0123456789abcdef
tag=fedcba9876543210fedcba9876543210
cat > "$smoke_dir/probe" <<EOF
#!/bin/bash
printf '%s\\n' "\$@" > "$smoke_dir/actual"
EOF
chmod 0700 "$smoke_dir/probe" || exit 1
cat > "$smoke_dir/source.service" <<EOF
[Service]
Type=oneshot
Environment=MTPROXY_WORKERS=1
Environment=MTPROXY_MAX_CONNECTIONS=4096
ExecStart=$smoke_dir/probe -u mtproxy -p 8888 -H 2398 -S \${MTPROXY_SECRET} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS}
EOF
for smoke_case in empty tagged; do
    unit="essence-mtproxy-argv-$$-$smoke_case.service"
    target="/run/systemd/system/$unit"
    if [[ -e "$target" || -L "$target" ]] || systemctl cat "$unit" >/dev/null 2>&1; then
        warn "Имя тестового unit уже занято; smoke остановлен без перезаписи."
        exit 1
    fi
    tag_args=""
    [[ "$smoke_case" != tagged ]] || tag_args="-P $tag"
    printf 'MTPROXY_SECRET=%s\nMTPROXY_TAG_ARGS="%s"\n' "$secret" "$tag_args" > "$TPROXY_ENV_FILE"
    _telegram_proxy_render_mtproxy_unit "$smoke_dir/source.service" "$smoke_dir/rendered.service" || {
        warn "Renderer отказал для $smoke_case."; exit 1;
    }
    # noclobber prevents overwriting a name that appeared after the check.
    (set -C; : > "$target") || exit 1
    smoke_units+=("$unit")
    cat "$smoke_dir/rendered.service" > "$target" || exit 1
    rm -f "$smoke_dir/actual"
    since=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl daemon-reload && systemctl start "$unit" || {
        warn "Изолированный systemd запуск отказал для $smoke_case."; exit 1;
    }
    {
        printf '%s\n' -u mtproxy -p 8888 -H 2398 -S "$secret"
        if [[ "$smoke_case" == tagged ]]; then printf '%s\n' -P "$tag"; fi
        printf '%s\n' --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M 1 -C 4096
    } > "$smoke_dir/expected"
    cmp -s "$smoke_dir/expected" "$smoke_dir/actual" || {
        warn "systemd argv не совпал с ожидаемым для $smoke_case."; exit 1;
    }
    journalctl --since "$since" --no-pager -u "$unit" > "$smoke_dir/journal" || exit 1
    # Manager parser warnings may lack UNIT metadata; restrict them by filename.
    journalctl --since "$since" --no-pager _PID=1 > "$smoke_dir/manager-journal" || exit 1
    if grep -i 'unknown escape' "$smoke_dir/journal" >/dev/null ||
       { grep -F "$unit" "$smoke_dir/manager-journal" | grep -i 'unknown escape' >/dev/null; }; then
        warn "systemd сообщил unknown escape для тестового unit $smoke_case."
        exit 1
    fi
    success "systemd argv: $smoke_case — OK."
done
