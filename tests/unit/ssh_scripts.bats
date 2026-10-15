#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module ssh.sh
    export NODE_NAME=fixture SERVER_USER=root SERVER_IP=127.0.0.1
    export REMOTE_DIR="$BATS_TEST_TMPDIR/server's scripts" SETUP_DIR="$BATS_TEST_TMPDIR/local/setup" \
        COMMON_DIR="$BATS_TEST_TMPDIR/local/common" VERSION_PATH="$BATS_TEST_TMPDIR/local/VERSION"
    mkdir -p "$SETUP_DIR/modules" "$COMMON_DIR"
    printf '#!/bin/bash\n' > "$SETUP_DIR/setup-essence.sh"
    printf '#!/bin/bash\n' > "$SETUP_DIR/modules/example.sh"
    printf 'common\n' > "$COMMON_DIR/common.sh"
    printf '1.2.3\n' > "$VERSION_PATH"
    export SCRIPT_UPLOAD_LOG="$BATS_TEST_TMPDIR/uploads"
    : > "$SCRIPT_UPLOAD_LOG"
    ssh_run() {
        while [[ "$1" != -- ]]; do shift; done
        shift
        bash -c "$1"
    }
    scp_run() {
        local recursive=false arg target remote
        if [[ "$1" == -r ]]; then recursive=true; shift; fi
        target="${!#}"
        remote="${target#*:}"
        remote=$(bash -c "printf '%s' $remote") || return 1
        local sources=("${@:1:$#-1}")
        printf 'copy\n' >> "$SCRIPT_UPLOAD_LOG"
        if [[ "$recursive" == true ]]; then cp -R "${sources[0]}" "$remote"; else cp "${sources[@]}" "$remote"; fi
    }
}
teardown() { teardown_test_env; }

@test "older scripts upgrade once; installed equal or newer scripts remain untouched" {
    mkdir -p "$REMOTE_DIR"
    printf '1.2.2\n' > "$REMOTE_DIR/VERSION"
    printf 'old\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    ensure_remote_scripts_current
    [[ "$(cat "$REMOTE_DIR/VERSION")" == 1.2.3 ]]
    [[ "$(cat "$REMOTE_DIR/setup-essence.sh")" == '#!/bin/bash' ]]
    local copies
    copies=$(wc -l < "$SCRIPT_UPLOAD_LOG")
    ensure_remote_scripts_current
    [[ "$(wc -l < "$SCRIPT_UPLOAD_LOG")" -eq "$copies" ]]
    printf 'manual edit\n' > "$REMOTE_DIR/setup-essence.sh"
    ensure_remote_scripts_current
    [[ "$(cat "$REMOTE_DIR/setup-essence.sh")" == 'manual edit' ]]
    [[ "$(wc -l < "$SCRIPT_UPLOAD_LOG")" -eq "$copies" ]]
    printf '1.2.4\n' > "$REMOTE_DIR/VERSION"
    ensure_remote_scripts_current
    [[ "$(cat "$REMOTE_DIR/setup-essence.sh")" == 'manual edit' ]]
    [[ "$(wc -l < "$SCRIPT_UPLOAD_LOG")" -eq "$copies" ]]
}

@test "empty server installs, unknown and broken states block automatic replacement" {
    mkdir -p "$REMOTE_DIR"
    ensure_remote_scripts_current
    [[ "$(cat "$REMOTE_DIR/VERSION")" == 1.2.3 ]]
    rm "$REMOTE_DIR/VERSION"
    run ensure_remote_scripts_current
    assert_failure
    printf 'invalid\n' > "$REMOTE_DIR/VERSION"
    run ensure_remote_scripts_current
    assert_failure
    rm "$REMOTE_DIR/setup-essence.sh"
    run ensure_remote_scripts_current
    assert_failure
}

@test "version normalization rejects expressions and compares numeric components" {
    [[ "$(_remote_scripts_normalize_version $'v001.010.000\r')" == 1.10.0 ]]
    _ver_gt "$(_remote_scripts_normalize_version 1.10.0)" "$(_remote_scripts_normalize_version 1.9.9)"
    local invalid
    for invalid in '' '1.2.3;touch /tmp/injected' '1.2.3  ' $'1.2.3\njunk' '9999999999.0.0'; do
        ! _remote_scripts_normalize_version "$invalid"
    done
    printf '$(touch "%s")\n' "$BATS_TEST_TMPDIR/escaped" > "$VERSION_PATH"
    run ensure_remote_scripts_current
    assert_failure
    [[ ! -e "$BATS_TEST_TMPDIR/escaped" && ! -e "$REMOTE_DIR" ]]
}

@test "force cancellation preserves newer scripts, acceptance replaces them" {
    mkdir -p "$REMOTE_DIR"
    printf '1.2.4\n' > "$REMOTE_DIR/VERSION"
    printf 'manual edit\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    ensure_remote_scripts_current --force <<< 'n'
    [[ "$(cat "$REMOTE_DIR/setup-essence.sh")" == 'manual edit' ]]
    ensure_remote_scripts_current --force <<< 'y'
    [[ "$(cat "$REMOTE_DIR/VERSION")" == 1.2.3 ]]
    [[ "$(cat "$REMOTE_DIR/setup-essence.sh")" == '#!/bin/bash' ]]
}

@test "transport and publication errors never publish a new version" {
    mkdir -p "$REMOTE_DIR"
    printf '1.2.2\n' > "$REMOTE_DIR/VERSION"
    printf 'old\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    ssh_run() {
        while [[ "$1" != -- ]]; do shift; done
        shift
        [[ "$1" == *'mv -f '* ]] && return 1
        bash -c "$1"
    }
    run ensure_remote_scripts_current
    assert_failure
    [[ "$(cat "$REMOTE_DIR/VERSION")" == 1.2.2 ]]
    [[ ! -e "$REMOTE_DIR/.VERSION" ]]
}

@test "SSH failure is not interpreted as a missing installation" {
    ssh_run() { return 255; }
    run ensure_remote_scripts_current
    assert_failure
    [[ ! -e "$REMOTE_DIR" ]]
}

@test "broken tree retains its readable version and force replaces unknown scripts" {
    mkdir -p "$REMOTE_DIR"
    printf '1.2.4\n' > "$REMOTE_DIR/VERSION"
    _remote_scripts_probe
    [ "$REMOTE_SCRIPTS_STATE" = broken ]
    [ "$REMOTE_SCRIPTS_VERSION" = 1.2.4 ]
    run ensure_remote_scripts_current
    assert_failure
    run ensure_remote_scripts_current --force <<< 'n'
    assert_success
    [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.4 ]
    ensure_remote_scripts_current --force <<< 'y'
    [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.3 ]
    printf 'bad version\n' > "$REMOTE_DIR/VERSION"
    run ensure_remote_scripts_current
    assert_failure
    ensure_remote_scripts_current --force <<< 'y'
    [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.3 ]
}

@test "force EOF and invalid options cannot mutate remote tree" {
    mkdir -p "$REMOTE_DIR"
    printf '1.2.4\n' > "$REMOTE_DIR/VERSION"
    printf 'manual\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    ensure_remote_scripts_current --force < /dev/null
    [ "$(cat "$REMOTE_DIR/setup-essence.sh")" = manual ]
    run ensure_remote_scripts_current --unexpected
    [ "$status" -eq 2 ]
    [ ! -s "$SCRIPT_UPLOAD_LOG" ]
}

@test "invalid remote version is never executed or exposed in diagnostics" {
    mkdir -p "$REMOTE_DIR"
    printf '$(touch \"%s\")\n' "$BATS_TEST_TMPDIR/remote-injected" > "$REMOTE_DIR/VERSION"
    printf '#!/bin/bash\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    run ensure_remote_scripts_current
    assert_failure
    [[ "$output" != *'touch'* ]]
    [ ! -e "$BATS_TEST_TMPDIR/remote-injected" ]
}

@test "failed copy or chmod preserves VERSION; failed postcheck stops action" {
    mkdir -p "$REMOTE_DIR"
    printf '1.2.2\n' > "$REMOTE_DIR/VERSION"
    printf 'old\n' > "$REMOTE_DIR/setup-essence.sh"
    chmod +x "$REMOTE_DIR/setup-essence.sh"
    scp_run() { return 1; }
    run ensure_remote_scripts_current
    assert_failure
    [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.2 ]
    scp_run() {
        local target="${!#}" path
        path=$(bash -c "printf '%s' ${target#*:}") || return 1
        [[ "$1" == -r ]] && { cp -R "$2" "$path"; return; }
        cp "${@:1:$#-1}" "$path"
    }
    ssh_run() {
        while [[ "$1" != -- ]]; do shift; done
        shift
        [[ "$1" == chmod* ]] && return 1
        bash -c "$1"
    }
    run ensure_remote_scripts_current
    assert_failure
    [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.2 ]
    ssh_run() {
        while [[ "$1" != -- ]]; do shift; done
        shift
        if [[ "$1" == *'entries='* && -e "$REMOTE_DIR/common/common.sh" ]]; then
            printf 'PRESENT\n1.2.2\n'
        else
            bash -c "$1"
        fi
    }
    run ensure_remote_scripts_current

    assert_failure
    [[ "$output" == *'не подтверждена'* ]]
}
@test "remote path with shell punctuation remains literal" {
    REMOTE_DIR="$BATS_TEST_TMPDIR/remote \$(touch '$BATS_TEST_TMPDIR/path-injection')"
    ensure_remote_scripts_current
    [ "$(cat "$REMOTE_DIR/VERSION")" = 1.2.3 ]
    [ ! -e "$BATS_TEST_TMPDIR/path-injection" ]
}
