#!/bin/bash
# ─── Установщик essence-rc (Remote Control) ───────────────────────────────────
# Определяет ОС и архитектуру, скачивает бинарник essence-rc из релиза GitHub,
# сверяет SHA256 с SHA256SUMS и ставит его в /usr/local/bin/essence-rc
# (Termux: $PREFIX/bin/essence-rc, без root).
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/Morvex885/essence-setup-script/main/install-essence-rc.sh | bash
# Переменные окружения:
#   ESSENCE_RC_VERSION      тег релиза (например v2.0.0); по умолчанию — последний
#   ESSENCE_RC_BASE_URL     каталог с ассетами релиза (зеркало); важнее ESSENCE_RC_VERSION
#   ESSENCE_RC_INSTALL_DIR  каталог установки вместо /usr/local/bin
# Windows: см. README (zip-архив, проверка Get-FileHash).

if (( BASH_VERSINFO[0] < 3 || ( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf '  [✗] Требуется Bash 3.2 или новее.\n' >&2
    exit 1
fi

set -euo pipefail

REPO="Morvex885/essence-setup-script"
BIN_NAME="essence-rc"

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "  ${CYAN}[*]${NC} $*"; }
success() { echo -e "  ${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
error()   { echo -e "  ${RED}[✗]${NC} $*" >&2; exit 1; }

# ─── Платформа ───────────────────────────────────────────────────────────────
is_termux() {
    [[ -n "${TERMUX_VERSION:-}" || "${PREFIX:-}" == *com.termux* ]]
}

# ldd из musl завершается с ненулевым кодом даже на --version, поэтому
# вывод захватывается целиком, а код возврата ldd игнорируется (pipefail).
is_musl() {
    local out
    out=$(ldd --version 2>&1) || true
    [[ "$out" == *[Mm][Uu][Ss][Ll]* ]]
}

# Печатает Rust target triple или возвращает 1, если платформа не поддерживается.
detect_target() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            if is_termux; then
                case "$arch" in
                    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
                    *) return 1 ;;
                esac
                return 0
            fi
            case "$arch" in
                x86_64|amd64)
                    is_musl && return 1
                    echo "x86_64-unknown-linux-gnu" ;;
                aarch64|arm64)
                    if is_musl; then echo "aarch64-unknown-linux-musl"
                    else echo "aarch64-unknown-linux-gnu"; fi ;;
                armv7l|armv7*|armv8l)
                    is_musl && return 1
                    echo "armv7-unknown-linux-gnueabihf" ;;
                *) return 1 ;;
            esac
            ;;
        Darwin)
            case "$arch" in
                x86_64) echo "x86_64-apple-darwin" ;;
                arm64|aarch64) echo "aarch64-apple-darwin" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        error "Не найден sha256sum или shasum — нечем проверить контрольную сумму."
    fi
}

# ─── Права ───────────────────────────────────────────────────────────────────
SUDO=""
as_owner() {
    if [[ -n "$SUDO" ]]; then sudo "$@"; else "$@"; fi
}

# Каталог доступен на запись (или его можно создать) без повышения прав.
dir_writable() {
    local dir="$1"
    while [[ ! -d "$dir" ]]; do
        dir=$(dirname "$dir")
    done
    [[ -w "$dir" ]]
}

# ─── Bootstrap curl/tar ──────────────────────────────────────────────────────
bootstrap_install() {
    local pkg="$1"
    if is_termux && command -v pkg >/dev/null 2>&1; then pkg install -y "$pkg" >/dev/null
    elif [[ $EUID -ne 0 ]]; then return 1
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$pkg" >/dev/null
    elif command -v yum >/dev/null 2>&1; then yum install -y -q "$pkg" >/dev/null
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache "$pkg" >/dev/null
    elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm "$pkg" >/dev/null
    else return 1
    fi
}

# ─── Установка ───────────────────────────────────────────────────────────────
main() {
    local target asset base_url install_dir tmp_dir expected actual dest

    for tool in curl tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            info "Устанавливаем $tool..."
            bootstrap_install "$tool" || error "Не найден $tool. Установите его и повторите."
        fi
    done

    target=$(detect_target) \
        || error "Платформа не поддерживается: $(uname -s)/$(uname -m). Windows — см. README; другие системы — сборка из исходников (remote-control/)."
    asset="${BIN_NAME}-${target}.tar.gz"

    if [[ -n "${ESSENCE_RC_BASE_URL:-}" ]]; then
        base_url="${ESSENCE_RC_BASE_URL%/}"
    elif [[ -n "${ESSENCE_RC_VERSION:-}" ]]; then
        base_url="https://github.com/${REPO}/releases/download/${ESSENCE_RC_VERSION}"
    else
        base_url="https://github.com/${REPO}/releases/latest/download"
    fi

    if [[ -n "${ESSENCE_RC_INSTALL_DIR:-}" ]]; then
        install_dir="$ESSENCE_RC_INSTALL_DIR"
    elif is_termux; then
        install_dir="${PREFIX:?}/bin"
    else
        install_dir="/usr/local/bin"
    fi

    if ! dir_writable "$install_dir" && [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 \
            || error "Нет прав на запись в $install_dir. Запустите от root или задайте ESSENCE_RC_INSTALL_DIR."
        SUDO="sudo"
        info "Для записи в $install_dir понадобится sudo."
    fi

    info "Платформа: $target"
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    info "Скачиваем $asset..."
    curl -fsSL "$base_url/$asset" -o "$tmp_dir/$asset" \
        || error "Не удалось скачать $base_url/$asset"
    curl -fsSL "$base_url/SHA256SUMS" -o "$tmp_dir/SHA256SUMS" \
        || error "Не удалось скачать $base_url/SHA256SUMS"

    expected=$(awk -v f="$asset" '{ n = $2; sub(/^[*]/, "", n); sub(/^\.\//, "", n); if (n == f) { print tolower($1); exit } }' \
        "$tmp_dir/SHA256SUMS" | tr -d '\r')
    [[ -n "$expected" ]] || error "В SHA256SUMS нет записи для $asset. Установка отменена."
    actual=$(sha256_of "$tmp_dir/$asset")
    [[ "$actual" == "$expected" ]] \
        || error "Контрольная сумма $asset не совпала (ожидалось $expected, получено $actual). Установка отменена."
    success "Контрольная сумма совпала"

    mkdir -p "$tmp_dir/x"
    tar -xzf "$tmp_dir/$asset" -C "$tmp_dir/x"
    [[ -f "$tmp_dir/x/$BIN_NAME" ]] || error "В архиве $asset нет файла $BIN_NAME. Установка отменена."
    chmod 755 "$tmp_dir/x/$BIN_NAME"

    dest="$install_dir/$BIN_NAME"
    as_owner mkdir -p "$install_dir"
    # Копия рядом с целью и rename — запущенный essence-rc не повредится.
    as_owner cp "$tmp_dir/x/$BIN_NAME" "$dest.new"
    as_owner chmod 755 "$dest.new"
    as_owner mv -f "$dest.new" "$dest"
    success "Установлено: $dest"

    if "$dest" --version >/dev/null 2>&1; then
        info "Версия: $("$dest" --version 2>/dev/null)"
    else
        warn "Не удалось запустить $dest --version"
    fi
    case ":$PATH:" in
        *":$install_dir:"*) ;;
        *) warn "$install_dir нет в PATH — добавьте его, чтобы запускать $BIN_NAME по имени." ;;
    esac
    info "Запуск: $BIN_NAME"
}

main "$@"
