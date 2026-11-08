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
        ssh:apt|ssh:apk|scp:apt|scp:apk)
            echo "openssh-client" ;;
        ssh:dnf|ssh:yum|scp:dnf|scp:yum)
            echo "openssh-clients" ;;
        ssh:pacman|ssh:brew|ssh:zypper|ssh:termux|\
        scp:pacman|scp:brew|scp:zypper|scp:termux)
            echo "openssh" ;;
        openssl:termux)                            echo "openssl-tool" ;;
        base64:apt|base64:dnf|base64:yum|base64:pacman|base64:zypper|\
        base64:apk|base64:brew|base64:termux)
            echo "coreutils" ;;
        nft:apt)                                  echo "nftables" ;;
        systemctl:apt)                            echo "systemd" ;;
        useradd:apt)                              echo "passwd" ;;
        id:apt)                                   echo "coreutils" ;;
        runuser:apt)                              echo "util-linux" ;;
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
                sleep 2
                waited=$((waited + 2))
                if (( waited >= 120 )); then
                    warn "apt заблокирован более 2 минут."
                    return 1
                fi
            done
            _run_pm $S env DEBIAN_FRONTEND=noninteractive apt-get update -q || return 1
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
        if [[ -z "$PM" ]]; then
            warn "Не найден поддерживаемый пакетный менеджер для ${bin}."
            return 1
        fi
        local pkg
        pkg=$(pkg_name_for "$bin")
        info "Отсутствует ${bin} — устанавливаем ${pkg} через ${PM}..."
        if ! pm_install "$pkg"; then
            warn "Не удалось автоматически установить ${pkg} через ${PM}."
            return 1
        fi
        if ! command -v "$bin" &>/dev/null; then
            warn "${bin} не появился в PATH после установки ${pkg}."
            return 1
        fi
        success "${pkg} установлен"
    done
}

# Только исполняемый файл, не shell-функция или alias; результат — абсолютный путь.
_age_resolve_binary() {
    local path dir
    [[ "$(type -t "$1")" == file ]] || return 1
    path=$(command -v "$1") || return 1
    [[ -f "$path" && -x "$path" ]] || return 1
    dir=$(cd "$(dirname "$path")" && pwd -P) || return 1
    printf '%s/%s\n' "$dir" "${path##*/}"
}

# Проверка всей пары с официальным batchpass: один release и работающий fd API.
_age_batchpass_valid() {
    local age="$1" keygen="$2" dir plugin version key_version plugin_version major minor patch tmp result rc=0
    age=$(_age_resolve_binary "$age") || return 1
    keygen=$(_age_resolve_binary "$keygen") || return 1
    dir="${age%/*}"
    plugin=$(PATH="$dir:$PATH" _age_resolve_binary age-plugin-batchpass) || return 1
    version=$("$age" --version 2>/dev/null) || return 1
    key_version=$("$keygen" --version 2>/dev/null) || return 1
    plugin_version=$("$plugin" --version 2>/dev/null) || return 1
    [[ "$version" == "$key_version" && "$version" == "$plugin_version" ]] || return 1
    [[ "$version" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
    (( 10#$major > 1 || (10#$major == 1 && (10#$minor > 3 || (10#$minor == 3 && 10#$patch >= 2))) )) || return 1
    tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/rc-age-check.XXXXXX") || return 1
    (
        unset AGE_PASSPHRASE AGE_PASSPHRASE_MAX_WORK_FACTOR
        export AGE_PASSPHRASE_FD=9 AGE_PASSPHRASE_WORK_FACTOR=1
        export PATH="$dir:$PATH"
        printf '%s' rc-age-check | "$age" -e -j batchpass 9<<<'rc-age-check' > "$tmp/check.age" 2>/dev/null &&
            "$age" -d -j batchpass 9<<<'rc-age-check' < "$tmp/check.age" > "$tmp/plain" 2>/dev/null
    ) || rc=1
    result=$(cat "$tmp/plain" 2>/dev/null)
    rm -rf "$tmp"
    (( rc == 0 )) && [[ "$result" == rc-age-check ]]
}

# Только совместимая age >= 1.3.2 + официальный plugin; без изменений system PATH.
# Pinned архивы и SHA-256: https://github.com/FiloSottile/age/releases/tag/v1.3.2
ensure_age_batchpass() {
    local age="${AGE_BIN:-age}" keygen="${AGE_KEYGEN_BIN:-age-keygen}"
    local cache root tools target os arch digest tmp hash rc=0
    if [[ "$(type -t "$age")" == function || "$(type -t "$keygen")" == function ]]; then
        warn "AGE_BIN и AGE_KEYGEN_BIN должны указывать на исполняемые файлы, а не shell-функции."
        return 1
    fi
    if _age_batchpass_valid "$age" "$keygen"; then
        AGE_BIN=$(_age_resolve_binary "$age") || return 1
        AGE_KEYGEN_BIN=$(_age_resolve_binary "$keygen") || return 1
        return 0
    fi
    if [[ "$age" != age || "$keygen" != age-keygen ]]; then
        warn "Указанный AGE_BIN/AGE_KEYGEN_BIN несовместим: нужны age >= 1.3.2 и age-plugin-batchpass той же версии."
        return 1
    fi
    if [[ "$PM" == termux || "${PREFIX:-}" == *com.termux* ]]; then
        if pm_install age && _age_batchpass_valid age age-keygen; then
            AGE_BIN=$(_age_resolve_binary age) || return 1
            AGE_KEYGEN_BIN=$(_age_resolve_binary age-keygen) || return 1
            return 0
        fi
        warn "Termux: установите совместимый пакет age >= 1.3.2 с age-plugin-batchpass."
        return 1
    fi
    cache="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
    [[ "$cache" == /* && ! -L "$cache" ]] || { warn "Небезопасный каталог cache для age."; return 1; }
    (umask 077; mkdir -p "$cache") || return 1
    [[ -d "$cache" && -O "$cache" ]] || { warn "Каталог cache не принадлежит пользователю."; return 1; }
    root="$cache/remote-control-essence"
    tools="$root/tools"
    for target in "$root" "$tools"; do
        [[ ! -L "$target" ]] || { warn "Символьная ссылка в каталоге инструментов age."; return 1; }
        (umask 077; mkdir -p "$target") || return 1
        [[ -d "$target" && -O "$target" && ! -L "$target" ]] || return 1
        chmod 700 "$target" || return 1
    done
    target="$tools/age-v1.3.2"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -d "$target" && -O "$target" && ! -L "$target" &&
           ! -L "$target/age" && ! -L "$target/age-keygen" && ! -L "$target/age-plugin-batchpass" ]] &&
            _age_batchpass_valid "$target/age" "$target/age-keygen" || {
                warn "Кэш age повреждён или небезопасен: $target."
                return 1
            }
        AGE_BIN="$target/age" AGE_KEYGEN_BIN="$target/age-keygen"
        return 0
    fi
    os=$(uname -s); arch=$(uname -m)
    case "$os:$arch" in
        Linux:x86_64|Linux:amd64) os=linux; arch=amd64; digest=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10 ;;
        Linux:aarch64|Linux:arm64) os=linux; arch=arm64; digest=6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4 ;;
        Linux:armv7l) os=linux; arch=arm; digest=0ceba62c92701b30b3336abf064714c1a6ea5fa0c75ee367ce36d4f9c0f8e6ce ;;
        Darwin:x86_64) os=darwin; arch=amd64; digest=1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539 ;;
        Darwin:arm64) os=darwin; arch=arm64; digest=e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5 ;;
        *) warn "Нет проверенного age bundle для $os/$arch: установите age >= 1.3.2 и age-plugin-batchpass вручную."; return 1 ;;
    esac
    (
    mkdir "$tools/.age-v1.3.2.lock" 2>/dev/null || { warn "Установка age уже выполняется."; exit 1; }
    trap '[[ -z "${tmp:-}" ]] || rm -rf "$tmp"; rmdir "$tools/.age-v1.3.2.lock" 2>/dev/null || true' EXIT
    tmp=$(umask 077; mktemp -d "$tools/.age-v1.3.2.XXXXXX") || exit 1
    info "Устанавливаем проверенный age v1.3.2 в пользовательский cache..."
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-${os}-${arch}.tar.gz" -o "$tmp/age.tar.gz" || rc=1
    if (( rc == 0 )); then
        if command -v sha256sum >/dev/null 2>&1; then
            hash=$(sha256sum "$tmp/age.tar.gz") || rc=1
        elif command -v shasum >/dev/null 2>&1; then
            hash=$(shasum -a 256 "$tmp/age.tar.gz") || rc=1
        else
            warn "Для проверки age необходим sha256sum или shasum."
            rc=1
        fi
        [[ "${hash%% *}" == "$digest" ]] || { warn "Контрольная сумма age не совпала."; rc=1; }
    fi
    if (( rc == 0 )); then
        tar -xzf "$tmp/age.tar.gz" -C "$tmp" age/age age/age-keygen age/age-plugin-batchpass &&
            [[ -f "$tmp/age/age" && ! -L "$tmp/age/age" &&
               -f "$tmp/age/age-keygen" && ! -L "$tmp/age/age-keygen" &&
               -f "$tmp/age/age-plugin-batchpass" && ! -L "$tmp/age/age-plugin-batchpass" ]] &&
            _age_batchpass_valid "$tmp/age/age" "$tmp/age/age-keygen" &&
            mv "$tmp/age" "$target" || rc=1
    fi
    (( rc == 0 ))
    ) || {
        warn "Не удалось подготовить age >= 1.3.2 с age-plugin-batchpass."
        return 1
    }
    AGE_BIN="$target/age" AGE_KEYGEN_BIN="$target/age-keygen"
}
