#!/bin/bash
# ─── Фича awg: AmneziaWG (этап 3 плана) ─────────────────────────────────────
# Хуки исполнителя: awg_prepare (пакеты PPA+DKMS до транзакции), awg_activate,
# awg_deactivate и awg_rollback (внутри транзакции `config`), awg_remove
# (необратимая очистка после committed при снятии).
# Конфиг /etc/amnezia/amneziawg/awg0.conf рендерит RC и ставит транзакция.
# Перенос `setup-essence/modules/amneziawg.sh:55-560` без меню и без
# проверок базовой установки mihomo (её ставят этапы этого же применения).
# Spec: AWG_PORT.

AWG_DIR="$R/etc/amnezia/amneziawg"
AWG_CONF="$AWG_DIR/awg0.conf"
AWG_OS_RELEASE="$R/etc/os-release"
AWG_MODULES_ROOT="$R/lib/modules"
AWG_DKMS_ROOT="$R/var/lib/dkms/amneziawg"
AWG_APT_KEYRING="$R/etc/apt/keyrings/amnezia.gpg"
AWG_APT_SOURCE="$R/etc/apt/sources.list.d/amnezia.sources"
AWG_APT_SOURCES_LIST="$R/etc/apt/sources.list"
AWG_APT_SOURCES_DIR="$R/etc/apt/sources.list.d"
AWG_TMP_BASE="${TMPDIR:-/tmp}"
AWG_EFFECTIVE_EUID="${AWG_EFFECTIVE_EUID:-${EUID:-$(id -u)}}"
AWG_PPA_URI="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"
AWG_PPA_FINGERPRINT="75C9DD72C799870E310542E24166F2C257290828"
AWG_PPA_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AWG_PPA_FINGERPRINT}"

# Ожидаемый сбой AWG — warning и код 1 (error() из common.sh не вызывается).
_awg_fail() {
    warn "$*"
    return 1
}

# Блокировка apt — общий неинтерактивный `agent_apt_wait` (до 300 с).
_awg_apt_wait() { agent_apt_wait; }

_awg_detect_platform() {
    local os_id version_id arch
    [[ -r "$AWG_OS_RELEASE" ]] || _awg_fail "Не найден $AWG_OS_RELEASE." || return 1
    os_id=$(. "$AWG_OS_RELEASE"; printf '%s' "${ID:-}")
    version_id=$(. "$AWG_OS_RELEASE"; printf '%s' "${VERSION_ID:-}")
    case "${os_id}:${version_id}" in
        debian:12|debian:13) AWG_APT_SUITE="jammy" ;;
        ubuntu:22.04) AWG_APT_SUITE="jammy" ;;
        ubuntu:24.04) AWG_APT_SUITE="noble" ;;
        *)
            _awg_fail "Поддерживаются Debian 12/13 и Ubuntu 22.04/24.04 (обнаружено: ${os_id:-?} ${version_id:-?})."
            return 1
            ;;
    esac

    arch=$(dpkg --print-architecture 2>/dev/null) || {
        _awg_fail "Не удалось определить архитектуру через dpkg."
        return 1
    }
    case "$arch" in
        amd64|arm64|armhf) AWG_ARCH="$arch" ;;
        *)
            _awg_fail "Архитектура '$arch' не поддерживается автоматической установкой AmneziaWG."
            return 1
            ;;
    esac
    return 0
}

_awg_preflight() {
    local cmd kernel
    [[ "$AWG_EFFECTIVE_EUID" -eq 0 ]] || _awg_fail "Запустите установку AmneziaWG от root." || return 1
    for cmd in systemctl iptables ip apt-get apt-cache dpkg dpkg-query curl modinfo modprobe; do
        command -v "$cmd" >/dev/null 2>&1 || {
            _awg_fail "Не найдена обязательная команда: $cmd."
            return 1
        }
    done
    command -v ufw >/dev/null 2>&1 || {
        _awg_fail "Не найден ufw из базовой установки."
        return 1
    }
    _awg_detect_platform || return 1

    kernel=$(uname -r)
    modprobe xt_TPROXY || {
        _awg_fail "Ядро не поддерживает TPROXY (xt_TPROXY). AmneziaWG через Mihomo невозможен."
        return 1
    }
    AWG_KERNEL="$kernel"
    AWG_HEADERS_PKG="linux-headers-${kernel}"
    return 0
}

_awg_repo_backup() {
    local path="$1" backup_name
    [[ -n "${AWG_REPO_TX_DIR:-}" ]] || return 1
    if awk -F '\t' -v p="$path" '$1 == p { found=1 } END { exit !found }' "$AWG_REPO_TX_DIR/manifest" 2>/dev/null; then
        return 0
    fi
    backup_name="file.$(wc -l < "$AWG_REPO_TX_DIR/manifest" | tr -d ' ')"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a -- "$path" "$AWG_REPO_TX_DIR/$backup_name" || return 1
        printf '%s\t1\t%s\n' "$path" "$backup_name" >> "$AWG_REPO_TX_DIR/manifest"
    else
        printf '%s\t0\t-\n' "$path" >> "$AWG_REPO_TX_DIR/manifest"
    fi
}

_awg_repo_rollback() {
    local path existed backup_name failed=0
    [[ -f "${AWG_REPO_TX_DIR:-}/manifest" ]] || return 0
    while IFS=$'\t' read -r path existed backup_name; do
        if [[ "$existed" == "1" ]]; then
            mkdir -p -- "$(dirname "$path")" || { failed=1; continue; }
            cp -a -- "$AWG_REPO_TX_DIR/$backup_name" "$path" || failed=1
        else
            rm -f -- "$path" || failed=1
        fi
    done < "$AWG_REPO_TX_DIR/manifest"
    return "$failed"
}

_awg_repo_abort() {
    local tx_dir="${AWG_REPO_TX_DIR:-}"
    if ! _awg_repo_rollback; then
        warn "Откат sources/keyring выполнен не полностью. Резервные копии сохранены в $tx_dir"
        AWG_REPO_TX_DIR=""
        return 1
    fi
    [[ -n "$tx_dir" ]] && rm -rf -- "$tx_dir"
    AWG_REPO_TX_DIR=""
    return 0
}

# Успешная установка пакетов: резервные копии sources/keyring больше не нужны.
_awg_repo_commit() {
    [[ -n "${AWG_REPO_TX_DIR:-}" ]] && rm -rf -- "$AWG_REPO_TX_DIR"
    AWG_REPO_TX_DIR=""
    return 0
}

_awg_repo_begin() {
    local old_umask
    AWG_REPO_TX_DIR=""
    old_umask=$(umask)
    umask 077
    AWG_REPO_TX_DIR=$(mktemp -d "$AWG_TMP_BASE/awg-repo.XXXXXX") || {
        umask "$old_umask"
        return 1
    }
    : > "$AWG_REPO_TX_DIR/manifest" || {
        umask "$old_umask"
        _awg_repo_abort
        return 1
    }
    umask "$old_umask"
}

_awg_render_legacy_source() {
    local source_file="$1"
    awk -v uri="$AWG_PPA_URI" '
        {
            active=$0
            sub(/^[[:space:]]*/, "", active)
            conflict=0
            if (active !~ /^#/) {
                count=split(active, tokens, /[[:space:]]+/)
                for (i=1; i<=count; i++) if (tokens[i] == uri) conflict=1
            }
            if (conflict) next
            print
        }
    ' "$source_file"
}

_awg_render_deb822_source() {
    local source_file="$1"
    awk -v uri="$AWG_PPA_URI" '
        BEGIN { RS=""; ORS="\n\n" }
        {
            count=split($0, lines, "\n")
            drop=0
            for (i=1; i<=count; i++) {
                field=lines[i]
                sub(/:.*/, "", field)
                if (toupper(field) == "URIS") {
                    values=lines[i]
                    sub(/^[^:]*:[[:space:]]*/, "", values)
                    n=split(values, tokens, /[[:space:]]+/)
                    kept=""
                    for (j=1; j<=n; j++) if (tokens[j] != uri && tokens[j] != "") kept=kept (kept ? " " : "") tokens[j]
                    if (kept == "") drop=1
                    else lines[i]="URIs: " kept
                }
            }
            if (!drop) {
                for (i=1; i<=count; i++) print lines[i]
            }
        }
    ' "$source_file"
}

_awg_remove_conflicting_sources() {
    local file tmp
    local files=()
    [[ -f "$AWG_APT_SOURCES_LIST" ]] && files+=("$AWG_APT_SOURCES_LIST")
    if [[ -d "$AWG_APT_SOURCES_DIR" ]]; then
        while IFS= read -r -d '' file; do files+=("$file"); done \
            < <(find "$AWG_APT_SOURCES_DIR" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0)
    fi
    for file in "${files[@]}"; do
        [[ "$file" == "$AWG_APT_SOURCE" ]] && continue
        grep -Fq "$AWG_PPA_URI" "$file" || continue
        tmp=$(mktemp "$(dirname "$file")/.awg-source.XXXXXX") || return 1
        if [[ "$file" == *.sources ]]; then
            _awg_render_deb822_source "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
        else
            _awg_render_legacy_source "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
        if cmp -s -- "$file" "$tmp"; then
            rm -f -- "$tmp"
            continue
        fi
        _awg_repo_backup "$file" || { rm -f -- "$tmp"; return 1; }
        chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
        mv -f -- "$tmp" "$file" || return 1
    done
}

_awg_prepare_repository_sources() {
    _awg_repo_backup "$AWG_APT_SOURCE" || return 1
    _awg_repo_backup "$AWG_APT_KEYRING" || return 1
    rm -f -- "$AWG_APT_SOURCE" || return 1
    _awg_remove_conflicting_sources
}

_awg_bootstrap_dependencies() {
    local need_gpg=0 need_headers=0 candidate headers_installed=0
    AWG_HEADERS_PKG="${AWG_HEADERS_PKG:-linux-headers-${AWG_KERNEL}}"

    command -v gpg >/dev/null 2>&1 || need_gpg=1
    [[ -d "$AWG_MODULES_ROOT/$AWG_KERNEL/build" ]] || need_headers=1
    (( need_gpg || need_headers )) || return 0

    info "Обновляю индексы активных репозиториев для зависимостей AmneziaWG..."
    _awg_apt_wait || {
        _awg_fail "Bootstrap зависимостей прерван во время ожидания apt lock перед apt-get update."
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get update || {
        _awg_fail "apt-get update для bootstrap зависимостей завершился ошибкой."
        return 1
    }

    if (( need_gpg )); then
        info "gpg не найден; устанавливаю пакет gnupg..."
        _awg_apt_wait || {
            _awg_fail "Установка gnupg прервана во время ожидания apt lock."
            return 1
        }
        DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg || {
            _awg_fail "Не удалось установить пакет gnupg."
            return 1
        }
        hash -r 2>/dev/null || true
    fi

    if (( need_headers )); then
        candidate=$(LC_ALL=C apt-cache policy "$AWG_HEADERS_PKG" 2>/dev/null \
            | awk '/Candidate:/ { print $2; exit }')
        if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
            HINT=kernel_headers
            _awg_fail "Активные репозитории не предоставляют headers для текущего ядра ($AWG_HEADERS_PKG). Возможные причины: старое/custom/provider kernel, неполные репозитории или APT pinning. Ядро не обновлялось, сервер не перезагружался. Обновите ядро (apt-get install linux-image-amd64 на Debian, linux-image-generic на Ubuntu), перезагрузите сервер и повторите node apply."
            return 1
        fi
        if LC_ALL=C dpkg-query -W -f='${Status}' "$AWG_HEADERS_PKG" 2>/dev/null \
            | grep -q '^install ok installed$'; then
            headers_installed=1
        fi
        _awg_apt_wait || {
            _awg_fail "Установка заголовочных файлов ядра прервана во время ожидания блокировки apt."
            return 1
        }
        if (( headers_installed )); then
            info "Пакет $AWG_HEADERS_PKG установлен без build-path; переустанавливаю его..."
            DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y "$AWG_HEADERS_PKG" || {
                _awg_fail "Не удалось переустановить пакет $AWG_HEADERS_PKG."
                return 1
            }
        else
            info "Устанавливаю заголовочные файлы текущего ядра: $AWG_HEADERS_PKG..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$AWG_HEADERS_PKG" || {
                _awg_fail "Не удалось установить пакет $AWG_HEADERS_PKG."
                return 1
            }
        fi
    fi

    command -v gpg >/dev/null 2>&1 || {
        _awg_fail "После bootstrap команда gpg не найдена."
        return 1
    }
    [[ -d "$AWG_MODULES_ROOT/$AWG_KERNEL/build" ]] || {
        _awg_fail "После установки $AWG_HEADERS_PKG не появился build-path $AWG_MODULES_ROOT/$AWG_KERNEL/build. Ядро не обновлялось, сервер не перезагружался."
        return 1
    }
    (( need_gpg )) && success "gnupg установлен"
    (( need_headers )) && success "Заголовочные файлы для ядра $AWG_KERNEL готовы"
    return 0
}

# _awg_pinned_keyring <armor> <keyring> <tmpdir> — в keyring попадает только
# ключ $AWG_PPA_FINGERPRINT: импорт во временный каталог gpg и экспорт по
# отпечатку, лишние ключи из загруженного файла отбрасываются.
_awg_pinned_keyring() {
    local armor="$1" keyring="$2" home pubs fingerprint
    home=$(mktemp -d "$3/gnupg.XXXXXX") || return 1
    if ! gpg --batch --quiet --homedir "$home" --import "$armor" 2>/dev/null ||
       ! gpg --batch --homedir "$home" --export "$AWG_PPA_FINGERPRINT" >"$keyring" 2>/dev/null; then
        rm -rf -- "$home"
        return 1
    fi
    rm -rf -- "$home"
    pubs=$(gpg --batch --show-keys --with-colons "$keyring" 2>/dev/null | awk -F: '$1 == "pub"' | wc -l)
    fingerprint=$(gpg --batch --show-keys --with-colons "$keyring" 2>/dev/null \
        | awk -F: '$1 == "fpr" { print toupper($10); exit }')
    [[ "$pubs" -eq 1 && "$fingerprint" == "$AWG_PPA_FINGERPRINT" ]]
}

_awg_install_repository() {
    local key_ascii key_tmp source_tmp old_umask
    _awg_repo_begin || {
        _awg_fail "Не удалось начать транзакцию настройки PPA Amnezia."
        return 1
    }
    _awg_prepare_repository_sources || {
        _awg_fail "Не удалось временно отключить прежние записи PPA Amnezia."
        _awg_repo_abort
        return 1
    }
    _awg_bootstrap_dependencies || {
        _awg_repo_abort
        return 1
    }

    old_umask=$(umask)
    umask 077
    key_ascii=$(mktemp "$AWG_REPO_TX_DIR/key.XXXXXX") || {
        umask "$old_umask"
        _awg_repo_abort
        return 1
    }
    umask "$old_umask"

    info "Настройка официального PPA Amnezia (${AWG_APT_SUITE})..."
    curl -fsSL "$AWG_PPA_KEY_URL" -o "$key_ascii" || {
        _awg_fail "Не удалось загрузить ключ PPA Amnezia."
        _awg_repo_abort
        return 1
    }
    mkdir -p -- "$(dirname "$AWG_APT_KEYRING")" "$(dirname "$AWG_APT_SOURCE")" || {
        _awg_repo_abort
        return 1
    }
    key_tmp=$(mktemp "$(dirname "$AWG_APT_KEYRING")/.amnezia.gpg.XXXXXX") || {
        _awg_repo_abort
        return 1
    }
    if ! _awg_pinned_keyring "$key_ascii" "$key_tmp" "$AWG_REPO_TX_DIR"; then
        rm -f -- "$key_tmp"
        _awg_fail "В ключе PPA нет ключа с fingerprint $AWG_PPA_FINGERPRINT."
        _awg_repo_abort
        return 1
    fi
    chmod 644 "$key_tmp"
    _awg_repo_backup "$AWG_APT_KEYRING" || {
        rm -f -- "$key_tmp"
        _awg_repo_abort
        return 1
    }
    mv -f -- "$key_tmp" "$AWG_APT_KEYRING" || {
        _awg_repo_abort
        return 1
    }

    source_tmp=$(mktemp "$(dirname "$AWG_APT_SOURCE")/.amnezia.sources.XXXXXX") || {
        _awg_repo_abort
        return 1
    }
    # Signed-By — путь на ноде, без тестового префикса.
    cat > "$source_tmp" <<EOF
Types: deb deb-src
URIs: $AWG_PPA_URI
Suites: $AWG_APT_SUITE
Components: main
Signed-By: ${AWG_APT_KEYRING#"$R"}
EOF
    if [[ $? -ne 0 ]] || ! chmod 644 "$source_tmp"; then
        rm -f -- "$source_tmp"
        _awg_repo_abort
        return 1
    fi
    mv -f -- "$source_tmp" "$AWG_APT_SOURCE" || {
        _awg_repo_abort
        return 1
    }
}

_awg_show_module_diagnostics() {
    local kernel="${AWG_KERNEL:-$(uname -r)}" log
    warn "Диагностика AmneziaWG для ядра $kernel:"
    echo "  Headers build: $AWG_MODULES_ROOT/$kernel/build"
    if command -v dkms >/dev/null 2>&1; then
        echo "  dkms status:"
        dkms status 2>&1 || true
    fi
    log=$(find "$AWG_DKMS_ROOT" -path '*/build/make.log' -type f 2>/dev/null | sort | tail -1)
    if [[ -n "$log" ]]; then
        echo "  make.log: $log"
        tail -n 80 "$log" 2>/dev/null || true
    fi
    echo "  dmesg (amneziawg/dkms/module):"
    dmesg 2>&1 | grep -Ei 'amnezia|awg|dkms|module|secure boot' | tail -n 80 || true
    if [[ -n "$log" ]] && grep -q 'setup_udp_tunnel_sock' "$log" 2>/dev/null; then
        warn "Известная несовместимость: текущий amneziawg-dkms не собирается на ядрах Ubuntu 7.0.0-38+ (в т.ч. HWE-ядро 24.04)."
        warn "Исправление ещё не опубликовано в PPA: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/259 — дождитесь обновления PPA или загрузитесь в более старое ядро."
    else
        warn "Проверьте Secure Boot, ограничения OpenVZ/LXC и совместимость нестандартного ядра."
    fi
}

_awg_any_package_installed() {
    local package
    for package in amneziawg amneziawg-tools amneziawg-dkms; do
        LC_ALL=C dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
            | grep -q '^install ok installed$' && return 0
    done
    return 1
}

_awg_cleanup_failed_packages() {
    local fresh_install="$1"
    if [[ "$fresh_install" != 1 ]]; then
        warn "Пакеты AmneziaWG могли остаться недонастроенными. После исправления выполните: dpkg --configure -a"
        return 0
    fi
    info "Удаляю частично установленные пакеты AmneziaWG, чтобы apt остался рабочим..."
    if _awg_apt_wait && DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg amneziawg-tools amneziawg-dkms; then
        success "Частично установленные пакеты AmneziaWG удалены."
    else
        warn "Не удалось удалить пакеты AmneziaWG. Выполните вручную: apt-get purge -y amneziawg amneziawg-tools amneziawg-dkms"
    fi
    return 0
}

_awg_ensure_packages() {
    local packages=("amneziawg" "amneziawg-tools" "amneziawg-dkms")
    local candidates=() candidate installed package tools_output tools_version module_version
    local i

    _awg_install_repository || { _awg_repo_abort; return 1; }
    _awg_apt_wait || {
        _awg_fail "Установка AmneziaWG прервана во время ожидания apt lock."
        _awg_repo_abort
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get update || {
        _awg_fail "apt-get update завершился ошибкой."
        _awg_repo_abort
        return 1
    }
    for i in "${!packages[@]}"; do
        package="${packages[$i]}"
        candidate=$(LC_ALL=C apt-cache policy "$package" 2>/dev/null \
            | awk '/Candidate:/ { print $2; exit }')
        if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
            _awg_fail "APT candidate для пакета $package отсутствует (suite: $AWG_APT_SUITE, arch: $AWG_ARCH)."
            _awg_repo_abort
            return 1
        fi
        candidates[$i]="$candidate"
    done

    local fresh_install=0
    _awg_any_package_installed || fresh_install=1

    _awg_apt_wait || {
        _awg_fail "Установка AmneziaWG прервана во время ожидания apt lock."
        _awg_repo_abort
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || {
        _awg_fail "Не удалось установить пакеты AmneziaWG 3.1."
        _awg_show_module_diagnostics
        _awg_cleanup_failed_packages "$fresh_install"
        _awg_repo_abort
        return 1
    }

    for i in "${!packages[@]}"; do
        package="${packages[$i]}"
        installed=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null) || installed=""
        if [[ -z "$installed" || "$installed" != "${candidates[$i]}" ]]; then
            _awg_fail "Пакет $package не обновлён до актуального APT candidate: установлено ${installed:-?}, доступно ${candidates[$i]}."
            _awg_repo_abort
            return 1
        fi
    done
    if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
        _awg_fail "После установки не найдены awg и/или awg-quick."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    fi

    tools_output=$(awg --version 2>&1)
    tools_version=$(printf '%s\n' "$tools_output" \
        | awk 'match($0, /[0-9]+\.[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')
    if [[ -z "$tools_version" ]] || ! dpkg --compare-versions "$tools_version" ge 3.1; then
        _awg_fail "Инструменты AmneziaWG устарели: требуется версия не ниже 3.1 (обнаружено ${tools_version:-неизвестно})."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    fi
    module_version=$(modinfo -F version -k "$AWG_KERNEL" amneziawg 2>/dev/null) || module_version=""
    if [[ -z "$module_version" ]] || ! dpkg --compare-versions "$module_version" ge 3.1; then
        _awg_fail "DKMS-модуль AmneziaWG устарел: требуется версия не ниже 3.1 (обнаружено ${module_version:-неизвестно})."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    fi

    _awg_repo_commit
    success "Пакеты AmneziaWG 3.1 проверены для $AWG_KERNEL"
    return 0
}

# ─── Хуки исполнителя ───────────────────────────────────────────────────────

awg_prepare() {
    [[ -n "${AWG_PORT:-}" ]] || { warn "Не задан AWG_PORT."; return 1; }
    _awg_preflight || return 1
    _awg_ensure_packages
}

# Часть конфига до первой строки `# peer:` (интерфейс без пиров).
_awg_interface_part() {
    awk '/^# peer:/ { exit } { print }' "$1"
}

_awg_wait_up() {
    local i
    for ((i = 0; i < 10; i++)); do
        if systemctl is-active --quiet awg-quick@awg0 && ip link show awg0 >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    warn "awg-quick@awg0 не поднялся."
    return 1
}

# Изменились только пиры и интерфейс уже поднят — `awg syncconf` без разрыва
# соединений; иначе перезапуск awg-quick@awg0.
awg_activate() {
    local backup="$OP/backup${AWG_CONF#"$R"}"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
    if ip link show awg0 >/dev/null 2>&1 && [[ -f "$backup" ]] &&
       [[ "$(_awg_interface_part "$AWG_CONF")" == "$(_awg_interface_part "$backup")" ]]; then
        awg syncconf awg0 <(awg-quick strip awg0) || return 1
        return 0
    fi
    systemctl enable awg-quick@awg0 || return 1
    systemctl restart awg-quick@awg0 || return 1
    _awg_wait_up
}

# Откат трогает AmneziaWG, только если транзакция трогала его: awg_deactivate
# в этой операции — интерфейс поднимается с восстановленным конфигом;
# awg0.conf в транзакции (TX_PATHS) и изменён ею — прежний конфиг
# перезапускается, первой установки (копии нет) — интерфейс опускается по
# новому конфигу из файлов операции (в /etc его уже нет). Откат по чужой
# причине (mihomo -t, nginx, sub…) работающий awg0 не перезапускает.
awg_rollback() {
    local path="${AWG_CONF#"$R"}"
    local backup="$OP/backup$path" staged="$OP/files$path"
    # Явный код: в обработчике trap (finish) голый `return` вернул бы код
    # команды до trap.
    if [[ " $TX_DEACTIVATED " == *" awg "* ]]; then
        systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0
        return $?
    fi
    [[ " ${TX_PATHS[*]} " == *" $path "* ]] || return 0
    if [[ -f "$backup" ]]; then
        cmp -s -- "$backup" "$staged" && return 0
        systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0
    else
        if ip link show awg0 >/dev/null 2>&1 && [[ -f "$staged" ]]; then
            awg-quick down "$staged"
        fi
        systemctl disable --now awg-quick@awg0
    fi
}

# Снятие фичи, до удаления awg0.conf этапом config: awg-quick и ExecStop юнита
# находят интерфейс только по этому файлу.
awg_deactivate() {
    [[ -f "$AWG_CONF" ]] || return 0
    systemctl disable --now awg-quick@awg0 || return 1
    if ip link show awg0 >/dev/null 2>&1; then
        awg-quick down awg0 || return 1
    fi
}

awg_remove() {
    rm -rf -- "$R/etc/amnezia"
}
