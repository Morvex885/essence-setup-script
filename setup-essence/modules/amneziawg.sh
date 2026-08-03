#!/bin/bash
# ─── AmneziaWG ──────────────────────────────────────────────────────────────

AWG_DIR="${AWG_DIR:-/etc/amnezia/amneziawg}"
AWG_CONF="${AWG_CONF:-$AWG_DIR/awg0.conf}"
AWG_CLIENTS_DIR="${AWG_CLIENTS_DIR:-/etc/mihomo/amnezia}"
AWG_MIHOMO_CONFIG="${AWG_MIHOMO_CONFIG:-/etc/mihomo/config.yaml}"
AWG_CLIENT_CONFIG="${AWG_CLIENT_CONFIG:-/etc/mihomo/client-config.txt}"
AWG_SYSCTL_FILE="${AWG_SYSCTL_FILE:-/etc/sysctl.d/99-vpn-speedup.conf}"
AWG_OS_RELEASE="${AWG_OS_RELEASE:-/etc/os-release}"
AWG_MODULES_ROOT="${AWG_MODULES_ROOT:-/lib/modules}"
AWG_APT_KEYRING="${AWG_APT_KEYRING:-/etc/apt/keyrings/amnezia.gpg}"
AWG_APT_SOURCE="${AWG_APT_SOURCE:-/etc/apt/sources.list.d/amnezia.sources}"
AWG_APT_SOURCES_LIST="${AWG_APT_SOURCES_LIST:-/etc/apt/sources.list}"
AWG_APT_SOURCES_DIR="${AWG_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
AWG_TMP_BASE="${AWG_TMP_BASE:-${TMPDIR:-/tmp}}"
AWG_EFFECTIVE_EUID="${AWG_EFFECTIVE_EUID:-${EUID:-$(id -u)}}"
AWG_PPA_URI="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"
AWG_PPA_FINGERPRINT="75C9DD72C799870E310542E24166F2C257290828"
AWG_PPA_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AWG_PPA_FINGERPRINT}"

# Helpers установки намеренно не используют error(): ожидаемый сбой AWG не должен
# завершать главный серверный entrypoint и закрывать SSH-сессию.
_awg_fail() {
    warn "$*"
    return 1
}

_awg_apt_lock_menu() {
    while true; do
        echo ""
        warn "apt lock не освободился за 60с"
        echo -e "  ${CYAN}Процессы, блокирующие apt:${NC}"
        local pids pid pname
        pids=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null || true)
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "???")
            echo -e "    PID ${YELLOW}${pid}${NC}  ${pname}"
        done
        echo ""
        echo -e "  ${GREEN}1)${NC} Завершить процесс и продолжить"
        echo -e "  ${CYAN}2)${NC} Подождать ещё 60с"
        echo -e "  ${RED}3)${NC} Прервать установку AWG"
        echo ""
        read -rp "  Выберите: " _choice
        case "$_choice" in
            1)
                for pid in $pids; do
                    pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "???")
                    if confirm_yn "Завершить процесс ${pname} (PID ${pid})?"; then
                        kill "$pid" 2>/dev/null || true
                        sleep 3
                        if kill -0 "$pid" 2>/dev/null; then
                            warn "Процесс не завершился, отправляю SIGKILL..."
                            kill -9 "$pid" 2>/dev/null || true
                            sleep 2
                        fi
                    fi
                done
                if ! fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
                    success "apt lock освобождён"
                    return 0
                fi
                warn "Lock всё ещё занят"
                ;;
            2) return 0 ;;
            3) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_awg_apt_wait() {
    local max_wait="${AWG_APT_MAX_WAIT:-60}" waited=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null; do
        [[ "$waited" -eq 0 ]] && info "Ожидаю завершения другого процесса apt..."
        sleep 2
        waited=$((waited + 2))
        if [[ "$waited" -ge "$max_wait" ]]; then
            _awg_apt_lock_menu || return 1
            waited=0
        fi
    done
    return 0
}

_awg_gen_free_port() {
    local min="$1" max="$2" range port
    range=$((max - min + 1))
    for _ in $(seq 1 100); do
        port=$((RANDOM % range + min))
        is_port_free "$port" && { echo "$port"; return 0; }
    done
    return 1
}

_awg_detect_platform() {
    local os_id version_id arch
    [[ -r "$AWG_OS_RELEASE" ]] || _awg_fail "Не найден $AWG_OS_RELEASE." || return 1
    os_id=$(. "$AWG_OS_RELEASE"; printf '%s' "${ID:-}")
    version_id=$(. "$AWG_OS_RELEASE"; printf '%s' "${VERSION_ID:-}")
    case "${os_id}:${version_id}" in
        debian:12|debian:13) AWG_APT_SUITE="focal" ;;
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

_awg_find_mihomo() {
    local mihomo_bin="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
    if [[ ! -x "$mihomo_bin" ]]; then
        mihomo_bin=$(command -v mihomo 2>/dev/null || true)
    fi
    [[ -n "$mihomo_bin" ]] || return 1
    printf '%s\n' "$mihomo_bin"
}

_awg_validate_managed_paths() {
    case "$AWG_DIR" in /*/amnezia/amneziawg) ;; *) _awg_fail "Небезопасный путь AWG_DIR: $AWG_DIR"; return 1 ;; esac
    [[ "$AWG_CONF" == "$AWG_DIR/awg0.conf" ]] || { _awg_fail "AWG_CONF должен находиться внутри AWG_DIR."; return 1; }
    case "$AWG_CLIENTS_DIR" in /*/mihomo/amnezia) ;; *) _awg_fail "Небезопасный путь AWG_CLIENTS_DIR: $AWG_CLIENTS_DIR"; return 1 ;; esac
    case "$AWG_MIHOMO_CONFIG" in /*/mihomo/config.yaml) ;; *) _awg_fail "Небезопасный путь config.yaml: $AWG_MIHOMO_CONFIG"; return 1 ;; esac
    case "$AWG_CLIENT_CONFIG" in /*/mihomo/client-config.txt) ;; *) _awg_fail "Небезопасный путь client-config.txt: $AWG_CLIENT_CONFIG"; return 1 ;; esac
    case "$AWG_SYSCTL_FILE" in /*/sysctl.d/99-vpn-speedup.conf) ;; *) _awg_fail "Небезопасный путь sysctl: $AWG_SYSCTL_FILE"; return 1 ;; esac
    case "$AWG_TMP_BASE" in /*) ;; *) _awg_fail "Временный путь AWG должен быть абсолютным: $AWG_TMP_BASE"; return 1 ;; esac
}

_awg_preflight() {
    local cmd kernel mihomo_bin
    [[ "$AWG_EFFECTIVE_EUID" -eq 0 ]] || _awg_fail "Запустите установку AmneziaWG от root." || return 1
    _awg_validate_managed_paths || return 1
    [[ -f "$AWG_MIHOMO_CONFIG" ]] || _awg_fail "Базовая установка Mihomo не найдена: $AWG_MIHOMO_CONFIG отсутствует." || return 1
    mihomo_bin=$(_awg_find_mihomo) || {
        _awg_fail "Бинарник Mihomo не найден. Сначала выполните базовую установку."
        return 1
    }
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
    systemctl cat mihomo >/dev/null 2>&1 || {
        _awg_fail "Не найден systemd-unit mihomo. Сначала выполните базовую установку."
        return 1
    }
    _awg_detect_platform || return 1

    kernel=$(uname -r)
    modprobe xt_TPROXY || {
        _awg_fail "Ядро не поддерживает TPROXY (xt_TPROXY). AWG через Mihomo невозможен."
        return 1
    }
    AWG_MIHOMO_BIN="$mihomo_bin"
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
            _awg_fail "Активные репозитории не предоставляют headers для текущего ядра ($AWG_HEADERS_PKG). Возможные причины: старое/custom/provider kernel, неполные репозитории или APT pinning. Ядро не обновлялось, сервер не перезагружался."
            return 1
        fi
        if LC_ALL=C dpkg-query -W -f='${Status}' "$AWG_HEADERS_PKG" 2>/dev/null \
            | grep -q '^install ok installed$'; then
            headers_installed=1
        fi
        _awg_apt_wait || {
            _awg_fail "Установка headers прервана во время ожидания apt lock."
            return 1
        }
        if (( headers_installed )); then
            info "Пакет $AWG_HEADERS_PKG установлен без build-path; переустанавливаю его..."
            DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y "$AWG_HEADERS_PKG" || {
                _awg_fail "Не удалось переустановить пакет $AWG_HEADERS_PKG."
                return 1
            }
        else
            info "Устанавливаю headers текущего ядра: $AWG_HEADERS_PKG..."
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
    (( need_headers )) && success "Headers для ядра $AWG_KERNEL готовы"
    return 0
}

_awg_install_repository() {
    local key_ascii key_tmp source_tmp fingerprint old_umask
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
    fingerprint=$(gpg --batch --show-keys --with-colons "$key_ascii" 2>/dev/null \
        | awk -F: '$1 == "fpr" { print toupper($10); exit }')
    if [[ "$fingerprint" != "$AWG_PPA_FINGERPRINT" ]]; then
        _awg_fail "Fingerprint ключа PPA не совпал с ожидаемым $AWG_PPA_FINGERPRINT."
        _awg_repo_abort
        return 1
    fi

    mkdir -p -- "$(dirname "$AWG_APT_KEYRING")" "$(dirname "$AWG_APT_SOURCE")" || {
        _awg_repo_abort
        return 1
    }
    key_tmp=$(mktemp "$(dirname "$AWG_APT_KEYRING")/.amnezia.gpg.XXXXXX") || {
        _awg_repo_abort
        return 1
    }
    if ! gpg --batch --dearmor < "$key_ascii" > "$key_tmp"; then
        rm -f -- "$key_tmp"
        _awg_fail "Не удалось преобразовать ключ PPA в keyring."
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
    cat > "$source_tmp" <<EOF
Types: deb deb-src
URIs: $AWG_PPA_URI
Suites: $AWG_APT_SUITE
Components: main
Signed-By: $AWG_APT_KEYRING
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
    log=$(find /var/lib/dkms/amneziawg -path '*/build/make.log' -type f 2>/dev/null | sort | tail -1)
    if [[ -n "$log" ]]; then
        echo "  make.log: $log"
        tail -n 80 "$log" 2>/dev/null || true
    fi
    echo "  dmesg (amneziawg/dkms/module):"
    dmesg 2>&1 | grep -Ei 'amnezia|awg|dkms|module|secure boot' | tail -n 80 || true
    warn "Проверьте Secure Boot, ограничения OpenVZ/LXC и совместимость нестандартного ядра."
}

_awg_ensure_packages() {
    local candidate
    _awg_install_repository || { _awg_repo_abort; return 1; }
    _awg_apt_wait || {
        _awg_fail "Установка AWG прервана во время ожидания apt lock."
        _awg_repo_abort
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get update || {
        _awg_fail "apt-get update завершился ошибкой."
        _awg_repo_abort
        return 1
    }
    candidate=$(LC_ALL=C apt-cache policy amneziawg 2>/dev/null | awk '/Candidate:/ { print $2; exit }')
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        _awg_fail "APT candidate для пакета amneziawg отсутствует (suite: $AWG_APT_SUITE, arch: $AWG_ARCH)."
        _awg_repo_abort
        return 1
    fi
    _awg_apt_wait || {
        _awg_fail "Установка AWG прервана во время ожидания apt lock."
        _awg_repo_abort
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg || {
        _awg_fail "Не удалось установить метапакет amneziawg."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    }
    if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
        _awg_fail "После установки не найдены awg и/или awg-quick."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    fi
    if ! modinfo -k "$AWG_KERNEL" amneziawg; then
        _awg_fail "DKMS-модуль amneziawg не собран для ядра $AWG_KERNEL."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    fi
    if ! modprobe amneziawg; then
        _awg_fail "Не удалось загрузить модуль amneziawg."
        _awg_show_module_diagnostics
        _awg_repo_abort
        return 1
    fi
    if ! command -v qrencode >/dev/null 2>&1; then
        _awg_apt_wait && DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode || \
            warn "qrencode не установлен; PNG/ANSI QR-коды будут недоступны."
    fi
    success "Пакеты AmneziaWG установлены, модуль загружен для $AWG_KERNEL"
    return 0
}

_awg_snapshot_path() {
    local tx_dir="$1" label="$2" path="$3"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a -- "$path" "$tx_dir/snapshot/$label" || return 1
        printf '1\n' > "$tx_dir/snapshot/$label.exists"
    else
        printf '0\n' > "$tx_dir/snapshot/$label.exists"
    fi
}

_awg_restore_path() {
    local tx_dir="$1" label="$2" path="$3" existed
    existed=$(<"$tx_dir/snapshot/$label.exists")
    rm -rf -- "$path"
    if [[ "$existed" == "1" ]]; then
        mkdir -p -- "$(dirname "$path")"
        cp -a -- "$tx_dir/snapshot/$label" "$path"
    fi
}

_awg_unit_state() {
    local unit="$1" state="$2"
    case "$state" in
        active) systemctl is-active --quiet "$unit" 2>/dev/null ;;
        enabled) systemctl is-enabled --quiet "$unit" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

_awg_ufw_has_rule() {
    local port="$1"
    ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/udp([[:space:]]|$)"
}

_awg_snapshot_state() {
    local tx_dir="$1" old_port="$2" new_port="$3"
    mkdir -p "$tx_dir/snapshot" || return 1
    _awg_snapshot_path "$tx_dir" awg_dir "$AWG_DIR" || return 1
    _awg_snapshot_path "$tx_dir" clients "$AWG_CLIENTS_DIR" || return 1
    _awg_snapshot_path "$tx_dir" mihomo_config "$AWG_MIHOMO_CONFIG" || return 1
    _awg_snapshot_path "$tx_dir" client_config "$AWG_CLIENT_CONFIG" || return 1
    _awg_snapshot_path "$tx_dir" sysctl_file "$AWG_SYSCTL_FILE" || return 1
    _awg_unit_state awg-quick@awg0 active && echo 1 > "$tx_dir/snapshot/awg.active" || echo 0 > "$tx_dir/snapshot/awg.active"
    _awg_unit_state awg-quick@awg0 enabled && echo 1 > "$tx_dir/snapshot/awg.enabled" || echo 0 > "$tx_dir/snapshot/awg.enabled"
    _awg_unit_state mihomo active && echo 1 > "$tx_dir/snapshot/mihomo.active" || echo 0 > "$tx_dir/snapshot/mihomo.active"
    _awg_unit_state mihomo enabled && echo 1 > "$tx_dir/snapshot/mihomo.enabled" || echo 0 > "$tx_dir/snapshot/mihomo.enabled"
    cat /proc/sys/net/ipv4/ip_forward 2>/dev/null > "$tx_dir/snapshot/ip_forward" || echo 0 > "$tx_dir/snapshot/ip_forward"
    if [[ -n "$old_port" ]] && _awg_ufw_has_rule "$old_port"; then
        echo 1 > "$tx_dir/snapshot/old_port.rule"
    else
        echo 0 > "$tx_dir/snapshot/old_port.rule"
    fi
    if _awg_ufw_has_rule "$new_port"; then
        echo 1 > "$tx_dir/snapshot/new_port.rule"
    else
        echo 0 > "$tx_dir/snapshot/new_port.rule"
    fi
}

_awg_build_mihomo_candidate() {
    local tproxy_port="$1" source_config="$2"
    awk -v port="$tproxy_port" '
        /^tproxy-port:[[:space:]]*/ {
            if (!updated) print "tproxy-port: " port
            updated=1
            next
        }
        {
            print
            if (!updated && /^bind-address:[[:space:]]*/) {
                print "tproxy-port: " port
                updated=1
            }
        }
        END { if (!updated) exit 1 }
    ' "$source_config"
}

_awg_prepare_mihomo_candidate() {
    local tproxy_port="$1" config_dir old_umask
    config_dir=$(dirname "$AWG_MIHOMO_CONFIG")
    old_umask=$(umask)
    umask 077
    AWG_MIHOMO_CANDIDATE=$(mktemp "$config_dir/.config.yaml.awg.XXXXXX") || {
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"
    if ! _awg_build_mihomo_candidate "$tproxy_port" "$AWG_MIHOMO_CONFIG" > "$AWG_MIHOMO_CANDIDATE"; then
        rm -f -- "$AWG_MIHOMO_CANDIDATE"
        AWG_MIHOMO_CANDIDATE=""
        _awg_fail "Не удалось безопасно добавить tproxy-port в config.yaml."
        return 1
    fi
    if ! "$AWG_MIHOMO_BIN" -t -f "$AWG_MIHOMO_CANDIDATE"; then
        rm -f -- "$AWG_MIHOMO_CANDIDATE"
        AWG_MIHOMO_CANDIDATE=""
        _awg_fail "Mihomo отклонил изменённый config.yaml; рабочий конфиг не изменён."
        return 1
    fi
    chmod --reference="$AWG_MIHOMO_CONFIG" "$AWG_MIHOMO_CANDIDATE" 2>/dev/null || true
}

_awg_stage_server_config() {
    local stage_dir="$1" server_private server_public psk old_umask
    old_umask=$(umask)
    umask 077
    server_private=$(awg genkey) || { umask "$old_umask"; return 1; }
    server_public=$(printf '%s\n' "$server_private" | awg pubkey) || { umask "$old_umask"; return 1; }
    psk=$(awg genpsk) || { umask "$old_umask"; return 1; }
    [[ -n "$server_private" && -n "$server_public" && -n "$psk" ]] || { umask "$old_umask"; return 1; }
    mkdir -p "$stage_dir" || { umask "$old_umask"; return 1; }
    printf '%s\n' "$server_private" > "$stage_dir/server_private.key" || { umask "$old_umask"; return 1; }
    printf '%s\n' "$server_public" > "$stage_dir/server_public.key" || { umask "$old_umask"; return 1; }
    printf '%s\n' "$psk" > "$stage_dir/psk.key" || { umask "$old_umask"; return 1; }
    cat > "$stage_dir/awg0.conf" <<EOF
[Interface]
PrivateKey = $server_private
Address = ${AWG_SERVER_IP}/24
ListenPort = $AWG_PORT
Jc = $AWG_Jc
Jmin = $AWG_Jmin
Jmax = $AWG_Jmax
S1 = $AWG_S1
S2 = $AWG_S2
S3 = $AWG_S3
S4 = $AWG_S4
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -I INPUT -m mark --mark 1 -j ACCEPT; ip rule add fwmark 1 table 100 || true; ip route add local 0.0.0.0/0 dev lo table 100 || true; iptables -t mangle -N MIHOMO_AWG || true; iptables -t mangle -F MIHOMO_AWG; iptables -t mangle -A MIHOMO_AWG -d ${AWG_SUBNET}.0/24 -j RETURN; iptables -t mangle -A MIHOMO_AWG -d 127.0.0.0/8 -j RETURN; iptables -t mangle -A MIHOMO_AWG -d 224.0.0.0/4 -j RETURN; iptables -t mangle -A MIHOMO_AWG -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port $AWG_TPROXY_PORT --tproxy-mark 1; iptables -t mangle -A MIHOMO_AWG -p udp -j TPROXY --on-ip 127.0.0.1 --on-port $AWG_TPROXY_PORT --tproxy-mark 1; iptables -t mangle -A PREROUTING -i %i -j MIHOMO_AWG; iptables -t nat -A PREROUTING -i %i -p udp --dport 53 -j REDIRECT --to-ports 1053
PostDown = iptables -D FORWARD -i %i -j ACCEPT || true; iptables -D INPUT -m mark --mark 1 -j ACCEPT || true; iptables -t mangle -D PREROUTING -i %i -j MIHOMO_AWG || true; iptables -t mangle -F MIHOMO_AWG || true; iptables -t mangle -X MIHOMO_AWG || true; iptables -t nat -D PREROUTING -i %i -p udp --dport 53 -j REDIRECT --to-ports 1053 || true; ip rule del fwmark 1 table 100 || true; ip route del local 0.0.0.0/0 dev lo table 100 || true
EOF
    if [[ $? -ne 0 ]] || ! chmod 600 "$stage_dir"/*; then
        umask "$old_umask"
        return 1
    fi
    umask "$old_umask"
}

_awg_install_staged_config() {
    local stage_dir="$1"
    rm -rf -- "$AWG_DIR"
    mkdir -p -- "$AWG_DIR" || return 1
    cp -a -- "$stage_dir/." "$AWG_DIR/" || return 1
    chmod 600 "$AWG_CONF" "$AWG_DIR"/*.key
}

_awg_apply_ip_forwarding() {
    mkdir -p -- "$(dirname "$AWG_SYSCTL_FILE")" || return 1
    sysctl -w net.ipv4.ip_forward=1 || return 1
    if grep -q '^net.ipv4.ip_forward[[:space:]]*=' "$AWG_SYSCTL_FILE" 2>/dev/null; then
        sed -i 's/^net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward = 1/' "$AWG_SYSCTL_FILE" || return 1
    else
        printf 'net.ipv4.ip_forward = 1\n' >> "$AWG_SYSCTL_FILE" || return 1
    fi
}

_awg_write_client_info() {
    local server_addr config_dir candidate old_umask
    server_addr=$(grep '^Domain:' "$AWG_CLIENT_CONFIG" 2>/dev/null | awk '{print $2; exit}')
    [[ -n "$server_addr" ]] || server_addr=$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    [[ -n "$server_addr" ]] || {
        _awg_fail "Не удалось определить публичный адрес сервера для client-config.txt."
        return 1
    }
    SERVER_ADDR="$server_addr"
    config_dir=$(dirname "$AWG_CLIENT_CONFIG")
    mkdir -p "$config_dir" || return 1
    old_umask=$(umask)
    umask 077
    candidate=$(mktemp "$config_dir/.client-config.awg.XXXXXX") || { umask "$old_umask"; return 1; }
    umask "$old_umask"
    if [[ -f "$AWG_CLIENT_CONFIG" ]]; then
        sed '/^--- AmneziaWG ---/,/^--- \/AmneziaWG ---/d' "$AWG_CLIENT_CONFIG" > "$candidate" || {
            rm -f -- "$candidate"
            return 1
        }
    fi
    cat >> "$candidate" <<EOF

--- AmneziaWG ---
Server:    $SERVER_ADDR
Port:      $AWG_PORT/udp
Subnet:    ${AWG_SUBNET}.0/24
Clients:   $AWG_CLIENTS_DIR/
--- /AmneziaWG ---
EOF
    if [[ $? -ne 0 ]] || ! chmod 600 "$candidate"; then
        rm -f -- "$candidate"
        return 1
    fi
    mv -f -- "$candidate" "$AWG_CLIENT_CONFIG"
}

_awg_restore_unit_state() {
    local tx_dir="$1" unit="$2" prefix="$3"
    if [[ "$(<"$tx_dir/snapshot/$prefix.enabled")" == "1" ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || true
    else
        systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
    if [[ "$(<"$tx_dir/snapshot/$prefix.active")" == "1" ]]; then
        systemctl restart "$unit" || true
    else
        systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
}

_awg_rollback_install() {
    local tx_dir="$1" reinstall="$2" stage_dir="$3" new_port="$4" old_port="$5"
    warn "Установка AmneziaWG не завершена; восстанавливаю исходное состояние..."
    awg-quick down awg0 >/dev/null 2>&1 || true
    systemctl stop awg-quick@awg0 >/dev/null 2>&1 || true
    ip link del awg0 >/dev/null 2>&1 || true

    _awg_restore_path "$tx_dir" mihomo_config "$AWG_MIHOMO_CONFIG"
    _awg_restore_path "$tx_dir" client_config "$AWG_CLIENT_CONFIG"
    _awg_restore_path "$tx_dir" sysctl_file "$AWG_SYSCTL_FILE"
    sysctl -w "net.ipv4.ip_forward=$(<"$tx_dir/snapshot/ip_forward")" >/dev/null 2>&1 || true
    _awg_restore_path "$tx_dir" clients "$AWG_CLIENTS_DIR"

    if [[ "$reinstall" == "1" ]]; then
        _awg_restore_path "$tx_dir" awg_dir "$AWG_DIR"
    elif [[ -f "$stage_dir/awg0.conf" ]]; then
        rm -rf -- "$AWG_DIR"
        mkdir -p -- "$AWG_DIR"
        cp -a -- "$stage_dir/." "$AWG_DIR/" 2>/dev/null || true
        chmod 600 "$AWG_CONF" "$AWG_DIR"/*.key 2>/dev/null || true
        warn "Новый конфиг оставлен для диагностики: $AWG_CONF"
    else
        _awg_restore_path "$tx_dir" awg_dir "$AWG_DIR"
    fi

    if [[ -n "$new_port" && "$(<"$tx_dir/snapshot/new_port.rule")" != "1" ]] && _awg_ufw_has_rule "$new_port"; then
        ufw delete allow "${new_port}/udp" >/dev/null 2>&1 || true
    fi
    if [[ -n "$old_port" && "$(<"$tx_dir/snapshot/old_port.rule")" == "1" ]] && ! _awg_ufw_has_rule "$old_port"; then
        ufw allow "${old_port}/udp" >/dev/null 2>&1 || true
    fi

    _awg_restore_unit_state "$tx_dir" mihomo mihomo
    _awg_restore_unit_state "$tx_dir" awg-quick@awg0 awg
    warn "Исходное состояние восстановлено. Установленные пакеты AmneziaWG оставлены в системе."
}

_awg_abort_install() {
    local tx_dir="$1" reinstall="$2" stage_dir="$3" new_port="$4" old_port="$5" reason="$6"
    _awg_fail "$reason"
    [[ -n "${AWG_MIHOMO_CANDIDATE:-}" ]] && rm -f -- "$AWG_MIHOMO_CANDIDATE"
    _awg_rollback_install "$tx_dir" "$reinstall" "$stage_dir" "$new_port" "$old_port"
    rm -rf -- "$tx_dir"
    return 1
}

_awg_packages_installed() {
    LC_ALL=C dpkg-query -W -f='${Status}' amneziawg 2>/dev/null | grep -q '^install ok installed$' \
        && command -v awg >/dev/null 2>&1 \
        && command -v awg-quick >/dev/null 2>&1
}

# ── Общая логика создания peer ──────────────────────────────────────────────
# _awg_create_peer <CLIENT_NAME>
# Создаёт peer: ключи, серверный конфиг, клиентские конфиги, QR.
# Устанавливает: PEER_IP, PEER_CONF, PEER_MIHOMO_CONF
# Возвращает 1 при ошибке.
_awg_create_peer() {
    local CLIENT_NAME="$1"

    # Определяем следующий IP
    local subnet
    subnet=$(grep 'Address' "$AWG_CONF" | head -1 | awk '{print $3}' | cut -d'.' -f1-3)
    local last_ip
    last_ip=$(grep 'AllowedIPs' "$AWG_CONF" | tail -1 | awk '{print $3}' | cut -d'/' -f1)
    [[ -z "$last_ip" ]] && last_ip="${subnet}.1"
    local next_octet=$(( ${last_ip##*.} + 1 ))

    if (( next_octet > 254 )); then
        echo "Подсеть заполнена — максимум 253 клиента" >&2
        return 1
    fi

    PEER_IP="${subnet}.${next_octet}"

    # Генерация ключей
    local client_priv client_pub psk
    client_priv=$(awg genkey)
    client_pub=$(echo "$client_priv" | awg pubkey)
    psk=$(awg genpsk)

    # Серверные параметры
    local server_pub awg_port
    server_pub=$(cat "$AWG_DIR/server_public.key")
    awg_port=$(grep 'ListenPort' "$AWG_CONF" | awk '{print $3}')

    local Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4
    Jc=$(grep '^Jc' "$AWG_CONF" | awk '{print $3}')
    Jmin=$(grep '^Jmin' "$AWG_CONF" | awk '{print $3}')
    Jmax=$(grep '^Jmax' "$AWG_CONF" | awk '{print $3}')
    S1=$(grep '^S1' "$AWG_CONF" | awk '{print $3}')
    S2=$(grep '^S2' "$AWG_CONF" | awk '{print $3}')
    S3=$(grep '^S3' "$AWG_CONF" | awk '{print $3}')
    S4=$(grep '^S4' "$AWG_CONF" | awk '{print $3}')
    H1=$(grep '^H1' "$AWG_CONF" | awk '{print $3}')
    H2=$(grep '^H2' "$AWG_CONF" | awk '{print $3}')
    H3=$(grep '^H3' "$AWG_CONF" | awk '{print $3}')
    H4=$(grep '^H4' "$AWG_CONF" | awk '{print $3}')

    # Добавляем peer в серверный конфиг
    cat >> "$AWG_CONF" << PEEREOF

# peer: $CLIENT_NAME
[Peer]
PublicKey = $client_pub
PresharedKey = $psk
AllowedIPs = ${PEER_IP}/32
PEEREOF

    # Применяем без перезапуска
    awg syncconf awg0 <(awg-quick strip "$AWG_CONF") 2>/dev/null || {
        systemctl restart awg-quick@awg0
        sleep 2
    }

    # Адрес сервера
    local SERVER_ADDR
    SERVER_ADDR=$(grep '^Domain:' /etc/mihomo/client-config.txt 2>/dev/null | awk '{print $2}')
    [[ -z "$SERVER_ADDR" ]] && SERVER_ADDR=$(curl -4 -s --max-time 5 ifconfig.me)

    local dns
    dns=$(grep '^DNS' "$AWG_DIR/clients/"*.conf 2>/dev/null | head -1 | sed 's/.*= //')
    [[ -z "$dns" ]] && dns="1.1.1.1, 1.0.0.1"

    # Клиентский конфиг
    local client_dir="/etc/mihomo/amnezia/${CLIENT_NAME}"
    mkdir -p "$client_dir"

    PEER_CONF="[Interface]
Address = ${PEER_IP}/32
DNS = $dns
PrivateKey = $client_priv
Jc = $Jc
Jmin = $Jmin
Jmax = $Jmax
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_ADDR}:${awg_port}
PersistentKeepalive = 25"

    echo "$PEER_CONF" > "$client_dir/${CLIENT_NAME}.conf"
    chmod 600 "$client_dir/${CLIENT_NAME}.conf"

    PEER_MIHOMO_CONF="--- Client proxy config Mihomo/Clash.Meta ---
proxies:
  - name: awg-${CLIENT_NAME}
    type: wireguard
    private-key: $client_priv
    server: $SERVER_ADDR
    port: $awg_port
    ip: $PEER_IP
    dns: ['${dns// /}']
    public-key: $server_pub
    pre-shared-key: $psk
    allowed-ips: ['0.0.0.0/0', '::/0']
    udp: true
    persistent-keepalive: 25
    amnezia-wg-option:
      jc: $Jc
      jmin: $Jmin
      jmax: $Jmax
      s1: $S1
      s2: $S2
      s3: $S3
      s4: $S4
      h1: $H1
      h2: $H2
      h3: $H3
      h4: $H4"

    echo "$PEER_MIHOMO_CONF" > "$client_dir/mihomo-proxy.yaml"

    # QR-код
    if command -v qrencode > /dev/null 2>&1; then
        qrencode -t PNG -o "$client_dir/qr.png" -s 5 < "$client_dir/${CLIENT_NAME}.conf"
        chmod 600 "$client_dir/qr.png"
    fi
}

awg_menu() {
    echo ""
    box_top
    box_center "AmneziaWG"
    box_bot
    echo ""
    if _awg_packages_installed; then
        echo -e "  Пакеты:        ${GREEN}установлены${NC}"
    else
        echo -e "  Пакеты:        ${RED}не установлены${NC}"
    fi
    if [[ -f "$AWG_CONF" ]]; then
        echo -e "  Конфигурация:  ${GREEN}создана${NC}"
    else
        echo -e "  Конфигурация:  ${RED}не создана${NC}"
    fi
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null && ip link show awg0 >/dev/null 2>&1; then
        echo -e "  Сервис:        ${GREEN}активен (awg0)${NC}"
    else
        echo -e "  Сервис:        ${YELLOW}не активен${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}1)${NC} Установить AmneziaWG"
    echo -e "  ${CYAN}2)${NC} Добавить клиента"
    echo -e "  ${YELLOW}3)${NC} Удалить клиента"
    echo -e "  ${RED}4)${NC} Удалить AmneziaWG"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите действие [0-4]: " AWG_CHOICE

    case "$AWG_CHOICE" in
        1) install_awg || warn "Установка AmneziaWG завершилась ошибкой. Вы можете повторить её из этого меню." ;;
        2) add_awg_peer || warn "Не удалось добавить клиента AmneziaWG." ;;
        3) remove_awg_peer || warn "Не удалось удалить клиента AmneziaWG." ;;
        4) uninstall_awg || warn "Не удалось удалить AmneziaWG." ;;
        0) return ;;
        *) warn "Неверный выбор." ;;
    esac
}

# ── Генерация обфускации (по аналогии с Amnezia-клиентом) ────────────────────

_awg_gen_params() {
    # Jc, Jmin, Jmax
    AWG_Jc=$(( RANDOM % 3 + 4 ))       # 4-6
    AWG_Jmin=10
    AWG_Jmax=50

    # S1-S4 с проверками уникальности
    while true; do
        AWG_S1=$(( RANDOM % 135 + 15 ))  # 15-149
        AWG_S2=$(( RANDOM % 135 + 15 ))
        # S1+148 != S2+92 (чтобы init и response пакеты имели разный размер)
        [[ "$AWG_S1" -ne "$AWG_S2" && $(( AWG_S1 + 148 )) -ne $(( AWG_S2 + 92 )) ]] && break
    done
    while true; do
        AWG_S3=$(( RANDOM % 63 + 1 ))    # 1-63
        [[ "$AWG_S3" -ne "$AWG_S1" && "$AWG_S3" -ne "$AWG_S2" ]] && break
    done
    while true; do
        AWG_S4=$(( RANDOM % 19 + 1 ))    # 1-19
        [[ "$AWG_S4" -ne "$AWG_S1" && "$AWG_S4" -ne "$AWG_S2" && "$AWG_S4" -ne "$AWG_S3" ]] && break
    done

    # H1-H4: восходящие непересекающиеся диапазоны [5, 2147483647]
    local nums=()
    while [[ ${#nums[@]} -lt 8 ]]; do
        local n=$(( RANDOM * RANDOM + RANDOM + 5 ))
        (( n < 5 )) && n=5
        nums+=("$n")
    done
    IFS=$'\n' nums=($(printf '%s\n' "${nums[@]}" | sort -n)); unset IFS

    AWG_H1="${nums[0]}-${nums[1]}"
    AWG_H2="${nums[2]}-${nums[3]}"
    AWG_H3="${nums[4]}-${nums[5]}"
    AWG_H4="${nums[6]}-${nums[7]}"
}

# ── Установка ────────────────────────────────────────────────────────────────

install_awg() {
    echo ""
    info "AmneziaWG — это WireGuard с обфускацией трафика против DPI."
    info "Сейчас будет установлен AWG-сервер."
    info "Peers (клиенты) создаются отдельно — через меню или remote-control."
    echo ""

    local reinstall=0 old_port="" tx_dir stage_dir old_umask
    if [[ -f "$AWG_CONF" ]]; then
        reinstall=1
        old_port=$(awk '/^ListenPort[[:space:]]*=/{print $3; exit}' "$AWG_CONF" 2>/dev/null)
        warn "AmneziaWG уже настроен."
        confirm_yn "Переустановить? (текущие клиенты будут заменены после успешного запуска)" || {
            info "Отменено."
            return 0
        }
    fi

    info "Предварительная проверка системы..."
    _awg_preflight || return 1
    success "Preflight пройден: ${AWG_ARCH}, ядро ${AWG_KERNEL}, PPA suite ${AWG_APT_SUITE}"

    DEFAULT_PORT=$(_awg_gen_free_port 30000 50000) || {
        _awg_fail "Не удалось найти свободный UDP-порт."
        return 1
    }
    read -rp "UDP порт для AmneziaWG [Enter = $DEFAULT_PORT]: " AWG_PORT
    [[ -z "$AWG_PORT" ]] && AWG_PORT="$DEFAULT_PORT"
    while true; do
        if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || (( AWG_PORT < 1 || AWG_PORT > 65535 )); then
            warn "Неверный порт '$AWG_PORT'. Введите число от 1 до 65535."
        elif ! is_port_free "$AWG_PORT" && [[ "$AWG_PORT" != "$old_port" ]]; then
            warn "Порт $AWG_PORT уже занят."
        else
            break
        fi
        read -rp "Новый порт: " AWG_PORT
        [[ -z "$AWG_PORT" ]] && { warn "Порт не указан"; return 1; }
    done

    AWG_SUBNET="10.10.8"
    AWG_SERVER_IP="${AWG_SUBNET}.1"
    DEFAULT_DNS="1.1.1.1, 1.0.0.1"
    read -rp "DNS для клиентов [Enter = $DEFAULT_DNS]: " AWG_DNS
    [[ -z "$AWG_DNS" ]] && AWG_DNS="$DEFAULT_DNS"
    _awg_gen_params

    echo ""
    info "Порт:          $AWG_PORT/udp"
    info "Подсеть:       ${AWG_SUBNET}.0/24"
    info "DNS:           $AWG_DNS"
    info "Обфускация:    Jc=$AWG_Jc S1=$AWG_S1 S2=$AWG_S2 H1=$AWG_H1 ..."
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return 0; }

    echo ""
    info "Шаг 1/4: Установка пакетов и проверка DKMS-модуля..."
    _awg_ensure_packages || return 1
    [[ -n "${AWG_REPO_TX_DIR:-}" ]] && rm -rf -- "$AWG_REPO_TX_DIR"
    AWG_REPO_TX_DIR=""

    old_umask=$(umask)
    umask 077
    tx_dir=$(mktemp -d "$AWG_TMP_BASE/awg-install.XXXXXX") || {
        umask "$old_umask"
        _awg_fail "Не удалось создать временную директорию установки."
        return 1
    }
    umask "$old_umask"
    stage_dir="$tx_dir/new-awg"
    _awg_snapshot_state "$tx_dir" "$old_port" "$AWG_PORT" || {
        rm -rf -- "$tx_dir"
        _awg_fail "Не удалось сохранить исходное состояние перед установкой."
        return 1
    }

    echo ""
    info "Шаг 2/4: Подготовка ключей и конфигурации..."
    AWG_TPROXY_PORT=$(_awg_gen_free_port 10000 60000) || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось найти свободный TPROXY-порт."
        return 1
    }
    _awg_stage_server_config "$stage_dir" || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось сгенерировать ключи или серверный конфиг."
        return 1
    }
    AWG_MIHOMO_CANDIDATE=""
    _awg_prepare_mihomo_candidate "$AWG_TPROXY_PORT" || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Конфигурация Mihomo не прошла проверку."
        return 1
    }
    success "Новая конфигурация подготовлена и проверена Mihomo"

    echo ""
    info "Шаг 3/4: Атомарное применение конфигурации..."
    if [[ "$(<"$tx_dir/snapshot/awg.active")" == "1" ]]; then
        systemctl stop awg-quick@awg0 || {
            _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"                 "Не удалось остановить прежний сервис AWG."
            return 1
        }
    fi
    ip link del awg0 >/dev/null 2>&1 || true
    _awg_install_staged_config "$stage_dir" || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось установить серверный конфиг AWG."
        return 1
    }
    mv -f -- "$AWG_MIHOMO_CANDIDATE" "$AWG_MIHOMO_CONFIG" || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось применить проверенный config.yaml."
        return 1
    }
    AWG_MIHOMO_CANDIDATE=""
    _awg_apply_ip_forwarding || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось включить IPv4 forwarding."
        return 1
    }
    systemctl restart mihomo || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Mihomo не запустился с новой конфигурацией."
        return 1
    }
    systemctl enable awg-quick@awg0 || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось включить systemd-unit AWG."
        return 1
    }
    systemctl restart awg-quick@awg0 || {
        journalctl -u awg-quick@awg0 -n 40 --no-pager 2>/dev/null || true
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Сервис awg-quick@awg0 не запустился."
        return 1
    }
    sleep 2
    if ! systemctl is-active --quiet awg-quick@awg0 || ! ip link show awg0; then
        journalctl -u awg-quick@awg0 -n 40 --no-pager 2>/dev/null || true
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Проверка active-state/interface awg0 завершилась ошибкой."
        return 1
    fi
    success "Сервис активен, интерфейс awg0 создан"

    echo ""
    info "Шаг 4/4: Обновление клиентов и firewall..."
    rm -rf -- "$AWG_CLIENTS_DIR"
    mkdir -p -- "$AWG_CLIENTS_DIR" || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось создать директорию клиентских конфигов."
        return 1
    }
    chmod 700 "$AWG_CLIENTS_DIR"
    _awg_write_client_info || {
        _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"             "Не удалось обновить client-config.txt."
        return 1
    }
    if ! _awg_ufw_has_rule "$AWG_PORT"; then
        ufw allow "${AWG_PORT}/udp" || {
            _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"                 "Не удалось открыть UDP-порт в UFW."
            return 1
        }
    fi
    if [[ -n "$old_port" && "$old_port" != "$AWG_PORT" && "$(<"$tx_dir/snapshot/old_port.rule")" == "1" ]]; then
        ufw delete allow "${old_port}/udp" || {
            _awg_abort_install "$tx_dir" "$reinstall" "$stage_dir" "$AWG_PORT" "$old_port"                 "Не удалось удалить прежнее правило UFW."
            return 1
        }
    fi
    success "Порт $AWG_PORT/udp открыт, client-config.txt обновлён"

    rm -rf -- "$tx_dir"
    echo ""
    success_box "AmneziaWG сервер установлен!"
    echo ""
    echo -e "  Сервер:      ${CYAN}${SERVER_ADDR}:${AWG_PORT}${NC}"
    echo -e "  Подсеть:     ${CYAN}${AWG_SUBNET}.0/24${NC}"
    echo ""

    if confirm_yn "Создать peer сейчас?" Y; then
        add_awg_peer
    else
        info "Peers можно создать позже через меню или remote-control."
    fi
}

# ── Добавить клиента ─────────────────────────────────────────────────────────

add_awg_peer() {
    echo ""

    if [[ ! -f "$AWG_CONF" ]]; then
        warn "AmneziaWG не установлен. Сначала выполните установку."
        return
    fi

    local client_num
    client_num=$(ls "$AWG_DIR/clients/" 2>/dev/null | wc -l)
    client_num=$(( client_num + 1 ))

    read -rp "Имя клиента [Enter = client${client_num}]: " CLIENT_NAME
    [[ -z "$CLIENT_NAME" ]] && CLIENT_NAME="client${client_num}"

    if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "Имя клиента может содержать только буквы, цифры, - и _"
        return
    fi

    if [[ -d "/etc/mihomo/amnezia/${CLIENT_NAME}" ]]; then
        warn "Клиент '$CLIENT_NAME' уже существует."
        confirm_yn "Перезаписать?" || { info "Отменено."; return; }
        sed -i "/# peer: $CLIENT_NAME/,/^$/d" "$AWG_CONF"
        rm -rf "/etc/mihomo/amnezia/${CLIENT_NAME}"
    fi

    _awg_create_peer "$CLIENT_NAME" || { warn "Не удалось создать peer."; return; }

    local client_dir="/etc/mihomo/amnezia/${CLIENT_NAME}"
    echo ""
    success_box "Клиент AmneziaWG добавлен!"
    echo ""
    echo -e "  Имя:     ${CYAN}$CLIENT_NAME${NC}"
    echo -e "  IP:      ${CYAN}$PEER_IP${NC}"
    echo -e "  Конфиг AWG:    ${CYAN}$client_dir/${CLIENT_NAME}.conf${NC}"
    echo -e "  Конфиг Mihomo: ${CYAN}$client_dir/mihomo-proxy.yaml${NC}"
    echo -e "  QR-код:        ${CYAN}$client_dir/qr.png${NC}"
    echo ""

    if command -v qrencode > /dev/null 2>&1; then
        echo -e "  ${CYAN}QR-код:${NC}"
        echo ""
        qrencode -t ANSIUTF8 < "$client_dir/${CLIENT_NAME}.conf"
        echo ""
    fi

    echo -e "  ${CYAN}Конфиг клиента AWG:${NC}"
    echo -e "${DIM}"
    echo "$PEER_CONF"
    echo -e "${NC}"
    echo -e "  ${CYAN}Конфиг клиента Mihomo/Clash.Meta:${NC}"
    echo -e "${DIM}"
    echo "$PEER_MIHOMO_CONF"
    echo -e "${NC}"
}

# ── Автоматическое добавление клиента (неинтерактивное) ────────────────────────
# Использование: add_awg_peer_auto <имя_клиента>
# Возвращает 0 при успехе, 1 при ошибке. Вывод в stderr.

add_awg_peer_auto() {
    local CLIENT_NAME="$1"

    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Имя клиента не указано" >&2
        return 1
    fi

    if [[ ! -f "$AWG_CONF" ]]; then
        echo "AmneziaWG не установлен" >&2
        return 1
    fi

    # Если peer уже существует — пропускаем
    if [[ -d "/etc/mihomo/amnezia/${CLIENT_NAME}" ]]; then
        return 0
    fi

    _awg_create_peer "$CLIENT_NAME" || return 1

    echo "AWG peer $CLIENT_NAME создан (IP: $PEER_IP)" >&2
    return 0
}

# ── Удалить клиента ──────────────────────────────────────────────────────────

remove_awg_peer() {
    echo ""

    if [[ ! -f "$AWG_CONF" ]]; then
        warn "AmneziaWG не установлен."
        return
    fi

    # Список клиентов
    local clients_dir="/etc/mihomo/amnezia"
    local clients=()
    if [[ -d "$clients_dir" ]]; then
        for d in "$clients_dir"/*/; do
            [[ -d "$d" ]] && clients+=("$(basename "$d")")
        done
    fi

    if [[ ${#clients[@]} -eq 0 ]]; then
        warn "Нет клиентов для удаления."
        return
    fi

    echo -e "  ${CYAN}Клиенты:${NC}"
    local i=1
    for c in "${clients[@]}"; do
        local c_ip
        c_ip=$(grep -A3 "# peer: $c" "$AWG_CONF" 2>/dev/null | grep 'AllowedIPs' | awk '{print $3}' | cut -d'/' -f1)
        echo -e "  ${GREEN}${i})${NC} $c ${DIM}${c_ip}${NC}"
        i=$((i + 1))
    done
    echo ""

    read -rp "Номер клиента для удаления [1-${#clients[@]}]: " CLIENT_NUM
    if ! [[ "$CLIENT_NUM" =~ ^[0-9]+$ ]] || (( CLIENT_NUM < 1 || CLIENT_NUM > ${#clients[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local client_name="${clients[$((CLIENT_NUM - 1))]}"

    warn "Будет удалён клиент: $client_name"
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    # Удаляем peer из серверного конфига
    if grep -q "# peer: $client_name" "$AWG_CONF"; then
        sed -i "/# peer: $client_name/,/^$/d" "$AWG_CONF"
        success "Peer удалён из серверного конфига"
    fi

    # Применяем без перезапуска
    awg syncconf awg0 <(awg-quick strip "$AWG_CONF") 2>/dev/null || {
        warn "syncconf не сработал, перезапускаю сервис..."
        systemctl restart awg-quick@awg0
        sleep 2
    }

    # Удаляем папку клиента
    rm -rf "${clients_dir}/${client_name}"
    success "Конфиг клиента удалён"

    echo ""
    success "Клиент $client_name удалён."
    echo ""
}

# Неинтерактивное удаление peer по имени (для вызова из remote-control)
remove_awg_peer_by_name() {
    local client_name="$1"
    [[ -z "$client_name" ]] && { echo "Имя не указано" >&2; return 1; }
    [[ ! -f "$AWG_CONF" ]] && { echo "AWG не установлен" >&2; return 1; }

    local clients_dir="/etc/mihomo/amnezia"
    if [[ ! -d "${clients_dir}/${client_name}" ]]; then
        echo "Peer $client_name не найден" >&2
        return 1
    fi

    # Удаляем peer из серверного конфига
    if grep -q "# peer: $client_name" "$AWG_CONF"; then
        sed -i "/# peer: $client_name/,/^$/d" "$AWG_CONF"
    fi

    # Применяем без перезапуска
    awg syncconf awg0 <(awg-quick strip "$AWG_CONF") 2>/dev/null || {
        systemctl restart awg-quick@awg0 2>/dev/null
        sleep 2
    }

    # Удаляем папку клиента
    rm -rf "${clients_dir}/${client_name}"
    echo "Peer $client_name удалён" >&2
}

# ── Удаление ─────────────────────────────────────────────────────────────────

uninstall_awg() {
    echo ""

    if [[ ! -f "$AWG_CONF" ]] && ! command -v awg > /dev/null 2>&1; then
        warn "AmneziaWG не установлен."
        return
    fi

    warn "Будет удалён AmneziaWG: сервис, конфиги, ключи, клиенты."
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    # Порт для закрытия в firewall
    local awg_port
    awg_port=$(grep 'ListenPort' "$AWG_CONF" 2>/dev/null | awk '{print $3}')

    awg-quick down awg0 2>/dev/null || true
    systemctl stop awg-quick@awg0 2>/dev/null || true
    systemctl disable awg-quick@awg0 2>/dev/null || true
    success "Сервис остановлен"

    # Убрать tproxy-port (добавлялся при установке AWG)
    if grep -q '^tproxy-port:' /etc/mihomo/config.yaml 2>/dev/null; then
        sed -i '/^tproxy-port:/d' /etc/mihomo/config.yaml
        systemctl restart mihomo &>/dev/null
        sleep 2
        success "tproxy-port убран из config.yaml"
    fi

    rm -rf "$AWG_DIR"
    rm -rf /etc/amnezia
    rm -rf /etc/mihomo/amnezia
    success "Конфиги, ключи и клиенты удалены"

    if [[ -n "$awg_port" ]]; then
        ufw delete allow "${awg_port}/udp" > /dev/null 2>&1 || true
        success "Порт $awg_port/udp закрыт"
    fi

    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed '/^--- AmneziaWG ---/,/^--- \/AmneziaWG ---/d' /etc/mihomo/client-config.txt > /tmp/client_tmp.txt
        mv /tmp/client_tmp.txt /etc/mihomo/client-config.txt
        success "Секция AmneziaWG удалена из client-config.txt"
    fi

    info "Перезагрузка systemd..."
    systemctl daemon-reload

    echo ""
    success "AmneziaWG полностью удалён."
    echo ""
}
