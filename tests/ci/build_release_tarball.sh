#!/bin/bash
# Собирает релизный архив серверного комплекта essence-setup-<version>.tar.gz
# (+ .sha256) в <outdir> и проверяет, что в нём есть каждый tracked-файл из
# common/, setup-essence/ и VERSION — их требует setup-essence/install-essence.sh.
# Клиент Remote Control выходит отдельными бинарниками essence-rc-<target>,
# поэтому remote-control/ (Cargo workspace клиента) в архив не входит.
# Использование: build_release_tarball.sh <version> [outdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION="${1:?Использование: build_release_tarball.sh <version> [outdir]}"
OUT_DIR="$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd)"
TARBALL="essence-setup-${VERSION}.tar.gz"
DIST="$OUT_DIR/dist/essence-setup"

cd "$PROJECT_ROOT"

# Список заранее: при ошибке git ls-files set -e остановит скрипт,
# а пустой список не даст проверке пройти вхолостую.
files=$(git ls-files common setup-essence VERSION)
[[ -n "$files" ]] || { echo "::error::git ls-files вернул пустой список" >&2; exit 1; }

rm -rf "$OUT_DIR/dist"
mkdir -p "$DIST/setup-essence/modules" "$DIST/common"
cp setup-essence/setup-essence.sh setup-essence/install-essence.sh "$DIST/setup-essence/"
cp setup-essence/modules/*.sh "$DIST/setup-essence/modules/"
cp -r common/. "$DIST/common/"
cp VERSION "$DIST/"

# Архив с корнем essence-setup/ → при распаковке --strip-components=1
tar -czf "$OUT_DIR/$TARBALL" -C "$OUT_DIR/dist" essence-setup
(cd "$OUT_DIR" && sha256sum "$TARBALL" > "${TARBALL}.sha256")

listing=$(tar -tzf "$OUT_DIR/$TARBALL")
missing=0
while IFS= read -r f; do
    if ! grep -qxF "essence-setup/$f" <<<"$listing"; then
        echo "::error::В архиве $TARBALL нет $f" >&2
        missing=1
    fi
done <<<"$files"
if grep -qE '^essence-setup/remote-control/' <<<"$listing"; then
    echo "::error::В архив $TARBALL попал remote-control/ (исходники клиента)" >&2
    missing=1
fi
exit "$missing"
