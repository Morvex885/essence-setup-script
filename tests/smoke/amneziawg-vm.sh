#!/bin/bash
# Smoke install/start/remove только для одноразовой Debian/Ubuntu VM.
set -uo pipefail

if [[ "${AWG_SMOKE_CONFIRM:-}" != "disposable-vm" ]]; then
    echo "Запуск заблокирован: задайте AWG_SMOKE_CONFIRM=disposable-vm на одноразовой VM." >&2
    exit 2
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Запустите smoke-сценарий от root." >&2
    exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/common/common.sh"
source "$PROJECT_ROOT/setup-essence/modules/amneziawg.sh"

if [[ -f "$AWG_CONF" ]] || systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    warn "VM уже содержит конфигурацию или активный сервис AWG; smoke-тест ничего не изменил."
    exit 2
fi
if [[ ! -f "$AWG_MIHOMO_CONFIG" ]]; then
    warn "Сначала выполните базовую установку Mihomo на disposable VM."
    exit 2
fi

info "Smoke: install (дефолтный порт/DNS, без peer)..."
if ! printf '\n\ny\nn\n' | install_awg; then
    warn "Smoke install: FAIL"
    exit 1
fi

command -v awg >/dev/null 2>&1 || { warn "Smoke: awg не найден"; exit 1; }
command -v awg-quick >/dev/null 2>&1 || { warn "Smoke: awg-quick не найден"; exit 1; }
modinfo -k "$(uname -r)" amneziawg >/dev/null || { warn "Smoke: modinfo FAIL"; exit 1; }
systemctl is-active --quiet awg-quick@awg0 || { warn "Smoke: unit не активен"; exit 1; }
ip link show awg0 >/dev/null 2>&1 || { warn "Smoke: интерфейс awg0 отсутствует"; exit 1; }
success "Smoke install/start: OK"

info "Smoke: remove (пакеты и PPA по политике проекта останутся)..."
if ! printf 'y\n' | uninstall_awg; then
    warn "Smoke remove: FAIL"
    exit 1
fi
if [[ -f "$AWG_CONF" ]] || systemctl is-active --quiet awg-quick@awg0 2>/dev/null \
    || ip link show awg0 >/dev/null 2>&1; then
    warn "Smoke remove: осталась конфигурация, active-unit или интерфейс awg0"
    exit 1
fi
success "Smoke install/start/remove: OK"
