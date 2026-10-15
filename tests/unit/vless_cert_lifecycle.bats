#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    source_common
    source "$PROJECT_ROOT/common/cert.sh"
    source "$PROJECT_ROOT/tests/helpers/cert_fixture_helper.bash"
    cert_fixture_init "$BATS_TEST_TMPDIR/crypto"
    cert_fixture_runtime "$BATS_TEST_TMPDIR/runtime"
    cert_fixture_fake_acme
    local root="$BATS_TEST_TMPDIR/server"
    mkdir -p "$root/etc/mihomo" "$root/etc/nginx/sites-available" "$root/etc/nginx/sites-enabled" "$root/var/www"
    printf 'events {}\nhttp {}\n' > "$root/etc/nginx/nginx.conf"
    printf 'listeners: []\n' > "$root/etc/mihomo/config.yaml"
    sed -e "s|/etc/|$root/etc/|g" -e "s|/var/www/|$root/var/www/|g" \
        "$PROJECT_ROOT/setup-essence/modules/vless.sh" > "$BATS_TEST_TMPDIR/vless.sh"
    source "$BATS_TEST_TMPDIR/vless.sh"
    export VLESS_ROOT="$root"
    # Route common's paths as well as the copied consumer's literal paths.
    eval "$(declare -f ensure_cert | sed '1s/ensure_cert/_fixture_ensure_cert/')"
    ensure_cert() {
        _fixture_ensure_cert "$1" "$2" "$3" "$VLESS_ROOT/etc/nginx/ssl" \
            "$VLESS_ROOT/etc/nginx/sites-available" "$VLESS_ROOT/etc/nginx/sites-enabled" "$VLESS_ROOT/etc/nginx/nginx.conf"
    }
    _check_base() { return 0; }
    apt_wait() { return 0; }
    apt-get() { return 0; }
    dpkg() { return 1; }
    sleep() { return 0; }
    curl() { if [[ "$*" == *'%{http_code}'* ]]; then printf 200; else printf '203.0.113.10'; fi; }
    getent() { printf '203.0.113.10 %s\n' "$2"; }
    uuidgen() { printf '11111111-1111-4111-8111-111111111111\n'; }
    acme_select_email() { ACME_SELECTED_EMAIL=test@example.test; }
    ensure_essence_acme_email() { return 0; }
    setup_fake_site() { printf 'decoy\n' > "$1/index.html"; }
    confirm_yn() { [[ "$1" != 'Добавить свой домен с сайтом-заглушкой?' ]]; }
}
teardown() { teardown_test_env; }

@test "Self-Steal reuses managed installed certificate and preserves another enabled site" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/leaf" web.example.test
    cert_fixture_archive web.example.test "$BATS_TEST_TMPDIR/leaf" ecc active
    cert_fixture_installed "$VLESS_ROOT/etc/nginx/ssl" web.example.test "$BATS_TEST_TMPDIR/leaf"
    printf 'other consumer\n' > "$VLESS_ROOT/etc/nginx/sites-enabled/other"
    cp "$VLESS_ROOT/etc/nginx/ssl/web.example.test/fullchain.pem" "$BATS_TEST_TMPDIR/before.pem"
    setup_reality <<< $'1\nweb.example.test\n'
    cmp "$BATS_TEST_TMPDIR/before.pem" "$VLESS_ROOT/etc/nginx/ssl/web.example.test/fullchain.pem"
    [[ ! -s "$ACME_ORDER_LOG" ]]
    [[ -f "$VLESS_ROOT/etc/nginx/sites-enabled/other" ]]
    [[ -L "$VLESS_ROOT/etc/nginx/sites-enabled/web.example.test" ]]
    cert_is_usable web.example.test "$VLESS_ROOT/etc/nginx/ssl/web.example.test/fullchain.pem" "$VLESS_ROOT/etc/nginx/ssl/web.example.test/privkey.pem"
}

@test "SNI IP restores paused archive without issuing a certificate" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/leaf" 203.0.113.10 IP:203.0.113.10
    cert_fixture_archive 203.0.113.10 "$BATS_TEST_TMPDIR/leaf" ecc removed
    setup_reality <<< $'2\nwww.example.test\n'
    cert_is_usable 203.0.113.10 "$VLESS_ROOT/etc/nginx/ssl/203.0.113.10/fullchain.pem" "$VLESS_ROOT/etc/nginx/ssl/203.0.113.10/privkey.pem" true
    [[ -f "$HOME/.acme.sh/203.0.113.10_ecc/203.0.113.10.conf" ]]
    [[ ! -e "$HOME/.acme.sh/203.0.113.10_ecc/203.0.113.10.conf.removed" ]]
    [[ ! -s "$ACME_ORDER_LOG" ]]
    [[ -L "$VLESS_ROOT/etc/nginx/sites-enabled/essence-acme-203.0.113.10" ]]
}
