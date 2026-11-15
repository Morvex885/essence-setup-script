#!/bin/bash
# Validate representative node renders with the real mihomo and nginx.
#
#   sudo tests/ci/validate_render.sh DUMP_DIR MIHOMO_BIN
#
# DUMP_DIR is written by the `dump_representative_renders` test of
# remote-control/core/src/server/render/tests.rs (ESSENCE_RENDER_DUMP): one
# directory per topology with the rendered files at their node paths. Every
# topology: `mihomo -t` on its config.yaml, then its nginx files are put over
# a pristine /etc/nginx (as `node apply` does), each certificate pair the
# configs reference gets a self-signed stand-in, and `nginx -t` runs.
# Needs root, nginx and libnginx-mod-stream (Debian/Ubuntu layout).
set -euo pipefail

dump=${1:?DUMP_DIR}
mihomo=${2:?MIHOMO_BIN}
compgen -G "$dump/*/etc/mihomo/config.yaml" >/dev/null || { echo "No renders in $dump" >&2; exit 1; }
pristine=$(mktemp -d)
work=$(mktemp -d)
cp -a /etc/nginx/. "$pristine/"
# shellcheck disable=SC2317  # called by the EXIT trap
restore() { rm -rf /etc/nginx && mkdir /etc/nginx && cp -a "$pristine/." /etc/nginx/; rm -rf "$pristine" "$work"; }
trap restore EXIT

# "certificate key" pairs on stdin: nginx ssl_certificate/_key lines and the
# mihomo `certificate:` line with the `private-key:` that follows it.
cert_pairs() {
    awk '
        /^[[:space:]]*ssl_certificate[[:space:]]/     { gsub(";", "", $2); cert = $2 }
        /^[[:space:]]*ssl_certificate_key[[:space:]]/ { gsub(";", "", $2); if (cert != "") print cert, $2; cert = "" }
        /^[[:space:]]*certificate:[[:space:]]/        { mcert = $2 }
        /^[[:space:]]*private-key:[[:space:]]/        { if (mcert != "") print mcert, $2; mcert = "" }
    ' | sort -u
}

failed=0
for dir in "$dump"/*/; do
    name=$(basename "$dir")
    echo "== $name"
    if ! "$mihomo" -t -d "$work/mihomo-$name" -f "$dir/etc/mihomo/config.yaml"; then
        echo "FAIL $name: mihomo -t" >&2
        failed=1
    fi
    [[ -d "$dir/etc/nginx" ]] || continue
    rm -rf /etc/nginx && mkdir /etc/nginx && cp -a "$pristine/." /etc/nginx/
    cp -a "$dir/etc/nginx/." /etc/nginx/
    # Created by the executor's sub_prepare before nginx is reloaded.
    mkdir -p /etc/nginx/snippets/essence-sub
    while read -r cert key; do
        mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
            -subj "/CN=$(basename "$(dirname "$cert")")" -keyout "$key" -out "$cert" 2>/dev/null
    done < <({ cat "$dir/etc/mihomo/config.yaml"; find "$dir/etc/nginx" -type f -exec cat {} +; } | cert_pairs)
    if ! nginx -t; then
        echo "FAIL $name: nginx -t" >&2
        failed=1
    fi
done
exit "$failed"
