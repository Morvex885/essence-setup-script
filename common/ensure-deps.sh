#!/bin/bash
# ─── Авто-установка зависимостей (кросс-платформенно) ────────────────────────
# Используется runtime-скриптами (remote-control-essence, setup-essence) и
# установщиками после распаковки репозитория.
#
# API:
#   ensure_dep <binary> [<binary> ...]   — проверить и при необходимости поставить
#   detect_pm                             — записать имя PM в переменную $PM
#   pkg_name_for <binary>                 — вернуть имя пакета для текущего $PM
#   pm_install <package>                  — поставить пакет через $PM
#
# Зависит от функций info/success/warn/error, определённых в common.sh ИЛИ
# в вызывающем скрипте (bootstrap-режим установщика). Если их нет — создаём
# минимальные заглушки.

command -v info    &>/dev/null || info()    { echo -e "  [*] $*"; }
command -v success &>/dev/null || success() { echo -e "  [✓] $*"; }
command -v warn    &>/dev/null || warn()    { echo -e "  [!] $*" >&2; }
command -v error   &>/dev/null || error()   { echo -e "  [✗] $*" >&2; exit 1; }

PM="${PM:-}"
detect_pm() {
    if   command -v pkg     &>/dev/null && [[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]]; then PM=termux
    elif command -v apt-get &>/dev/null; then PM=apt
    elif command -v dnf     &>/dev/null; then PM=dnf
    elif command -v yum     &>/dev/null; then PM=yum
    elif command -v pacman  &>/dev/null; then PM=pacman
    elif command -v zypper  &>/dev/null; then PM=zypper
    elif command -v apk     &>/dev/null; then PM=apk
    elif command -v brew    &>/dev/null; then PM=brew
    fi
}
[[ -z "$PM" ]] && detect_pm

pkg_name_for() {
    local bin="$1"
    case "$bin:$PM" in
        ssh:apt|ssh:apk)                           echo "openssh-client" ;;
        ssh:dnf|ssh:yum)                           echo "openssh-clients" ;;
        ssh:pacman|ssh:brew|ssh:zypper|ssh:termux) echo "openssh" ;;
        openssl:termux)                            echo "openssl-tool" ;;
        *) echo "$bin" ;;
    esac
}

_need_sudo() {
    [[ $EUID -eq 0 ]] && { echo ""; return; }
    command -v sudo &>/dev/null && echo "sudo" || echo ""
}

_run_pm() {
    # Выполнить команду pm, сохранив вывод. При ошибке — вывалить его в stderr,
    # чтобы юзер увидел реальную причину (битое зеркало, 404, нет сети и т.п.).
    local out rc
    out=$("$@" 2>&1); rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" >&2
    fi
    return $rc
}

pm_install() {
    local pkg="$1" S
    S=$(_need_sudo)
    case "$PM" in
        termux) _run_pm pkg install -y "$pkg" ;;
        apt)
            local waited=0
            while $S fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock >/dev/null 2>&1; do
                (( waited == 0 )) && info "Ожидаем освобождения apt-лока..."
                sleep 2; waited=$((waited + 2))
                (( waited >= 120 )) && error "apt заблокирован более 2 минут."
            done
            _run_pm $S env DEBIAN_FRONTEND=noninteractive apt-get update -q \
                || warn "apt-get update завершился с ошибкой — продолжаем"
            _run_pm $S env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                -o Dpkg::Options::=--force-confold "$pkg"
            ;;
        dnf)    _run_pm $S dnf install -y -q "$pkg" ;;
        yum)    _run_pm $S yum install -y -q "$pkg" ;;
        pacman) _run_pm $S pacman -Sy --noconfirm --needed "$pkg" ;;
        zypper) _run_pm $S zypper --non-interactive --quiet install "$pkg" ;;
        apk)    _run_pm $S apk add --quiet --no-progress "$pkg" ;;
        brew)   _run_pm brew install "$pkg" ;;
        *) return 127 ;;
    esac
}

ensure_dep() {
    local bin
    for bin in "$@"; do
        command -v "$bin" &>/dev/null && continue

        [[ -z "$PM" ]] && error "Не найден поддерживаемый пакетный менеджер (apt/dnf/yum/pacman/zypper/apk/brew/termux). Установите ${bin} вручную."

        local pkg
        pkg=$(pkg_name_for "$bin")
        info "Отсутствует ${bin} — устанавливаем ${pkg} через ${PM}..."
        pm_install "$pkg" \
            || error "Не удалось автоматически установить ${pkg} через ${PM}. Установите вручную и повторите запуск."
        command -v "$bin" &>/dev/null || error "${bin} не появился в PATH после установки ${pkg}."
        success "${pkg} установлен"
    done
}
