#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source_module 'ssh.sh'
    export SETUP_DIR="$BATS_TEST_TMPDIR/local/setup" COMMON_DIR="$BATS_TEST_TMPDIR/local/common" \
        VERSION_PATH="$BATS_TEST_TMPDIR/local/VERSION" REMOTE_DIR="$BATS_TEST_TMPDIR/remote root 'quoted'"
    export NODE_NAME=fixture SERVER_USER=root SERVER_IP=127.0.0.1
    mkdir -p "$SETUP_DIR/modules" "$COMMON_DIR"
    printf '#!/bin/bash\n' > "$SETUP_DIR/setup-essence.sh"
    printf '#!/bin/bash\n' > "$SETUP_DIR/modules/telegram-proxy.sh"
    printf 'common\n' > "$COMMON_DIR/common.sh"
    ssh_run() {
        while [[ "$1" != -- ]]; do shift; done
        shift
        bash -c "$1"
    }
    scp_run() {
        local recursive=false target remote
        [[ "$1" == -r ]] && { recursive=true; shift; }
        target="${!#}"
        remote=$(bash -c "printf '%s' ${target#*:}") || return 1
        local sources=("${@:1:$#-1}")
        if [[ "$recursive" == true ]]; then cp -R "${sources[0]}" "$remote"; else cp "${sources[@]}" "$remote"; fi
    }
}
teardown() { teardown_test_env; }

@test "valid versions normalize, compare numerically and preserve equal/newer trees" {
    local iterations="${FUZZ_ITERATIONS:-100}" i major minor patch version normalized older newer before
    for ((i=0; i<iterations; i++)); do
        major=$(random_int 0 9999)
        minor=$(random_int 1 9999)
        patch=$(random_int 1 9999)
        version="v0${major}.0${minor}.0${patch}"
        normalized=$(_remote_scripts_normalize_version "$version")
        [ "$normalized" = "$major.$minor.$patch" ]
        [ "$(_remote_scripts_normalize_version "$normalized")" = "$normalized" ]
        older="$major.$minor.$((patch - 1))"
        newer="$major.$minor.$((patch + 1))"
        _ver_gt "$normalized" "$older"
        ! _ver_gt "$normalized" "$newer"
        printf '%s\r\n' "$version" > "$VERSION_PATH"
        mkdir -p "$REMOTE_DIR"
        printf 'old payload %s\n' "$i" > "$REMOTE_DIR/setup-essence.sh"
        chmod +x "$REMOTE_DIR/setup-essence.sh"
        printf '%s\n' "$older" > "$REMOTE_DIR/VERSION"
        ensure_remote_scripts_current >/dev/null
        [ "$(cat "$REMOTE_DIR/VERSION")" = "${version}"$'\r' ] || [ "$(_remote_scripts_normalize_version "$(cat "$REMOTE_DIR/VERSION")")" = "$normalized" ]
        before=$(cat "$REMOTE_DIR/setup-essence.sh")
        ensure_remote_scripts_current >/dev/null
        [ "$(cat "$REMOTE_DIR/setup-essence.sh")" = "$before" ]
        printf 'manual payload %s\n' "$i" > "$REMOTE_DIR/setup-essence.sh"
        printf '%s\n' "$newer" > "$REMOTE_DIR/VERSION"
        ensure_remote_scripts_current >/dev/null
        [ "$(cat "$REMOTE_DIR/setup-essence.sh")" = "manual payload $i" ]
    done
}

@test "mutated and executable-looking versions never execute or alter server" {
    local iterations="${FUZZ_ITERATIONS:-100}" i invalid marker="$BATS_TEST_TMPDIR/injection" before
    mkdir -p "$REMOTE_DIR"
    printf '#!/bin/bash\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    printf '1.2.3\n' > "$REMOTE_DIR/VERSION"
    before=$(cat "$REMOTE_DIR/setup-essence.sh")
    for ((i=0; i<iterations; i++)); do
        invalid=$(mutate_inject '1.2.3' "${DICT_SHELL_INJECTION[@]}")
        if _remote_scripts_normalize_version "$invalid" >/dev/null 2>&1; then continue; fi
        printf '%s\n' "$invalid" > "$VERSION_PATH"
        ! ensure_remote_scripts_current >/dev/null 2>&1
        [ "$(cat "$REMOTE_DIR/setup-essence.sh")" = "$before" ]
        [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.3 ]
    done
    printf '$(touch "%s")\n' "$marker" > "$VERSION_PATH"
    ! ensure_remote_scripts_current >/dev/null 2>&1
    [ ! -e "$marker" ]
}
