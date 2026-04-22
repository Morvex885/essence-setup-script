#!/bin/bash
# ─── Установщик essence-setup (серверный инструмент) ──────────────────────────
# Устанавливает essence-setup на VPS / сервер.
# Использование:
#   sudo bash install-essence.sh                          # публичный репо
#   sudo GITHUB_TOKEN=ghp_xxx bash install-essence.sh     # приватный репо

set -euo pipefail

REPO="Morvex885/essence-setup-script"
INSTALL_DIR="/opt/essence-setup"
BIN_DIR="/usr/local/bin"
VERSION_FILE="$INSTALL_DIR/VERSION"
TOKEN="${GITHUB_TOKEN:-}"
TOOL_NAME="essence-setup"

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "  ${CYAN}[*]${NC} $*"; }
success() { echo -e "  ${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
error()   { echo -e "  ${RED}[✗]${NC} $*"; exit 1; }

# ─── Проверки ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Запустите от root: sudo bash install-essence.sh"

# ─── Bootstrap curl/tar (нужны ДО скачивания репозитория) ─────────────────────
_bootstrap_install() {
    local pkg="$1"
    if   command -v apt-get &>/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
                                               DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null
    elif command -v dnf     &>/dev/null; then dnf    install -y -q "$pkg" >/dev/null
    elif command -v yum     &>/dev/null; then yum    install -y -q "$pkg" >/dev/null
    elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm --needed "$pkg" >/dev/null
    elif command -v zypper  &>/dev/null; then zypper --non-interactive --quiet install "$pkg" >/dev/null
    elif command -v apk     &>/dev/null; then apk    add --quiet --no-progress "$pkg"
    else return 127
    fi
}
for _b in curl tar; do
    command -v "$_b" &>/dev/null && continue
    info "Отсутствует ${_b} — ставим автоматически..."
    _bootstrap_install "$_b" || error "Не удалось поставить ${_b}. Установите вручную и повторите запуск."
    command -v "$_b" &>/dev/null || error "${_b} не появился в PATH."
    success "${_b} установлен"
done
unset _b

# ─── GitHub API ───────────────────────────────────────────────────────────────
_CURL_ARGS=(-fsSL)
[[ -n "$TOKEN" ]] && _CURL_ARGS+=(-H "Authorization: token $TOKEN")

api_get() {
    curl "${_CURL_ARGS[@]}" "$1"
}

get_latest_tag() {
    api_get "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' \
        | grep -o '"[^"]*"$' \
        | tr -d '"'
}

download_tarball() {
    local tag="$1" dest="$2"

    # Предпочитаем gh CLI (автоматически работает с приватными репо)
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        info "Скачиваем ${tag} через gh CLI..."
        gh release download "$tag" --repo "$REPO" \
            --pattern "essence-setup-*.tar.gz" \
            --output "$dest" 2>/dev/null && return
    fi

    # Fallback: curl через API (работает с токеном для приватных репо)
    info "Скачиваем ${tag} через curl..."
    curl "${_CURL_ARGS[@]}" --location-trusted \
        "https://api.github.com/repos/${REPO}/tarball/${tag}" \
        -o "$dest"
}

# ─── Установка ────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}  essence-setup — установщик${NC}"
    echo ""

    # Получаем последнюю версию
    info "Проверяем последнюю версию..."
    local latest
    latest=$(get_latest_tag 2>/dev/null) || error "Не удалось получить версию из GitHub.\nДля приватного репо укажите токен: sudo GITHUB_TOKEN=ghp_xxx bash install-essence.sh"
    [[ -z "$latest" ]] && error "GitHub не вернул версию. Возможно, ещё нет ни одного релиза."

    # Проверяем текущую версию
    local current="none"
    [[ -f "$VERSION_FILE" ]] && current=$(tr -d '\r' < "$VERSION_FILE")

    if [[ "$current" == "$latest" ]]; then
        success "Уже установлена актуальная версия: ${latest}"
        exit 0
    fi

    if [[ "$current" == "none" ]]; then
        info "Устанавливаем версию ${latest}..."
    else
        info "Обновление: ${current} → ${latest}"
    fi

    # Скачиваем архив во временную директорию
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "${tmp_dir:-}"' EXIT

    download_tarball "$latest" "$tmp_dir/archive.tar.gz"

    # Распаковываем (strip-components=1 убирает корневой каталог архива)
    mkdir -p "$tmp_dir/pkg"
    tar -xzf "$tmp_dir/archive.tar.gz" -C "$tmp_dir/pkg" --strip-components=1

    # Устанавливаем файлы
    mkdir -p "$INSTALL_DIR/modules" "$INSTALL_DIR/common"
    cp "$tmp_dir/pkg/setup-essence/setup-essence.sh"      "$INSTALL_DIR/"
    cp "$tmp_dir/pkg/setup-essence/install-essence.sh"    "$INSTALL_DIR/"
    cp "$tmp_dir/pkg/VERSION"                           "$INSTALL_DIR/"
    cp "$tmp_dir/pkg/setup-essence/modules/"*.sh         "$INSTALL_DIR/modules/"
    cp "$tmp_dir/pkg/common/common.sh"                  "$INSTALL_DIR/common/"
    cp "$tmp_dir/pkg/common/ensure-deps.sh"             "$INSTALL_DIR/common/"

    chmod +x "$INSTALL_DIR/setup-essence.sh" \
              "$INSTALL_DIR/install-essence.sh" \
              "$INSTALL_DIR/modules/"*.sh

    # Симлинк в PATH
    ln -sf "$INSTALL_DIR/setup-essence.sh" "$BIN_DIR/essence-setup"

    echo ""
    success "Версия ${latest} установлена!"
    success "Команда: ${GREEN}essence-setup${NC}"
    echo ""
}

main
