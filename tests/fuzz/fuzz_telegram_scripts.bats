#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source_module 'telegram-proxy.sh'
    export SETUP_DIR="$BATS_TEST_TMPDIR/setup root"
    export COMMON_DIR="$BATS_TEST_TMPDIR/common root"
    export VERSION_PATH="$BATS_TEST_TMPDIR/VERSION"
    export TELEGRAM_PROXY_REMOTE_DIR="$BATS_TEST_TMPDIR/remote root 'quoted'"
    export REMOTE_DIR="$TELEGRAM_PROXY_REMOTE_DIR"
    mkdir -p "$SETUP_DIR/modules" "$COMMON_DIR/protocols" "$TELEGRAM_PROXY_REMOTE_DIR"
    printf '0.0.1\n' > "$VERSION_PATH"
    printf '#!/bin/bash\n' > "$SETUP_DIR/setup-essence.sh"
    chmod 755 "$SETUP_DIR/setup-essence.sh"
    printf '%s\n' '# telegram' > "$SETUP_DIR/modules/telegram-proxy.sh"
    printf '%s\n' '# module' > "$SETUP_DIR/modules/other.sh"
    printf '%s\n' '# common' > "$COMMON_DIR/common.sh"
    printf '%s\n' '# cert' > "$COMMON_DIR/cert.sh"
    printf '%s\n' '# deps' > "$COMMON_DIR/ensure-deps.sh"
    printf '%s\n' '# protocol' > "$COMMON_DIR/protocols/uri.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    local real_sha256sum real_shasum
    real_sha256sum=$(type -P sha256sum 2>/dev/null || :)
    real_shasum=$(type -P shasum 2>/dev/null || :)
    [[ -n "$real_sha256sum" || -n "$real_shasum" ]] || {
        printf '%s\n' 'sha256sum or shasum is required' >&2
        return 1
    }
    export TEST_REAL_SHA256SUM="$real_sha256sum" TEST_REAL_SHASUM="$real_shasum"
    cat > "$BATS_TEST_TMPDIR/bin/sha256sum" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == --check ]]; then
    if [[ -n "${TEST_REAL_SHA256SUM:-}" ]]; then
        "$TEST_REAL_SHA256SUM" --check --status </dev/null >/dev/null 2>&1
        if [[ "$?" -eq 0 ]]; then
            exec "$TEST_REAL_SHA256SUM" "$@"
        fi
        checker=("$TEST_REAL_SHA256SUM")
    else
        checker=("$TEST_REAL_SHASUM" -a 256)
    fi
    status=0
    while read -r expected file; do
        actual=$("${checker[@]}" "$file" | cut -d' ' -f1) || {
            status=1
            continue
        }
        [[ "$actual" == "$expected" ]] || status=1
    done
    exit "$status"
fi
if [[ -n "${TEST_REAL_SHA256SUM:-}" ]]; then
    exec "$TEST_REAL_SHA256SUM" "$@"
fi
exec "$TEST_REAL_SHASUM" -a 256 "$@"
EOF
    chmod 755 "$BATS_TEST_TMPDIR/bin/sha256sum"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    ssh_run() {
        local command
        while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
        [[ "${1:-}" == -- ]] && shift
        command="$*"
        /bin/bash -c "$command"
    }
}

teardown() { teardown_test_env; }

_sync_fixture() {
    rm -rf "$TELEGRAM_PROXY_REMOTE_DIR/modules" "$TELEGRAM_PROXY_REMOTE_DIR/common"
    mkdir -p "$TELEGRAM_PROXY_REMOTE_DIR/modules" "$TELEGRAM_PROXY_REMOTE_DIR/common/protocols"
    cp "$SETUP_DIR/setup-essence.sh" "$TELEGRAM_PROXY_REMOTE_DIR/setup-essence.sh"
    cp "$VERSION_PATH" "$TELEGRAM_PROXY_REMOTE_DIR/VERSION"
    cp "$SETUP_DIR/modules/"*.sh "$TELEGRAM_PROXY_REMOTE_DIR/modules/"
    cp "$COMMON_DIR/"*.sh "$TELEGRAM_PROXY_REMOTE_DIR/common/"
    cp "$COMMON_DIR/protocols/"*.sh "$TELEGRAM_PROXY_REMOTE_DIR/common/protocols/"
    chmod 755 "$TELEGRAM_PROXY_REMOTE_DIR/setup-essence.sh"
}

@test "checksum manifest round-trips random script groups and detects remote drift" {
    local iterations="${FUZZ_ITERATIONS:-20}" iteration group file remote_file manifest
    for ((iteration=0; iteration<iterations; iteration++)); do
        group=$((RANDOM % 3))
        case "$group" in
            0)
                file="$SETUP_DIR/modules/other.sh"
                remote_file="modules/other.sh"
                random_ascii 32 > "$file" ;;
            1)
                file="$COMMON_DIR/common.sh"
                remote_file="common/common.sh"
                random_utf8 12
                printf '%s\r\n' "$FUZZ_UTF8_STR" > "$file" ;;
            2)
                file="$COMMON_DIR/protocols/uri.sh"
                remote_file="common/protocols/uri.sh"
                random_ascii 24 > "$file" ;;
        esac
        manifest=$(_telegram_proxy_scripts_manifest)
        _sync_fixture
        run _telegram_proxy_remote_scripts_match "$manifest"
        [ "$status" -eq 0 ]
        printf 'x' >> "$TELEGRAM_PROXY_REMOTE_DIR/$remote_file"
        run _telegram_proxy_remote_scripts_match "$manifest"
        [ "$status" -eq 10 ]
    done
}
