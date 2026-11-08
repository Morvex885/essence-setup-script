#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env

    export APP="$BATS_TEST_TMPDIR/app"
    export HOME="$BATS_TEST_TMPDIR/home"
    export BIN="$BATS_TEST_TMPDIR/bin"
    export REMOTE="$BATS_TEST_TMPDIR/remote.git"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GH_ACTIVE_LOGIN_FILE="$BATS_TEST_TMPDIR/gh-active-login"
    mkdir -p "$APP/modules" "$APP/templates" "$APP/common/protocols" "$BIN" "$HOME"
    printf '%s\n' test-owner > "$GH_ACTIVE_LOGIN_FILE"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$APP/"
    cp "$PROJECT_ROOT/VERSION" "$APP/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$APP/modules/"
    cp "$PROJECT_ROOT/remote-control/templates/"*.yaml "$APP/templates/"
    cp -R "$PROJECT_ROOT/common/." "$APP/common/"
    chmod +x "$APP/remote-control-essence.sh"

    cat > "$BIN/curl" <<'EOF'
#!/bin/bash
exit 1
EOF
    cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
exit 2
EOF
    cat > "$BIN/scp" <<'EOF'
#!/bin/bash
exit 2
EOF
    chmod +x "$BIN/ssh" "$BIN/scp"
    export TEST_REAL_OPENSSL
    TEST_REAL_OPENSSL=$(command -v openssl) || return 1
    cat > "$BIN/openssl" <<'EOF'
#!/bin/bash
if [[ "$1" == passwd && "$2" == -6 ]]; then
    shift 2
    salt=test
    password=
    while (( $# > 0 )); do
        if [[ "$1" == -salt ]]; then
            salt="$2"
            shift 2
        elif [[ "$1" == -stdin ]]; then
            IFS= read -r password
            shift
        else
            password="$1"
            shift
        fi
    done
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)
    else
        digest=$(printf '%s' "$password" | shasum -a 256 | cut -d' ' -f1)
    fi
    printf '$6$%s$%s\n' "$salt" "$digest"
    exit 0
fi
exec "$TEST_REAL_OPENSSL" "$@"
EOF
    cat > "$BIN/gh" <<'EOF'
#!/bin/bash
# The system gh account and each GH_CONFIG_DIR profile are independent.
profile="${GH_CONFIG_DIR:-}"
if [[ -n "${GH_CALLS_FILE:-}" ]]; then
    printf '%s\n' "$*" >> "$GH_CALLS_FILE"
fi
if [[ -n "${GH_SCOPE_CALLS_FILE:-}" ]]; then
    printf '%s %s\n' "${profile##*/}" "$*" >> "$GH_SCOPE_CALLS_FILE"
fi
if [[ "$1" == auth && "$2" == switch || "$1" == auth && "$2" == setup-git ]]; then
    printf '%s\n' 'global GitHub account mutation forbidden' >&2
    exit 90
fi
if [[ "$1" == auth && "$2" == status ]]; then
    [[ "${GH_MODE:-success}" != auth-fail ]] || exit 1
    exit 0
fi
if [[ "$1" == auth && "$2" == token ]]; then
    login=""
    while (( $# > 0 )); do
        if [[ "$1" == --user ]]; then login="${2:-}"; break; fi
        shift
    done
    [[ -n "$login" && "$login" =~ ^[A-Za-z0-9-]+$ &&
       "${GH_TOKEN_UNAVAILABLE_LOGIN:-}" != "$login" ]] || exit 1
    printf 'ghp_FixtureToken_%s\n' "$login"
    exit 0
fi
if [[ "$1" == auth && "$2" == login ]]; then
    [[ -n "$profile" ]] || exit 1
    if [[ "$*" == *--with-token* ]]; then
        IFS= read -r token || exit 1
        [[ "$token" =~ ^ghp_FixtureToken_([A-Za-z0-9-]+)$ ]] || exit 1
        login="${BASH_REMATCH[1]}"
    elif [[ "$*" == *--web* ]]; then
        if [[ "${GH_MODE:-success}" == web-fail ]]; then
            printf '%s\n' 'browser authorization failed: token=ghp_WebSecret123' >&2
            exit 1
        fi
        login="${GH_WEB_LOGIN:-$(cat "$GH_ACTIVE_LOGIN_FILE")}"
        token="ghp_FixtureToken_$login"
    else
        exit 1
    fi
    mkdir -p "$profile" || exit 1
    printf 'user: %s\noauth_token: %s\n' "$login" "$token" > "$profile/hosts.yml"
    exit 0
fi
if [[ "$1" == auth && "$2" == git-credential ]]; then
    [[ "$3" == get && -f "$profile/hosts.yml" ]] || exit 1
    login=$(sed -n 's/^user: //p' "$profile/hosts.yml")
    token=$(sed -n 's/^oauth_token: //p' "$profile/hosts.yml")
    printf 'username=%s\npassword=%s\n' "$login" "$token"
    exit 0
fi
if [[ "$1" == api && "$2" == user ]]; then
    if [[ "${GH_MODE:-success}" == api-timeout ]]; then
        printf '%s\n' 'connection timed out' >&2
        exit 28
    fi
    [[ "${GH_MODE:-success}" != empty-login ]] || exit 0
    if [[ "${GH_MODE:-success}" == auth-fail ]]; then
        printf '%s\n' 'HTTP 401: Bad credentials' >&2
        exit 1
    fi
    if [[ -n "$profile" ]]; then
        [[ -f "$profile/hosts.yml" ]] || { printf 'not logged in to github.com\n' >&2; exit 1; }
        login=$(sed -n 's/^user: //p' "$profile/hosts.yml")
        [[ "${GH_MODE:-success}" != wrong-account ]] || login=alternate-owner
        printf '%s\n' "$login"
    else
        cat "$GH_ACTIVE_LOGIN_FILE"
    fi
    exit 0
fi
if [[ "$1" == repo && "$2" == view ]]; then
    if [[ "${GH_MODE:-success}" == fail ]]; then
        printf '%s\n' 'permission denied' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == secret-fail ]]; then
        printf '%s\n' 'permission denied: https://user:password@github.com token=ghp_SecretValue123456789 github_pat_SecretValue123456789' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == missing ]]; then
        printf '%s\n' 'repository not found' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == retry ]]; then
        count=0
        [[ -f "${GH_COUNT_FILE:-}" ]] && count=$(cat "$GH_COUNT_FILE")
        printf '%s\n' "$((count + 1))" > "$GH_COUNT_FILE"
        if (( count == 0 )); then
            printf '%s\n' 'permission denied' >&2
            exit 1
        fi
    fi
    if [[ "${GH_MODE:-success}" == reconnect &&
          ! -f "${GH_REPO_STATE_FILE:-}" ]]; then
        printf '%s\n' 'repository not found' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == public || "$3" == "${GH_PUBLIC_REPO:-}" ]] &&
       [[ ! -f "${GH_PRIVATE_MARKER:-}" ]]; then
        printf '%s\n' '{"visibility":"PUBLIC"}'
    else
        printf '%s\n' '{"visibility":"PRIVATE"}'
    fi
    exit 0
fi
if [[ "$1" == repo && "$2" == edit ]]; then
    [[ -z "${GH_EDIT_MARKER:-}" ]] || touch "$GH_EDIT_MARKER"
    [[ -z "${GH_PRIVATE_MARKER:-}" ]] || touch "$GH_PRIVATE_MARKER"
    exit 0
fi
if [[ "$1" == repo && "$2" == create ]]; then
    if [[ -n "${GH_CREATE_COUNT_FILE:-}" ]]; then
        count=$(cat "$GH_CREATE_COUNT_FILE")
        printf '%s\n' "$((count + 1))" > "$GH_CREATE_COUNT_FILE"
        [[ -n "${GH_REPO_STATE_FILE:-}" ]] && touch "$GH_REPO_STATE_FILE"
    fi
    printf '%s\n' '{"visibility":"PRIVATE"}'
    exit 0
fi
if [[ "$1" == repo && "$2" == delete ]]; then
    [[ -z "${GH_DELETE_MARKER:-}" ]] || touch "$GH_DELETE_MARKER"
    if [[ "${GH_DELETE_FAIL:-false}" == true ]]; then
        printf '%s\n' 'delete failed: token=ghp_DeleteSecret123' >&2
        exit 1
    fi
    exit 0
fi
if [[ "$1" == browse && "$2" == --settings && "$3" == --repo ]]; then
    [[ -z "${GH_BROWSE_MARKER:-}" ]] || touch "$GH_BROWSE_MARKER"
    if [[ "${GH_BROWSE_FAIL:-false}" == true ]]; then
        exit 1
    fi
    exit 0
fi
exit 1
EOF
    chmod +x "$BIN/curl" "$BIN/gh" "$BIN/openssl"
    export PATH="$BIN:$PATH"

    git init --bare -b main "$REMOTE" >/dev/null
    local seed="$BATS_TEST_TMPDIR/seed"
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    git -C "$seed" commit --allow-empty -m seed >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null
    git config --global url."file://$REMOTE".insteadOf \
        "https://github.com/test-owner/essence-remote-control-config.git"
}

teardown() {
    PATH="${PATH#"$BIN:"}"
    export PATH
    hash -r
    teardown_test_env
}
_hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

_file_mode() {
    case "${OSTYPE:-}" in
        darwin*) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

# _rc ARGV… — разовая команда entrypoint без stdin (status/output).
_rc() {
    run "$APP/remote-control-essence.sh" "$@" < /dev/null
}

# _rc_secrets JSON ARGV… — разовая команда с секретами через --secrets-stdin.
_rc_secrets() {
    local json="$1"
    shift
    run bash -c 'printf "%s" "$1" | "$0" "${@:2}" --secrets-stdin' \
        "$APP/remote-control-essence.sh" "$json" "$@"
}

# _connect_github ARGV… — source github-connect аккаунтом test-owner с согласием
# на план (--yes): план подключения проверяется в cmd_system.bats.
_connect_github() {
    _rc source github-connect --login test-owner --yes "$@"
}

# _serve_requests ARGV_JSON… — один процесс serve, запросы с id 1, 2, …
_serve_requests() {
    bats_require_minimum_version 1.5.0
    local argv id=0 lines=""
    for argv in "$@"; do
        id=$((id + 1))
        lines+="$(jq -cn --argjson a "$argv" --argjson id "$id" '{id:$id, argv:$a}')"$'\n'
    done
    run --separate-stderr bash -c 'printf "%s" "$1" | "$0" serve' \
        "$APP/remote-control-essence.sh" "$lines"
}

_runtime_fingerprint() {
    local root="$1" path rel mode hash
    [[ -d "$root" ]] || return 1
    printf 'd %s .\n' "$(_file_mode "$root")" || return 1
    while IFS= read -r path; do
        rel="${path#"$root"/}"
        if [[ -L "$path" ]]; then
            printf 'l %s %s\n' "$(readlink "$path")" "$rel" || return 1
        else
            mode=$(_file_mode "$path") || return 1
            if [[ -d "$path" ]]; then
                printf 'd %s %s\n' "$mode" "$rel" || return 1
            elif [[ -f "$path" ]]; then
                hash=$(_hash_file "$path") || return 1
                printf 'f %s %s %s\n' "$mode" "$hash" "$rel" || return 1
            else
                printf 'x %s %s\n' "$mode" "$rel" || return 1
            fi
        fi
    done < <(find "$root" -mindepth 1 -print | LC_ALL=C sort)
}


@test "runtime fingerprint records symlinks without dereferencing them" {
    local root="$BATS_TEST_TMPDIR/fingerprint-root"
    mkdir -p "$root" || return 1
    printf 'fingerprint-target\n' > "$root/target" || return 1
    ln -s target "$root/link" || return 1

    run _runtime_fingerprint "$root"
    assert_success
    assert_output --partial $'l target link'
    ! printf '%s\n' "$output" | grep -Eq '^f [0-9]+ [0-9a-f]+ link$'
}
_materialization_temp_inventory() {
    local config_dir="$1"
    find "$config_dir" -mindepth 1 -maxdepth 1 \
        \( -name '.github-runtime.*' -o -name 'github-runtime.tmp.*' \
           -o -name '.auth.*' -o -name '.runtime-vault.*' \
           -o -name 'runtime-vault.json.tmp.*' -o -name '.materialize.*' \) \
        -print | LC_ALL=C sort
}

_assert_runtime_secure_modes() {
    local runtime="$1" id="$2" path mode
    while IFS= read -r path; do
        mode=$(_file_mode "$path") || return 1
        if [[ "$mode" != 700 ]]; then
            printf '# insecure directory mode: %s %s\n' "$mode" "$path" >&3
            return 1
        fi
    done < <(find "$runtime" -type d -print)
    mode=$(_file_mode "$runtime/secrets.json") || return 1
    if [[ "$mode" != 600 ]]; then
        printf '# insecure secrets mode: %s\n' "$mode" >&3
        return 1
    fi
    mode=$(_file_mode "$runtime/ssh/identities/$id") || return 1
    if [[ "$mode" != 600 ]]; then
        printf '# insecure private identity mode: %s\n' "$mode" >&3
        return 1
    fi
}


_establish_materialization_source() {
    local password_hash
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    _publish_key_node_state ready || return 1
    password_hash=$(openssl passwd -6 -salt fixture secret-pass) || return 1
    _publish_remote_access_hash "$password_hash" || return 1
    RC_SCRIPT_PASSWORD=secret-pass _rc session open
    assert_success

    MATERIALIZE_CONFIG_DIR="$HOME/.config/remote-control-essence"
    MATERIALIZE_RUNTIME="$MATERIALIZE_CONFIG_DIR/github-runtime"
    MATERIALIZE_ID=0123456789abcdef0123456789abcdef
    export MATERIALIZE_CONFIG_DIR MATERIALIZE_RUNTIME MATERIALIZE_ID
    [[ -f "$MATERIALIZE_RUNTIME/ssh/identities/$MATERIALIZE_ID" ]] || return 1
    [[ -f "$MATERIALIZE_CONFIG_DIR/.auth" ]] || return 1
    _assert_runtime_secure_modes "$MATERIALIZE_RUNTIME" "$MATERIALIZE_ID" || return 1
    [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth")" == 600 ]] || return 1
}

_publish_remote_access_null() {
    local marker="$1"
    local updater="$BATS_TEST_TMPDIR/access-null-$marker"
    git clone "$REMOTE" "$updater" >/dev/null || return 1
    git -C "$updater" config user.name updater || return 1
    git -C "$updater" config user.email updater@example.invalid || return 1
    jq --arg marker "$marker" '.marker=$marker' "$updater/config.json" \
        > "$updater/config.json.tmp" || return 1
    mv "$updater/config.json.tmp" "$updater/config.json" || return 1
    jq '.access.script_password_hash=null' "$updater/manifest.json" \
        > "$updater/manifest.json.tmp" || return 1
    mv "$updater/manifest.json.tmp" "$updater/manifest.json" || return 1
    git -C "$updater" add config.json manifest.json || return 1
    git -C "$updater" commit -m "access-null-$marker" >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null || return 1
}

_publish_remote_access_hash() {
    local password_hash="$1" updater="$BATS_TEST_TMPDIR/access-hash"
    git clone "$REMOTE" "$updater" >/dev/null || return 1
    git -C "$updater" config user.name updater || return 1
    git -C "$updater" config user.email updater@example.invalid || return 1
    jq --arg password_hash "$password_hash" \
        '.access.script_password_hash=$password_hash' "$updater/manifest.json" \
        > "$updater/manifest.json.tmp" || return 1
    mv "$updater/manifest.json.tmp" "$updater/manifest.json" || return 1
    git -C "$updater" add manifest.json || return 1
    git -C "$updater" commit -m access-hash >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null || return 1
}

_install_materialization_fault_wrappers() {
    export REAL_JQ REAL_CP REAL_CHMOD REAL_MV REAL_RM
    REAL_JQ=$(command -v jq) || return 1
    REAL_CP=$(command -v cp) || return 1
    REAL_CHMOD=$(command -v chmod) || return 1
    REAL_MV=$(command -v mv) || return 1
    REAL_RM=$(command -v rm) || return 1
    cat > "$BIN/jq" <<'EOF'
#!/bin/bash
is_config_filter=false
is_runtime_input=false
for arg in "$@"; do
    [[ "$arg" == .config ]] && is_config_filter=true
    [[ "$arg" == "$MATERIALIZE_CONFIG_DIR"/*vault* ]] && is_runtime_input=true
done
if [[ "${MATERIALIZE_FAULT:-}" == jq &&
      "$is_config_filter" == true && "$is_runtime_input" == true ]]; then
    printf 'jq\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 81
fi
exec "$REAL_JQ" "$@"
EOF
    cat > "$BIN/cp" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == cp ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *github-runtime* ]]; then
            printf 'cp\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 82
        fi
    done
fi
exec "$REAL_CP" "$@"
EOF
    cat > "$BIN/chmod" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == chmod ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *github-runtime* ]]; then
            printf 'chmod\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 83
        fi
    done
fi
exec "$REAL_CHMOD" "$@"
EOF
    cat > "$BIN/mv" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == auth-rollback &&
      "${1:-}" == "$MATERIALIZE_CONFIG_DIR"/.auth.backup.* &&
      "${2:-}" == "$MATERIALIZE_CONFIG_DIR/.auth" ]]; then
    printf 'auth-restore-fail\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 89
fi
if [[ "${MATERIALIZE_FAULT:-}" == runtime-rollback &&
      "${1:-}" == "$MATERIALIZE_CONFIG_DIR"/.github-runtime.publish.* &&
      "${2:-}" == "$MATERIALIZE_RUNTIME" ]]; then
    printf 'publish-fail\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 86
fi
if [[ "${MATERIALIZE_FAULT:-}" == runtime-rollback &&
      "${1:-}" == "$MATERIALIZE_CONFIG_DIR"/.github-runtime.retired.* &&
      "${2:-}" == "$MATERIALIZE_RUNTIME" ]]; then
    printf 'runtime-restore-fail\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 87
fi
if [[ "${MATERIALIZE_FAULT:-}" == mv ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *github-runtime* ]]; then
            printf 'mv\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 84
        fi
    done
fi
exec "$REAL_MV" "$@"
EOF
    cat > "$BIN/rm" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == auth-rollback ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "$MATERIALIZE_CONFIG_DIR/.auth" ]]; then
            printf 'auth-rm\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 88
        fi
    done
fi
if [[ "${MATERIALIZE_FAULT:-}" == auth-rm ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "$MATERIALIZE_CONFIG_DIR/.auth" ]]; then
            printf 'auth-rm\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 85
        fi
    done
fi
exec "$REAL_RM" "$@"
EOF
    chmod +x "$BIN/jq" "$BIN/cp" "$BIN/chmod" "$BIN/mv" "$BIN/rm" || return 1
}

_publish_key_node_state() {
    local mode="$1"
    local updater="$BATS_TEST_TMPDIR/updater-$mode"
    local node_id=0123456789abcdef0123456789abcdef
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    mkdir -p "$updater/ssh/identities"
    jq --arg id "$node_id" --arg mode "$mode" '
        .nodes=[{
          id:$id,name:"ssh-node",ip:"127.0.0.1",port:22,user:"root",
          auth:"key",identity:(if $mode=="ready" then $id else "system" end),
          secret_id:null,tag:"TEST",aliases:{}
        }]
    ' "$updater/config.json" > "$updater/config.json.tmp" &&
        mv "$updater/config.json.tmp" "$updater/config.json"
    if [[ "$mode" == ready ]]; then
        ssh-keygen -t ed25519 -N '' -q -f "$updater/ssh/identities/$node_id"
        local key_type key_data _
        read -r key_type key_data _ < "$updater/ssh/identities/$node_id.pub"
        printf '127.0.0.1 %s %s\n' "$key_type" "$key_data" \
            > "$updater/ssh/known_hosts"
        jq '.portability={status:"ready",issues:[]}' \
            "$updater/manifest.json" > "$updater/manifest.json.tmp" &&
            mv "$updater/manifest.json.tmp" "$updater/manifest.json"
    else
        rm -f "$updater/ssh/identities/"*
        : > "$updater/ssh/known_hosts"
        jq --arg id "$node_id" \
            '.portability={status:"needs_setup",issues:[
              {node_id:$id,reason:"missing_identity"},
              {node_id:$id,reason:"missing_host_key"}
            ]}' "$updater/manifest.json" > "$updater/manifest.json.tmp" &&
            mv "$updater/manifest.json.tmp" "$updater/manifest.json"
    fi
    git -C "$updater" add config.json manifest.json ssh
    git -C "$updater" commit -m "$mode-node" >/dev/null
    git -C "$updater" push origin main >/dev/null
}

_install_fake_age() {
    cat > "$BIN/age-keygen" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-y" ]]; then
    printf '%s\n' age1testrecipient
else
    printf '%s\n' '# public key: age1testrecipient'
    printf '%s\n' 'AGE-SECRET-KEY-TEST'
fi
EOF
    cat > "$BIN/age" <<'EOF'
#!/bin/bash
out="" input="" decrypting=false identity=false batchpass=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) decrypting=true; shift ;;
        -p) exit 90 ;;
        -e) shift ;;
        -j) [[ "$2" == batchpass ]] || exit 91; batchpass=true; shift 2 ;;
        -i) identity=true; shift 2 ;;
        -r) shift 2 ;;
        -o) out="$2"; shift 2 ;;
        *) input="$1"; shift ;;
    esac
done
[[ -n "$out" && -n "$input" ]] || exit 1
if [[ "$batchpass" == true ]]; then
    [[ "${AGE_PASSPHRASE_FD:-}" == 9 && -z "${AGE_PASSPHRASE:-}" ]] || exit 92
    IFS= read -r passphrase <&9 || [[ -n "$passphrase" ]] || exit 93
fi
if [[ "$decrypting" == true && "$identity" == false ]]; then
    [[ "$passphrase" != wrong-pass ]] || exit 1
    if [[ -n "${AGE_PASSWORD_DECRYPT_MARKER:-}" ]]; then
        printf '%s\n' unlock >> "$AGE_PASSWORD_DECRYPT_MARKER"
    fi
fi
cp "$input" "$out"
EOF
    chmod +x "$BIN/age" "$BIN/age-keygen"
    # Dependency installation is a separate test double here; real-age cases
    # below exercise the actual ensure_age_batchpass and official binaries.
    cat >> "$APP/common/ensure-deps.sh" <<'EOF'

ensure_age_batchpass() {
    ensure_dep age || return 1
    AGE_BIN=$(command -v age) || return 1
    AGE_KEYGEN_BIN=$(command -v age-keygen) || return 1
}
EOF
}
_set_local_marker() {
    local config_dir="$1" marker="$2" tmp="$BATS_TEST_TMPDIR/config-marker.tmp"
    jq --arg marker "$marker" '.marker=$marker' "$config_dir/config.json" > "$tmp" &&
        mv "$tmp" "$config_dir/config.json"
}

_publish_plain_marker() {
    local marker="$1"
    local updater="$BATS_TEST_TMPDIR/plain-marker-$marker"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    jq --arg marker "$marker" '.marker=$marker' "$updater/config.json" \
        > "$updater/config.json.tmp" && mv "$updater/config.json.tmp" "$updater/config.json"
    git -C "$updater" add config.json
    git -C "$updater" commit -m "marker-$marker" >/dev/null
    git -C "$updater" push origin main >/dev/null
}

_prepare_alternate_remote() {
    ALTERNATE_REMOTE="$BATS_TEST_TMPDIR/alternate.git"
    local seed="$BATS_TEST_TMPDIR/alternate-seed"
    git init --bare -b main "$ALTERNATE_REMOTE" >/dev/null || return 1
    git init -b main "$seed" >/dev/null || return 1
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    git -C "$seed" commit --allow-empty -m seed >/dev/null || return 1
    git -C "$seed" remote add origin "$ALTERNATE_REMOTE"
    git -C "$seed" push origin main >/dev/null || return 1
    git config --global url."file://$ALTERNATE_REMOTE".insteadOf \
        "https://github.com/alternate-owner/essence-remote-control-config.git"
}

_assert_no_global_auth_mutation() {
    [[ "$(cat "$GH_ACTIVE_LOGIN_FILE")" == "${1:-test-owner}" ]] || return 1
    ! grep -Eq '^auth (switch|setup-git)( |$)' "$GH_CALLS_FILE"
}


_prepare_existing_plaintext_vault() {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    _set_local_marker "$config_dir" local
    _connect_github --storage none
    assert_success
    _rc source github-switch-local
    assert_success
}



@test "first local source selection does not probe GitHub" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"

    _rc source init-local

    assert_success
    assert_output --partial "Локальная конфигурация создана"
    [[ ! -s "$GH_CALLS_FILE" ]] || return 1
}

@test "plaintext GitHub source persists and restarts from installed layout" {
    _rc source init-local
    assert_success

    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local github_link=$'\033]8;;https://github.com/test-owner/essence-remote-control-config\033\\GitHub\033]8;;\033\\'
    assert_output --partial "Источник GitHub подключён."
    jq -e 'type == "object" and .type == "github" and .private_verified == true' \
        "$config_dir/source.json"
    [[ "$(git --git-dir="$config_dir/github-store.git" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    local rel
    for rel in storage.json config.json secrets.json manifest.json templates/default.yaml; do
        cmp <(git --git-dir="$config_dir/github-store.git" show "main:$rel") \
            <(git --git-dir="$REMOTE" show "main:$rel")
    done
    local session_worktree_found=false session_worktree
    for session_worktree in "$config_dir"/github-sessions/*/worktree; do
        [[ -d "$session_worktree" ]] && session_worktree_found=true
    done
    [[ "$session_worktree_found" == false ]] || return 1
    [[ -f "$config_dir/github-runtime/config.json" ]] || return 1

    _rc source status
    assert_success
    assert_output --partial "type: github"
    assert_output --partial "storage: none"
    assert_output --partial "sync: clean"
    [[ -f "$config_dir/github-runtime/config.json" ]] || return 1
    _rc session open
    assert_success

    _rc source github-rewrap-password
    [ "$status" -eq 1 ]
    assert_output --partial "без шифрования"
}

@test "opening encrypted GitHub menu preserves the published state" {
    _install_fake_age
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success

    local updater="$BATS_TEST_TMPDIR/age-updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    jq -n --slurpfile config "$updater/config.json" \
        --slurpfile secrets "$updater/secrets.json" \
        --slurpfile manifest "$updater/manifest.json" \
        --rawfile template "$updater/templates/default.yaml" '
        {
          vault_version:2,
          minimum_remote_control_version:"0.0.0",
          portability:$manifest[0].portability,
          access:$manifest[0].access,
          config:$config[0],
          secrets:$secrets[0],
          templates:{"default.yaml":(($manifest[0].templates["default.yaml"] // {}) + {content:$template})},
          ssh:{identities:{},known_hosts:""}
        }
    ' > "$updater/state.json.age"
    printf '%s\n' '{"storage_version":1,"encryption":"age"}' > "$updater/storage.json"
    printf '%s\n' age1testrecipient > "$updater/recipient.txt"
    printf '%s\n' AGE-SECRET-KEY-TEST > "$updater/unlock.age"
    rm -f "$updater/config.json" "$updater/secrets.json" "$updater/manifest.json"
    rm -rf "$updater/templates" "$updater/ssh"
    git -C "$updater" add -A
    git -C "$updater" commit -m encrypted-state >/dev/null
    git -C "$updater" push origin main >/dev/null

    local before
    before=$(git --git-dir="$REMOTE" rev-parse main) || return 1
    RC_VAULT_PASSWORD=access-pass _rc session open
    assert_success
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$before" ]] || return 1
    jq -e '.schema_version==1 and .node_passwords=={}' \
        "$HOME/.config/remote-control-essence/github-runtime/secrets.json" || return 1
}

@test "failed encrypted GitHub actions retain the selected source and invoke each operation" {
    _install_fake_age
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success

    local updater="$BATS_TEST_TMPDIR/empty-diagnostic-age-updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    jq -n --slurpfile config "$updater/config.json" \
        --slurpfile secrets "$updater/secrets.json" \
        --slurpfile manifest "$updater/manifest.json" \
        --rawfile template "$updater/templates/default.yaml" '
        {
          vault_version:2,
          minimum_remote_control_version:"0.0.0",
          portability:$manifest[0].portability,
          access:$manifest[0].access,
          config:$config[0],
          secrets:$secrets[0],
          templates:{"default.yaml":(($manifest[0].templates["default.yaml"] // {}) + {content:$template})},
          ssh:{identities:{},known_hosts:""}
        }
    ' > "$updater/state.json.age"
    printf '%s\n' '{"storage_version":1,"encryption":"age"}' > "$updater/storage.json"
    printf '%s\n' age1testrecipient > "$updater/recipient.txt"
    printf '%s\n' AGE-SECRET-KEY-TEST > "$updater/unlock.age"
    rm -f "$updater/config.json" "$updater/secrets.json" "$updater/manifest.json"
    rm -rf "$updater/templates" "$updater/ssh"
    git -C "$updater" add -A
    git -C "$updater" commit -m empty-diagnostic-encrypted-state >/dev/null
    git -C "$updater" push origin main >/dev/null

    export FAILED_GITHUB_ACTIONS="$BATS_TEST_TMPDIR/failed-github-actions" RC_VAULT_PASSWORD=access-pass
    cat >> "$APP/modules/github-config.sh" <<'EOF'
github_config_rewrap_master() { printf 'rewrap\n' >> "$FAILED_GITHUB_ACTIONS"; _github_clear_error; return 1; }
github_config_rotate_vault_key() { printf 'rotate\n' >> "$FAILED_GITHUB_ACTIONS"; _github_clear_error; return 1; }
github_config_import_recovery() { printf 'import\n' >> "$FAILED_GITHUB_ACTIONS"; _github_clear_error; return 1; }
github_config_switch_local() { printf 'local\n' >> "$FAILED_GITHUB_ACTIONS"; _github_clear_error; return 1; }
EOF

    _rc_secrets '{"vault-password":"old-pass","new-vault-password":"new-pass"}' source github-rewrap-password
    [ "$status" -eq 1 ] || return 1
    _rc_secrets '{"new-vault-password":"new-pass"}' source github-rotate-key --yes
    [ "$status" -eq 1 ] || return 1
    _rc source github-import-recovery-key --file /tmp/missing-recovery-key
    [ "$status" -eq 1 ] || return 1
    _rc source github-switch-local
    [ "$status" -eq 1 ] || return 1
    [[ "$(cat "$FAILED_GITHUB_ACTIONS")" == $'rewrap\nrotate\nimport\nlocal' ]] || return 1
    jq -e '.type=="github"' "$HOME/.config/remote-control-essence/source.json" || return 1
}
@test "ready GitHub state preserves node SSH resources after startup" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    _publish_key_node_state ready

    _rc session open
    assert_success
    local runtime="$HOME/.config/remote-control-essence/github-runtime"
    jq -e '.portability=={status:"ready",issues:[]}' "$runtime/manifest.json" || return 1
    [[ -s "$runtime/ssh/identities/0123456789abcdef0123456789abcdef" ]] || return 1
    ssh-keygen -F 127.0.0.1 -f "$runtime/ssh/known_hosts" >/dev/null || return 1
}

@test "deferred SSH action resolves resources and persists readiness across restart" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    _publish_key_node_state needs-setup

    local scan_key="$BATS_TEST_TMPDIR/scan-key" key_type key_data _
    ssh-keygen -t ed25519 -N '' -q -f "$scan_key"
    read -r key_type key_data _ < "$scan_key.pub"
    export SSH_SCAN_FILE="$BATS_TEST_TMPDIR/ssh-scan"
    printf '127.0.0.1 %s %s\n' "$key_type" "$key_data" > "$SSH_SCAN_FILE"
    cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' ok
EOF
    cat > "$BIN/ssh-keyscan" <<'EOF'
#!/bin/bash
cat "$SSH_SCAN_FILE"
EOF
    chmod +x "$BIN/ssh" "$BIN/ssh-keyscan"

    run bash -c '"$0" node setup-ssh --provision-keys yes --yes < /dev/null' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Отложенная SSH-настройка нод завершена"
    assert_output --partial "ready: да"
    local runtime="$HOME/.config/remote-control-essence/github-runtime"
    jq -e '.portability=={status:"ready",issues:[]}' "$runtime/manifest.json" || return 1
    [[ -s "$runtime/ssh/identities/0123456789abcdef0123456789abcdef" ]] || return 1
    ssh-keygen -F 127.0.0.1 -f "$runtime/ssh/known_hosts" >/dev/null || return 1

    _rc session open
    assert_success
    jq -e '.portability=={status:"ready",issues:[]}' "$runtime/manifest.json" || return 1
    [[ "$(git --git-dir="$REMOTE" show main:manifest.json |
        jq -r '.portability.status')" == ready ]] || return 1
}

@test "direct GitHub selection initializes local recovery and empty plaintext repository" {
    git --git-dir="$REMOTE" update-ref -d refs/heads/main

    _connect_github --storage none

    assert_success
    assert_output --partial "Источник GitHub подключён."
    [[ "$output" != *"jq: error"* ]] || return 1
    local config_dir="$HOME/.config/remote-control-essence"
    jq -e 'type == "object" and .schema_version == 2' "$config_dir/config.json"
    jq -e 'type == "object" and .schema_version == 2' \
        "$config_dir/github-runtime/config.json"
    jq -e 'type == "object" and .encryption == "none"' \
        <(git --git-dir="$REMOTE" show main:storage.json)
    jq -e 'type == "object" and .schema_version == 2' \
        <(git --git-dir="$REMOTE" show main:config.json)
}

@test "direct GitHub replacement on a new device commits default local recovery" {
    _prepare_existing_plaintext_vault
    local old_remote
    old_remote=$(git --git-dir="$REMOTE" rev-parse main)
    rm -rf "$HOME/.config/remote-control-essence"

    _connect_github --existing local

    assert_success
    assert_output --partial "Источник GitHub подключён."
    [[ "$output" != *"jq: error"* ]] || return 1
    local config_dir="$HOME/.config/remote-control-essence" new_remote
    new_remote=$(git --git-dir="$REMOTE" rev-parse main)
    [[ "$new_remote" != "$old_remote" ]] || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$old_remote" "$new_remote"
    jq -e 'type == "object" and .schema_version == 2' \
        <(git --git-dir="$REMOTE" show main:config.json)
    jq -e 'type == "object" and .schema_version == 2' \
        "$config_dir/github-runtime/config.json"
    jq -e '.type == "github" and .repo == "test-owner/essence-remote-control-config" and .private_verified == true' \
        "$config_dir/source.json"
}

@test "plaintext GitHub source initializes empty private repository" {
    git --git-dir="$REMOTE" update-ref -d refs/heads/main

    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    assert_output --partial "Источник GitHub подключён."
    git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/main
}
@test "encrypted GitHub source initializes empty private repository and restarts" {
    git --git-dir="$REMOTE" update-ref -d refs/heads/main
    _install_fake_age

    _rc source init-local
    assert_success
    _rc_secrets '{"new-vault-password":"access-pass"}' \
        source github-connect --login test-owner --storage age
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    assert_output --partial "Источник GitHub подключён."
    jq -e '.type == "github" and .private_verified == true' \
        "$config_dir/source.json"
    [[ "$(git --git-dir="$config_dir/github-store.git" show main:storage.json |
        jq -r '.encryption')" == age ]] || return 1
    local rel
    for rel in recipient.txt unlock.age state.json.age; do
        git --git-dir="$config_dir/github-store.git" cat-file -e "main:$rel"
    done
    for rel in config.json secrets.json manifest.json; do
        ! git --git-dir="$config_dir/github-store.git" cat-file -e "main:$rel" || return 1
    done
    [[ -f "$config_dir/github-runtime/config.json" ]] || return 1

    RC_VAULT_PASSWORD=access-pass _rc session open
    assert_success
    assert_output --partial "sync: clean"

    RC_VAULT_PASSWORD=access-pass _rc source status
    assert_success
    assert_output --partial "storage: age"
}

@test "script password hash persists through GitHub and protects the next process" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success

    run bash -c 'printf "%s" "{\"password\":\"secret-pass\"}" | "$0" self password-set --secrets-stdin' "$APP/remote-control-essence.sh"
    assert_success
    [[ "$(git --git-dir="$REMOTE" show main:manifest.json |
        jq -r '.access.script_password_hash | startswith("$6$")')" == true ]] || return 1

    RC_SCRIPT_PASSWORD=secret-pass _rc session open
    assert_success

    local rounds_hash config_dir="$HOME/.config/remote-control-essence"
    rounds_hash=$(openssl passwd -6 -salt 'rounds=100000$fixture' secret-pass) || return 1
    _publish_remote_access_hash "$rounds_hash" || return 1

    RC_SCRIPT_PASSWORD=secret-pass _rc session open
    assert_success
    [[ "$(cat "$config_dir/.auth")" == "$rounds_hash" ]] || return 1
}
@test "format recovery requires the script password and keeps its hash on replace" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    run bash -c 'printf "%s" "{\"password\":\"secret-pass\"}" | "$0" self password-set --secrets-stdin' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" updater="$BATS_TEST_TMPDIR/v1-auth" head
    git clone "$REMOTE" "$updater" >/dev/null 2>&1 || return 1
    git -C "$updater" config user.name fixture
    git -C "$updater" config user.email fixture@example.invalid
    jq '.vault_version=1' "$updater/manifest.json" > "$updater/manifest.next" &&
        mv "$updater/manifest.next" "$updater/manifest.json" || return 1
    git -C "$updater" commit -am vault-v1 >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null 2>&1 || return 1
    head=$(git --git-dir="$REMOTE" rev-parse main)

    _rc_secrets '{"script-password":"wrong"}' source github-replace-with-local --yes
    assert_failure
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$head" ]] || return 1

    _rc_secrets '{"script-password":"secret-pass"}' source github-replace-with-local --yes
    assert_success
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" != "$head" ]] || return 1
    [[ -s "$config_dir/.auth" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show main:manifest.json | jq -r '.access.script_password_hash')" == \
        "$(cat "$config_dir/.auth")" ]]
}
@test "format recovery asks again when the migrated snapshot carries another script password" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    _rc_secrets '{"password":"secret-pass"}' self password-set
    assert_success
    local updater="$BATS_TEST_TMPDIR/v1-rotated" rotated
    rotated=$(openssl passwd -6 -salt fixture rotated-pass) || return 1
    git clone "$REMOTE" "$updater" >/dev/null 2>&1 || return 1
    git -C "$updater" config user.name fixture
    git -C "$updater" config user.email fixture@example.invalid
    jq --arg hash "$rotated" '.vault_version=1 | .access.script_password_hash=$hash' \
        "$updater/manifest.json" > "$updater/manifest.next" &&
        mv "$updater/manifest.next" "$updater/manifest.json" || return 1
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$updater/secrets.json"
    git -C "$updater" commit -am vault-v1 >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null 2>&1 || return 1

    _rc_secrets '{"script-password":"secret-pass"}' source github-migrate-format --yes
    assert_success
    RC_SCRIPT_PASSWORD=secret-pass _rc status
    assert_failure
    assert_output --partial "Неверный пароль запуска."
    RC_SCRIPT_PASSWORD=rotated-pass _rc session open
    assert_success
}

@test "existing plaintext vault can load remote without changing local files" {
    _prepare_existing_plaintext_vault
    _publish_plain_marker remote
    local config_dir="$HOME/.config/remote-control-essence"
    local remote_head
    remote_head=$(git --git-dir="$REMOTE" rev-parse main)

    _connect_github --existing remote
    assert_success
    [[ "$(jq -r '.marker' "$config_dir/github-runtime/config.json")" == remote ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/config.json")" == local ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_head" ]] || return 1
    jq -e '.type == "github" and .repo == "test-owner/essence-remote-control-config"' \
        "$config_dir/source.json"
}

@test "existing plaintext vault can replace remote with local history" {
    _prepare_existing_plaintext_vault
    _publish_plain_marker remote
    local config_dir="$HOME/.config/remote-control-essence"
    _set_local_marker "$config_dir" local-new
    local old_remote new_remote
    old_remote=$(git --git-dir="$REMOTE" rev-parse main)

    _connect_github --existing local
    assert_success
    new_remote=$(git --git-dir="$REMOTE" rev-parse main)
    [[ "$new_remote" != "$old_remote" ]] || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$old_remote" "$new_remote"
    [[ "$(git --git-dir="$REMOTE" show "$old_remote:config.json" | jq -r '.marker')" == remote ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show "$new_remote:config.json" | jq -r '.marker')" == local-new ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/github-runtime/config.json")" == local-new ]] || return 1
}

@test "canceling existing plaintext vault keeps both versions untouched" {
    _prepare_existing_plaintext_vault
    _publish_plain_marker remote
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum remote_head
    checksum=$(_hash_file "$config_dir/config.json")
    remote_head=$(git --git-dir="$REMOTE" rev-parse main)

    _connect_github
    [ "$status" -eq 2 ]
    assert_output --partial "--existing remote|local"
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_head" ]] || return 1
}

@test "existing age vault inherits storage mode and unlocks only once" {
    _install_fake_age
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    _set_local_marker "$config_dir" local

    local updater="$BATS_TEST_TMPDIR/age-existing"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    mkdir -p "$updater/templates" "$updater/ssh"
    jq -n --slurpfile config "$config_dir/config.json" \
        --slurpfile secrets "$config_dir/secrets.json" \
        --rawfile template "$APP/templates/default.yaml" '
        {
          vault_version:2,
          minimum_remote_control_version:"0.0.0",
          portability:{status:"ready",issues:[]},
          access:{script_password_hash:null},
          config:($config[0] + {marker:"remote"}),
          secrets:($secrets[0] + {schema_version:2}),
          templates:{"default.yaml":{content:$template}},
          ssh:{identities:{},known_hosts:""}
        }
    ' > "$updater/state.json.age"
    printf '%s\n' '{"storage_version":1,"encryption":"age"}' > "$updater/storage.json"
    printf '%s\n' age1testrecipient > "$updater/recipient.txt"
    printf '%s\n' AGE-SECRET-KEY-TEST > "$updater/unlock.age"
    git -C "$updater" add -A
    git -C "$updater" commit -m encrypted-state >/dev/null
    git -C "$updater" push origin main >/dev/null
    mv "$BIN/age" "$BIN/age.package"
    mv "$BIN/age-keygen" "$BIN/age-keygen.package"
    cat > "$BIN/brew" <<'EOF'
#!/bin/bash
[[ "$1" == install && "$2" == age ]] || exit 1
cp "$BIN/age.package" "$BIN/age"
cp "$BIN/age-keygen.package" "$BIN/age-keygen"
chmod +x "$BIN/age" "$BIN/age-keygen"
: > "$AGE_INSTALL_MARKER"
EOF
    chmod +x "$BIN/brew"
    export PM=brew AGE_INSTALL_MARKER="$BATS_TEST_TMPDIR/age-install-marker"
    export AGE_PASSWORD_DECRYPT_MARKER="$BATS_TEST_TMPDIR/age-password-decrypts"
    : > "$AGE_PASSWORD_DECRYPT_MARKER"
    local original_path="$PATH"
    local isolated_bin="$BATS_TEST_TMPDIR/no-age-bin" path_dir candidate name
    mkdir -p "$isolated_bin"
    while IFS= read -r path_dir; do
        [[ -d "$path_dir" ]] || continue
        for candidate in "$path_dir"/*; do
            [[ -f "$candidate" && -x "$candidate" ]] || continue
            name=${candidate##*/}
            case "$name" in age|age-keygen) continue ;; esac
            [[ -e "$isolated_bin/$name" ]] ||
                ln -s "$candidate" "$isolated_bin/$name"
        done
    done < <(tr ':' '\n' <<< "$PATH")
    export PATH="$BIN:$isolated_bin"
    ! command -v age >/dev/null 2>&1 || return 1



    _rc_secrets '{"vault-password":"access-pass"}' \
        source github-connect --login test-owner --existing remote
    export PATH="$original_path"
    assert_success
    [[ -f "$AGE_INSTALL_MARKER" ]] || return 1
    local password_decrypts
    password_decrypts=$(wc -l < "$AGE_PASSWORD_DECRYPT_MARKER" | tr -d ' ')
    [[ "$password_decrypts" == 1 ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/github-runtime/config.json")" == remote ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/config.json")" == local ]] || return 1
}
@test "tracked GitHub data without storage metadata is rejected before writing" {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum remote_head orphan="$BATS_TEST_TMPDIR/orphan"
    checksum=$(_hash_file "$config_dir/config.json")
    git init -b main "$orphan" >/dev/null
    git -C "$orphan" config user.name orphan
    git -C "$orphan" config user.email orphan@example.invalid
    printf 'not an Essence vault\n' > "$orphan/README.txt"
    git -C "$orphan" add README.txt
    git -C "$orphan" commit -m orphan >/dev/null
    git -C "$orphan" remote add origin "$REMOTE"
    git -C "$orphan" push --force origin main >/dev/null
    remote_head=$(git --git-dir="$REMOTE" rev-parse main)

    _connect_github --storage none
    [ "$status" -eq 1 ]
    assert_output --partial "проверка существующего репозитория GitHub"
    assert_output --partial "В репозитории есть данные, но отсутствует корректная конфигурация Essence."
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_head" ]] || return 1
}



@test "failed GitHub enable preserves local source and config" {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")

    GH_MODE=fail _connect_github --storage none
    [ "$status" -eq 1 ]
    assert_output --partial "Не удалось подключить GitHub (этап: проверка приватного репозитория): permission denied"
    [[ "$output" != *"gh auth login"* ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
}

@test "failed first attempt can retry GitHub enable in one process" {
    _rc source init-local
    assert_success
    export GH_MODE=retry GH_COUNT_FILE="$BATS_TEST_TMPDIR/gh-count"
    printf '0\n' > "$GH_COUNT_FILE"

    _serve_requests '["session","open"]' \
        '["source","github-connect","--login","test-owner","--storage","none","--yes"]' \
        '["source","github-connect","--login","test-owner","--storage","none","--yes"]'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 2 and .ok == false)' >/dev/null || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok)' >/dev/null || return 1
    assert_output --partial "Не удалось подключить GitHub (этап: проверка приватного репозитория): permission denied"
    [[ "$output" != *"gh auth login"* ]] || return 1
    assert_output --partial "Источник GitHub подключён."
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    [[ "$(cat "$GH_COUNT_FILE")" == 2 ]] || return 1
}

@test "explicit GitHub login with unavailable token and failed web auth never reaches repository" {
    _rc source init-local
    assert_success
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SCOPE_CALLS_FILE="$BATS_TEST_TMPDIR/gh-scopes"

    GH_TOKEN_UNAVAILABLE_LOGIN=alternate-owner GH_MODE=web-fail \
        _rc source github-connect --login alternate-owner --storage none
    [ "$status" -eq 2 ]
    assert_output --partial "source github-login --login alternate-owner"
    GH_TOKEN_UNAVAILABLE_LOGIN=alternate-owner GH_MODE=web-fail \
        _rc source github-login --login alternate-owner
    [ "$status" -eq 2 ]
    assert_output --partial "Не удалось войти в GitHub как alternate-owner."
    [[ "$output" != *"ghp_WebSecret123"* ]] || return 1
    [[ "$output" != *"ghp_FixtureToken_"* ]] || return 1
    [[ ! -e "$HOME/.config/remote-control-essence/source.json" ]] || return 1
    grep -q '^auth token --hostname github.com --user alternate-owner$' "$GH_CALLS_FILE"
    grep -q '^alternate-owner auth login --hostname github.com --git-protocol https --web$' "$GH_SCOPE_CALLS_FILE"
    ! grep -q '^repo ' "$GH_CALLS_FILE" || return 1
    ! grep -q 'ghp_' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation
}
@test "GitHub connection error redacts credentials and tokens" {
    _rc source init-local
    assert_success


    GH_MODE=secret-fail _connect_github --storage none
    [ "$status" -eq 1 ]
    assert_output --partial "Не удалось подключить GitHub (этап: проверка приватного репозитория):"
    [[ "$output" != *"password@github.com"* ]] || return 1
    [[ "$output" != *"ghp_SecretValue123456789"* ]] || return 1
    [[ "$output" != *"github_pat_SecretValue123456789"* ]] || return 1
    [[ "$output" != *"gh auth login"* ]] || return 1
}

@test "saved GitHub source reopens cached config during account API timeout" {
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local source_hash global_login
    source_hash=$(_hash_file "$config_dir/source.json")
    global_login=$(cat "$GH_ACTIVE_LOGIN_FILE")
    git --git-dir="$config_dir/github-store.git" show main:config.json > "$BATS_TEST_TMPDIR/cached-config.json"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-offline-calls"
    : > "$GH_CALLS_FILE"

    GH_MODE=api-timeout _rc session open
    assert_success
    cmp "$BATS_TEST_TMPDIR/cached-config.json" "$config_dir/github-runtime/config.json" || return 1
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(cat "$GH_ACTIVE_LOGIN_FILE")" == "$global_login" ]] || return 1
    grep -q '^api user ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^repo view ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^auth token ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^auth login ' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation
}
@test "saved profile API failure blocks repository access without changing global login" {
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local source_hash=$(_hash_file "$config_dir/source.json")
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    : > "$GH_CALLS_FILE"

    GH_MODE=auth-fail _rc session open
    assert_failure
    assert_output --partial "GH_CONFIG_DIR=$config_dir/credentials/gh/test-owner gh auth login --hostname github.com --web"
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    ! grep -q '^repo ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^auth login ' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation
}

@test "saved profile mismatch never falls back to global account or reimports credentials" {
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" profile="$HOME/.config/remote-control-essence/credentials/gh/test-owner"
    local source_hash=$(_hash_file "$config_dir/source.json")
    printf 'user: alternate-owner\noauth_token: ghp_FixtureToken_alternate-owner\n' > "$profile/hosts.yml"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    : > "$GH_CALLS_FILE"

    _rc session open
    assert_failure
    assert_output --partial "Профиль test-owner авторизован как alternate-owner."
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(sed -n 's/^user: //p' "$profile/hosts.yml")" == alternate-owner ]] || return 1
    ! grep -q '^auth token ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^auth login ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^repo ' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation
}

@test "switching to local source can reconnect GitHub in the same process" {
    export GH_MODE=reconnect
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    export GH_REPO_STATE_FILE="$BATS_TEST_TMPDIR/gh-repo-created"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"
    _rc source init-local
    assert_success
    _connect_github --create-repo --storage none
    assert_success

    _serve_requests '["session","open"]' '["source","github-switch-local"]' \
        '["source","github-connect","--login","test-owner","--existing","local","--yes"]'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok)' >/dev/null || return 1
    assert_output --partial "Источник GitHub подключён."
    jq -e 'type == "object" and .type == "github" and .private_verified == true' \
        "$HOME/.config/remote-control-essence/source.json"
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 1 ]] || return 1
}

@test "legacy exact local source marker migrates on the next process" {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")
    printf '%s\n' '{"type":"local"}' > "$config_dir/source.json"
    chmod 600 "$config_dir/source.json"

    _rc session open
    assert_success
    assert_output --partial "source: local"
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
}

@test "switching from GitHub to local persists without source metadata" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"

    _rc source github-switch-local
    assert_success
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")
    [[ ! -e "$config_dir/source.json" ]] || return 1

    _rc session open
    assert_success
    assert_output --partial "source: local"
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
}
@test "first connection explicitly selects B and imports only B's token" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SCOPE_CALLS_FILE="$BATS_TEST_TMPDIR/gh-scopes"
    _rc source init-local
    assert_success
    _rc source github-connect --login alternate-owner --storage none --yes
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    jq -e '.repo == "alternate-owner/essence-remote-control-config" and (keys | sort == ["branch","private_verified","repo","type"])' \
        "$config_dir/source.json"
    grep -q '^auth token --hostname github.com --user alternate-owner$' "$GH_CALLS_FILE"
    grep -q '^alternate-owner auth login --hostname github.com --git-protocol https --with-token$' "$GH_SCOPE_CALLS_FILE"
    grep -q '^alternate-owner repo view alternate-owner/essence-remote-control-config ' "$GH_SCOPE_CALLS_FILE"
    ! grep -q '^repo view test-owner/' "$GH_CALLS_FILE" || return 1
    [[ "$(git --git-dir="$config_dir/github-store.git" config --get remote.origin.url)" == \
        "https://github.com/alternate-owner/essence-remote-control-config.git" ]] || return 1
    [[ "$(_file_mode "$config_dir/credentials/gh/alternate-owner/hosts.yml")" == 600 ]] || return 1
    [[ "$output" != *"ghp_FixtureToken_"* ]] || return 1
    ! grep -q 'ghp_FixtureToken_' "$GH_CALLS_FILE" || return 1
    ! grep -q 'ghp_FixtureToken_' "$config_dir/source.json" || return 1
    _assert_no_global_auth_mutation
}

@test "missing repository defaults to refusal without creating or changing local state" {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"
    _connect_github --storage none
    [ "$status" -eq 2 ]
    assert_output --partial "Репозиторий test-owner/essence-remote-control-config не найден"
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "confirmed missing repository creates exactly one private repository" {
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    _rc source init-local
    assert_success
    _connect_github --create-repo --storage none
    assert_success

    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 1 ]] || return 1
    [[ "$(grep -c '^repo create test-owner/essence-remote-control-config --private --description Essence Remote Control configuration$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    jq -e '.type == "github" and .private_verified == true' \
        "$HOME/.config/remote-control-essence/source.json"
}

@test "startup does not recreate a repository missing from saved GitHub source" {
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    _rc source init-local
    assert_success
    _connect_github --create-repo --storage none
    assert_success
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    _rc session open
    assert_failure
    assert_output --partial "Не удалось открыть источник GitHub (этап: проверка приватного репозитория): Репозиторий test-owner/essence-remote-control-config не найден."
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
}

@test "GitHub delete defaults to refusal and keeps source metadata" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_MARKER="$BATS_TEST_TMPDIR/gh-delete"

    _rc source github-delete-repo
    [ "$status" -eq 2 ]
    [[ -f "$config_dir/source.json" ]] || return 1
    [[ ! -e "$GH_DELETE_MARKER" ]] || return 1
    [[ "$(grep -c '^repo delete ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "successful GitHub delete preserves local files and disables source" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_MARKER="$BATS_TEST_TMPDIR/gh-delete"

    _rc source github-delete-repo --yes
    assert_success
    assert_output --partial "Репозиторий test-owner/essence-remote-control-config удалён."
    [[ -f "$GH_DELETE_MARKER" ]] || return 1
    [[ "$(grep -c '^repo delete test-owner/essence-remote-control-config --yes$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
    jq -e 'type == "object" and .schema_version == 2' "$config_dir/config.json"
    jq -e 'type == "object" and .schema_version == 1' "$config_dir/secrets.json"
    jq -e 'type == "object" and .schema_version == 2' "$config_dir/manifest.json"
}

@test "failed GitHub delete reports the settings link and keeps local source" {
    bats_require_minimum_version 1.5.0
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_MARKER="$BATS_TEST_TMPDIR/gh-delete"
    export GH_BROWSE_MARKER="$BATS_TEST_TMPDIR/gh-browse"
    export GH_DELETE_FAIL=true

    run --separate-stderr "$APP/remote-control-essence.sh" source github-delete-repo --yes --json < /dev/null
    [ "$status" -eq 1 ]
    jq -e '.error.code == "remote_failed" and
        .error.settings_url == "https://github.com/test-owner/essence-remote-control-config/settings"' <<< "$output"
    [[ -f "$config_dir/config.json" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ -f "$GH_DELETE_MARKER" && ! -e "$GH_BROWSE_MARKER" ]] || return 1
    [[ "$(grep -c '^repo delete test-owner/essence-remote-control-config --yes$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    [[ "$(grep -c '^browse ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$output$stderr" != *"ghp_DeleteSecret123"* ]] || return 1
}

@test "failed GitHub delete prints the repository settings link" {
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_FAIL=true GH_BROWSE_FAIL=true

    _rc source github-delete-repo --yes
    [ "$status" -eq 1 ]
    assert_output --partial "https://github.com/test-owner/essence-remote-control-config/settings"
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$output" != *"ghp_DeleteSecret123"* ]] || return 1
}

@test "GitHub runtime materialization command failures preserve runtime and auth and retry cleanly" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    local fault marker expected old_runtime new_runtime old_auth_hash old_auth_mode
    local old_temps new_temps failures=0

    for fault in jq cp chmod mv; do
        expected="materialize-$fault"
        _publish_plain_marker "$expected" || return 1
        old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
        old_auth_hash=$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
        old_auth_mode=$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
        old_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1
        marker="$BATS_TEST_TMPDIR/materialize-$fault.calls"
        rm -f "$marker" || return 1

        MATERIALIZE_FAULT="$fault" MATERIALIZE_FAULT_MARKER="$marker" RC_SCRIPT_PASSWORD=secret-pass \
            _rc session open
        [[ "$status" -ne 0 ]] || failures=$((failures + 1))
        [[ -s "$marker" ]] || failures=$((failures + 1))
        new_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") ||
            new_runtime="runtime-unavailable"
        [[ "$new_runtime" == "$old_runtime" ]] || failures=$((failures + 1))
        [[ "$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_hash" ]] ||
            failures=$((failures + 1))
        [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_mode" ]] ||
            failures=$((failures + 1))
        new_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1
        [[ "$new_temps" == "$old_temps" ]] || failures=$((failures + 1))

        MATERIALIZE_FAULT=none MATERIALIZE_FAULT_MARKER="$marker" RC_SCRIPT_PASSWORD=secret-pass \
            _rc session open
        [[ "$status" -eq 0 ]] || failures=$((failures + 1))
        [[ "$(jq -r '.marker' "$MATERIALIZE_RUNTIME/config.json" 2>/dev/null || true)" == "$expected" ]] ||
            failures=$((failures + 1))
        _assert_runtime_secure_modes "$MATERIALIZE_RUNTIME" "$MATERIALIZE_ID" ||
            failures=$((failures + 1))
        [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == 600 ]] ||
            failures=$((failures + 1))
    done

    [[ "$failures" -eq 0 ]] || return 1
}

@test "missing remote auth hash rm failure rolls back runtime and auth then retries" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    _publish_remote_access_null auth-null || return 1

    local old_runtime old_auth_hash old_auth_mode old_temps new_runtime new_temps
    local marker="$BATS_TEST_TMPDIR/materialize-auth-rm.calls" failures=0
    old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
    old_auth_hash=$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    old_auth_mode=$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    old_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1

    MATERIALIZE_FAULT=auth-rm MATERIALIZE_FAULT_MARKER="$marker" RC_SCRIPT_PASSWORD=secret-pass \
        _rc session open
    [[ "$status" -ne 0 ]] || failures=$((failures + 1))
    [[ "$(cat "$marker" 2>/dev/null || true)" == auth-rm ]] || failures=$((failures + 1))
    new_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") ||
        new_runtime="runtime-unavailable"
    [[ "$new_runtime" == "$old_runtime" ]] || failures=$((failures + 1))
    [[ "$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_hash" ]] ||
        failures=$((failures + 1))
    [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_mode" ]] ||
        failures=$((failures + 1))
    new_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1
    [[ "$new_temps" == "$old_temps" ]] || failures=$((failures + 1))

    MATERIALIZE_FAULT=none MATERIALIZE_FAULT_MARKER="$marker" _rc session open
    [[ "$status" -eq 0 ]] || failures=$((failures + 1))
    [[ ! -e "$MATERIALIZE_CONFIG_DIR/.auth" ]] || failures=$((failures + 1))
    [[ "$(jq -r '.marker' "$MATERIALIZE_RUNTIME/config.json" 2>/dev/null || true)" == auth-null ]] ||
        failures=$((failures + 1))
    _assert_runtime_secure_modes "$MATERIALIZE_RUNTIME" "$MATERIALIZE_ID" ||
        failures=$((failures + 1))

    [[ "$failures" -eq 0 ]] || return 1
}
@test "failed runtime restore preserves the retired runtime backup" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    _publish_plain_marker runtime-rollback || return 1
    local old_runtime retired marker="$BATS_TEST_TMPDIR/materialize-runtime-rollback.calls"
    old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
    rm -f "$marker" || return 1

    MATERIALIZE_FAULT=runtime-rollback MATERIALIZE_FAULT_MARKER="$marker" RC_SCRIPT_PASSWORD=secret-pass \
        _rc session open
    assert_failure
    [[ "$(cat "$marker")" == $'publish-fail\nruntime-restore-fail' ]] || return 1
    retired=$(find "$MATERIALIZE_CONFIG_DIR" -mindepth 1 -maxdepth 1 \
        -name '.github-runtime.retired.*' -print)
    [[ "$(printf '%s\n' "$retired" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || return 1
    [[ "$(_runtime_fingerprint "$retired")" == "$old_runtime" ]] || return 1
    [[ ! -e "$MATERIALIZE_RUNTIME" ]] || return 1
    assert_output --partial "Резервные копии сохранены в $MATERIALIZE_CONFIG_DIR."
}

@test "failed auth restore preserves the auth backup after runtime rollback" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    _publish_remote_access_null auth-rollback || return 1
    local old_runtime old_auth_hash old_auth_mode backup marker="$BATS_TEST_TMPDIR/materialize-auth-rollback.calls"
    old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
    old_auth_hash=$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    old_auth_mode=$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    rm -f "$marker" || return 1

    MATERIALIZE_FAULT=auth-rollback MATERIALIZE_FAULT_MARKER="$marker" RC_SCRIPT_PASSWORD=secret-pass \
        _rc session open
    assert_failure
    [[ "$(cat "$marker")" == $'auth-rm\nauth-restore-fail' ]] || return 1
    [[ "$(_runtime_fingerprint "$MATERIALIZE_RUNTIME")" == "$old_runtime" ]] || return 1
    backup=$(find "$MATERIALIZE_CONFIG_DIR" -mindepth 1 -maxdepth 1 \
        -name '.auth.backup.*' -print)
    [[ "$(printf '%s\n' "$backup" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || return 1
    [[ "$(_hash_file "$backup")" == "$old_auth_hash" ]] || return 1
    [[ "$(_file_mode "$backup")" == "$old_auth_mode" ]] || return 1
    [[ "$old_auth_mode" == 600 ]] || return 1
    assert_output --partial "Резервные копии сохранены в $MATERIALIZE_CONFIG_DIR."
}

@test "startup ensures the complete local dependency set and starts one update check" {
    local deps_log="$BATS_TEST_TMPDIR/ensure-deps.calls"
    local update_log="$BATS_TEST_TMPDIR/update.calls" dep count failures=0
    cat > "$APP/common/ensure-deps.sh" <<'EOF'
#!/bin/bash
ensure_dep() {
    printf '%s\n' "$@" >> "$ENSURE_DEPS_LOG"
}
EOF
    cat > "$BIN/curl" <<'EOF'
#!/bin/bash
printf 'update\n' >> "$UPDATE_CHECK_LOG"
printf '%s\n' '{"tag_name":"v0.0.0"}'
EOF
    chmod +x "$APP/common/ensure-deps.sh" "$BIN/curl" || return 1
    export ENSURE_DEPS_LOG="$deps_log" UPDATE_CHECK_LOG="$update_log"

    cp -R "$PROJECT_ROOT/remote-control/tui" "$APP/"
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    [[ "$status" -eq 0 ]] || failures=$((failures + 1))
    for dep in jq openssl ssh scp base64; do
        count=$(grep -c "^${dep}$" "$deps_log" 2>/dev/null || true)
        [[ "$count" -eq 1 ]] || failures=$((failures + 1))
    done
    for ((count=0; count<50; count++)); do
        if [[ -f "$update_log" ]] && grep -q '^update$' "$update_log"; then
            break
        fi
        sleep 0.1
    done
    count=$(grep -c '^update$' "$update_log" 2>/dev/null || true)
    [[ "$count" -eq 1 ]] || failures=$((failures + 1))

    [[ "$failures" -eq 0 ]] || return 1
}

@test "readable incomplete GitHub metadata reports the GitHub diagnostic" {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    printf '%s\n' '{"type":"github","repo":"test-owner/essence-remote-control-config"}' \
        > "$config_dir/source.json"

    _rc session open
    assert_failure
    assert_output --partial "source.json содержит неполные или некорректные параметры GitHub."
    assert_output --partial "этап: проверка настроек источника GitHub"
}

@test "malformed source metadata keeps the generic startup fallback" {
    _rc source init-local
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    printf '%s\n' '{not-json' > "$config_dir/source.json"

    _rc session open
    assert_failure
    assert_output --partial "Не удалось открыть источник конфигурации."
}

@test "global B cannot migrate saved A; restart fetch and push stay on A" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SCOPE_CALLS_FILE="$BATS_TEST_TMPDIR/gh-scopes"
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" source_hash global_config_hash b_head
    source_hash=$(_hash_file "$config_dir/source.json")
    global_config_hash=$(_hash_file "$GIT_CONFIG_GLOBAL")
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)
    _publish_plain_marker fetched-from-a || return 1
    printf 'alternate-owner\n' > "$GH_ACTIVE_LOGIN_FILE"
    : > "$GH_CALLS_FILE"
    : > "$GH_SCOPE_CALLS_FILE"

    _rc source github-fetch
    assert_success
    assert_output --partial "Конфигурация загружена из GitHub."
    jq -e '.marker == "fetched-from-a"' "$config_dir/github-runtime/config.json"
    local pending="$BATS_TEST_TMPDIR/pending-a" a_head
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    git clone "$REMOTE" "$pending" >/dev/null || return 1
    git -C "$pending" config user.name pending
    git -C "$pending" config user.email pending@example.invalid
    jq '.marker = "pushed-to-a"' "$pending/config.json" > "$pending/config.json.tmp" &&
        mv "$pending/config.json.tmp" "$pending/config.json"
    git -C "$pending" add config.json
    git -C "$pending" commit -m local-pending >/dev/null || return 1
    git -C "$pending" push "$config_dir/github-store.git" HEAD:refs/heads/main >/dev/null || return 1
    _rc source github-push
    assert_success
    assert_output --partial "Локальная конфигурация отправлена в GitHub."
    jq -e '.marker == "pushed-to-a"' <(git --git-dir="$REMOTE" show main:config.json)
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" != "$a_head" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]] || return 1
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(_hash_file "$GIT_CONFIG_GLOBAL")" == "$global_config_hash" ]] || return 1
    [[ "$(git --git-dir="$config_dir/github-store.git" config --get remote.origin.url)" == \
        "https://github.com/test-owner/essence-remote-control-config.git" ]] || return 1
    grep -q '^test-owner repo view test-owner/' "$GH_SCOPE_CALLS_FILE"
    ! grep -q '^alternate-owner ' "$GH_SCOPE_CALLS_FILE" || return 1
    ! grep -q 'ghp_FixtureToken_' "$GH_CALLS_FILE" || return 1
    [[ "$output" != *"ghp_FixtureToken_"* ]] || return 1
    _assert_no_global_auth_mutation alternate-owner
}

@test "C explicitly migrates A to B without changing global gh or A remote" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SCOPE_CALLS_FILE="$BATS_TEST_TMPDIR/gh-scopes"
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" a_head global_config_hash
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    global_config_hash=$(_hash_file "$GIT_CONFIG_GLOBAL")
    : > "$GH_SCOPE_CALLS_FILE"

    _rc source github-change-account --login alternate-owner --storage none --yes
    assert_success
    jq -e '.repo == "alternate-owner/essence-remote-control-config"' "$config_dir/source.json"
    [[ "$(git --git-dir="$config_dir/github-store.git" config --get remote.origin.url)" == \
        "https://github.com/alternate-owner/essence-remote-control-config.git" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == \
        "$(git --git-dir="$config_dir/github-store.git" rev-parse refs/heads/main)" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(_hash_file "$GIT_CONFIG_GLOBAL")" == "$global_config_hash" ]] || return 1
    [[ ! -e "$config_dir/account-switch" ]] || return 1
    grep -q '^alternate-owner repo view alternate-owner/' "$GH_SCOPE_CALLS_FILE"
    _assert_no_global_auth_mutation
}

@test "C to a repository with an old snapshot format aborts without changes" {
    _prepare_alternate_remote
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" a_head b_head seed="$BATS_TEST_TMPDIR/v1-alternate"
    local source_hash
    git clone "$REMOTE" "$seed" >/dev/null 2>&1 || return 1
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    jq '.vault_version=1' "$seed/manifest.json" > "$seed/manifest.next" &&
        mv "$seed/manifest.next" "$seed/manifest.json" || return 1
    git -C "$seed" commit -am vault-v1 >/dev/null || return 1
    git -C "$seed" push --force "$ALTERNATE_REMOTE" HEAD:main >/dev/null 2>&1 || return 1
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)
    source_hash=$(_hash_file "$config_dir/source.json")

    _rc source github-change-account --login alternate-owner
    [ "$status" -eq 1 ]
    assert_output --partial "Смена аккаунта прервана."
    assert_output --partial "source github-switch-local"
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]] || return 1
    [[ ! -e "$config_dir/account-switch/transaction.json" ]]
}

@test "c cancellation and failed B authorization preserve A source cache and remotes" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" source_hash cache_hash a_head b_head
    source_hash=$(_hash_file "$config_dir/source.json")
    cache_hash=$(_hash_file "$config_dir/github-runtime/config.json")
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)

    _rc source github-change-account
    [ "$status" -eq 2 ]
    assert_output --partial "--login"
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    : > "$GH_CALLS_FILE"
    GH_TOKEN_UNAVAILABLE_LOGIN=alternate-owner GH_MODE=web-fail \
        _rc source github-change-account --login alternate-owner
    [ "$status" -eq 2 ]
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(_hash_file "$config_dir/github-runtime/config.json")" == "$cache_hash" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]] || return 1
    [[ "$(git --git-dir="$config_dir/github-store.git" config --get remote.origin.url)" == \
        "https://github.com/test-owner/essence-remote-control-config.git" ]] || return 1
    [[ ! -e "$config_dir/account-switch" ]] || return 1
    ! grep -q '^repo view alternate-owner/' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation
}

@test "cancel after opening B restores A session for same-process fetch" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    _connect_github --storage none
    assert_success
    local source="$HOME/.config/remote-control-essence/source.json" a_head b_head
    local seed="$BATS_TEST_TMPDIR/alternate-seed"
    printf 'invalid tracked state\n' > "$seed/invalid.txt"
    git -C "$seed" add invalid.txt
    git -C "$seed" commit -m invalid >/dev/null || return 1
    git -C "$seed" push origin main >/dev/null || return 1
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)

    _serve_requests '["session","open"]' \
        '["source","github-change-account","--login","alternate-owner"]' \
        '["source","github-fetch"]'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 2 and .error.code == "target_replace_required" and
        .error.tracked_files == 1)' >/dev/null || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok)' >/dev/null || return 1
    assert_output --partial "Конфигурация загружена из GitHub."
    jq -e '.repo == "test-owner/essence-remote-control-config"' "$source" || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]]
}

@test "rejected B push suspends the switch and same-process fetch rolls back to A" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" a_head b_head
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)
    printf '#!/bin/sh\nexit 1\n' > "$ALTERNATE_REMOTE/hooks/pre-receive"
    chmod +x "$ALTERNATE_REMOTE/hooks/pre-receive"

    _serve_requests '["session","open"]' \
        '["source","github-change-account","--login","alternate-owner","--storage","none","--yes"]' \
        '["source","github-push"]' '["source","github-fetch"]'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok == false)' >/dev/null || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 4 and .ok)' >/dev/null || return 1
    assert_output --partial "Результат отправки в новый репозиторий не подтверждён."
    assert_output --partial "Не удалось отправить конфигурацию в GitHub"
    assert_output --partial "Конфигурация загружена из GitHub."
    jq -e '.repo == "test-owner/essence-remote-control-config"' "$config_dir/source.json" || return 1
    [[ "$(git --git-dir="$config_dir/github-store.git" config --get remote.origin.url)" == \
        "https://github.com/test-owner/essence-remote-control-config.git" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]] || return 1
    [[ ! -e "$config_dir/account-switch" ]] || return 1
}

@test "missing A profile and token never selects global B or writes either repository" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" source_hash cache_hash a_head b_head
    source_hash=$(_hash_file "$config_dir/source.json")
    cache_hash=$(_hash_file "$config_dir/github-runtime/config.json")
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)
    rm -rf "$config_dir/credentials/gh/test-owner"
    printf 'alternate-owner\n' > "$GH_ACTIVE_LOGIN_FILE"
    : > "$GH_CALLS_FILE"

    GH_TOKEN_UNAVAILABLE_LOGIN=test-owner _rc session open
    assert_failure
    assert_output --partial "GH_CONFIG_DIR=$config_dir/credentials/gh/test-owner gh auth login --hostname github.com --web"
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(_hash_file "$config_dir/github-runtime/config.json")" == "$cache_hash" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]] || return 1
    [[ ! -e "$config_dir/credentials/gh/test-owner/hosts.yml" ]] || return 1
    ! grep -q '^repo ' "$GH_CALLS_FILE" || return 1
    ! grep -q '^auth login .*--web' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation alternate-owner
}

@test "startup imports only saved A token when global gh points to B" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SCOPE_CALLS_FILE="$BATS_TEST_TMPDIR/gh-scopes"
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence" source_hash
    source_hash=$(_hash_file "$config_dir/source.json")
    rm -rf "$config_dir/credentials/gh/test-owner"
    printf 'alternate-owner\n' > "$GH_ACTIVE_LOGIN_FILE"
    : > "$GH_CALLS_FILE"
    : > "$GH_SCOPE_CALLS_FILE"

    _rc session open
    assert_success
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ "$(sed -n 's/^user: //p' "$config_dir/credentials/gh/test-owner/hosts.yml")" == test-owner ]] || return 1
    grep -q '^auth token --hostname github.com --user test-owner$' "$GH_CALLS_FILE"
    grep -q '^test-owner auth login --hostname github.com --git-protocol https --with-token$' "$GH_SCOPE_CALLS_FILE"
    ! grep -q '^auth login .*--web' "$GH_CALLS_FILE" || return 1
    ! grep -q '^auth token .*--user alternate-owner' "$GH_CALLS_FILE" || return 1
    ! grep -q 'ghp_FixtureToken_' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation alternate-owner
}

@test "web login permits isolated authorization when targeted token is absent" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SCOPE_CALLS_FILE="$BATS_TEST_TMPDIR/gh-scopes"
    GH_TOKEN_UNAVAILABLE_LOGIN=test-owner GH_WEB_LOGIN=test-owner \
        _rc source github-login --login test-owner
    assert_success
    GH_TOKEN_UNAVAILABLE_LOGIN=test-owner _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    jq -e '.repo == "test-owner/essence-remote-control-config"' "$config_dir/source.json"
    grep -q '^test-owner auth login --hostname github.com --git-protocol https --web$' "$GH_SCOPE_CALLS_FILE"
    [[ "$output" != *"ghp_FixtureToken_"* ]] || return 1
    ! grep -q 'ghp_FixtureToken_' "$GH_CALLS_FILE" || return 1
    ! grep -q 'ghp_FixtureToken_' "$config_dir/source.json" || return 1
    _assert_no_global_auth_mutation
}

@test "GitHub connect requires a valid login before any repository call" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    _rc source init-local
    assert_success
    _rc source github-connect --storage none
    [ "$status" -eq 2 ]
    assert_output --partial "--login"
    _rc source github-connect --login bad/login --storage none
    [ "$status" -eq 2 ]
    assert_output --partial "Некорректный логин GitHub"
    [[ ! -e "$HOME/.config/remote-control-essence/source.json" ]] || return 1
    ! grep -q '^repo ' "$GH_CALLS_FILE" || return 1
    _assert_no_global_auth_mutation
}

_portable_install_device_wrappers() {
    export TEST_REAL_CAT TEST_MACHINE_ID=11111111111111111111111111111111
    export PORTABLE_SSH_LOG="$BATS_TEST_TMPDIR/portable-ssh.log"
    TEST_REAL_CAT=$(command -v cat) || return 1
    : > "$PORTABLE_SSH_LOG"
    cat > "$BIN/cat" <<'EOF'
#!/bin/bash
if [[ "$#" == 1 && "$1" == /etc/machine-id ]]; then
    printf '%s\n' "$TEST_MACHINE_ID"
else
    exec "$TEST_REAL_CAT" "$@"
fi
EOF
    local tool
    for tool in ssh scp; do
        cat > "$BIN/$tool" <<'EOF'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$PORTABLE_SSH_LOG"
exit 91
EOF
    done
    chmod +x "$BIN/cat" "$BIN/ssh" "$BIN/scp"
    hash -r
}

_portable_seed_local_passwords() (
    umask 077
    local root="$HOME/.config/remote-control-essence"
    export CONFIG_DIR="$root" STATE_DIR="$root" CONFIG_JSON="$root/config.json"
    export SECRETS_JSON="$root/secrets.json" STATE_MANIFEST="$root/manifest.json"
    export TEMPLATES_DIR="$root/templates" SSH_IDENTITIES_DIR="$root/ssh/identities"
    export SSH_KNOWN_HOSTS="$root/ssh/known_hosts"
    source "$APP/common/common.sh"
    source "$APP/modules/state.sh"
    source "$APP/modules/nodes.sh"
    jq -n '{
      schema_version:2,nodes:[
        {id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"portable-a",ip:"192.0.2.10",port:22,user:"root",auth:"password",identity:null,secret_id:"node:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:ssh-password",tag:"TEST",aliases:{}},
        {id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",name:"portable-b",ip:"192.0.2.11",port:22,user:"root",auth:"password",identity:null,secret_id:"node:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:ssh-password",tag:"TEST",aliases:{}}],
      groups:[],clients:[],connections:[]}' > "$CONFIG_JSON" || exit 1
    node_secret_set aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 'synthetic-portable-a' || exit 1
    node_secret_set bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 'synthetic-portable-b' || exit 1
    jq '.node_passwords["node:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:ssh-password"]="bad-device-a-ciphertext"' "$SECRETS_JSON" > "$root/secrets.next" &&
        mv "$root/secrets.next" "$SECRETS_JSON" || exit 1
    mkdir -p "$SSH_IDENTITIES_DIR"
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/password-host" || exit 1
    local kind public ignored
    read -r kind public ignored < "$BATS_TEST_TMPDIR/password-host.pub"
    printf '192.0.2.10 %s %s\n192.0.2.11 %s %s\n' "$kind" "$public" "$kind" "$public" > "$SSH_KNOWN_HOSTS"
    state_checkpoint || exit 1
)

_portable_get_runtime_password() (
    local runtime="$1" node="$2"
    source "$APP/common/common.sh"
    source "$APP/modules/state.sh"
    source "$APP/modules/nodes.sh"
    node_secret_get "$node" "$runtime/secrets.json"
)

_portable_prepare_two_devices() {
    _portable_install_device_wrappers || return 1
    export PORTABLE_HOME_A="$HOME"
    _rc source init-local
    assert_success
    _portable_seed_local_passwords || return 1
    local original="$HOME/.config/remote-control-essence/secrets.json" original_hash
    original_hash=$(_hash_file "$original")
    _connect_github --storage none
    assert_success
    [[ "$output" != *synthetic-portable* && "$output" != *bad-device-a-ciphertext* ]] || return 1
    [[ "$(_hash_file "$original")" == "$original_hash" ]] || return 1
    git --git-dir="$REMOTE" show main:secrets.json > "$BATS_TEST_TMPDIR/published-secrets.json" || return 1
    jq -e '.schema_version==2 and .node_passwords=={"node:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:ssh-password":"synthetic-portable-a"}' "$BATS_TEST_TMPDIR/published-secrets.json" || return 1
    git --git-dir="$REMOTE" show main:manifest.json > "$BATS_TEST_TMPDIR/published-manifest.json" || return 1
    jq -e '.vault_version==2 and .portability=={status:"needs_setup",issues:[{node_id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",reason:"missing_secret"}]}' "$BATS_TEST_TMPDIR/published-manifest.json" || return 1
    export HOME="$BATS_TEST_TMPDIR/device-b-home" TEST_MACHINE_ID=22222222222222222222222222222222
    mkdir -p "$HOME"
    _rc source init-local
    assert_success
    _connect_github --existing remote
    assert_success
    export PORTABLE_CONFIG="$HOME/.config/remote-control-essence"
    export PORTABLE_RUNTIME="$PORTABLE_CONFIG/github-runtime"
    [[ "$(_portable_get_runtime_password "$PORTABLE_RUNTIME" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == synthetic-portable-a ]] || return 1
    run _portable_get_runtime_password "$PORTABLE_RUNTIME" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    [[ "$status" -eq 2 && -z "$output" ]] || return 1
    jq -e '.schema_version==1 and .node_passwords["node:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:ssh-password"]!="synthetic-portable-a"' "$PORTABLE_RUNTIME/secrets.json" || return 1
    [[ "$(_file_mode "$PORTABLE_RUNTIME/secrets.json")" == 600 ]] || return 1
    [[ -z "$(_materialization_temp_inventory "$PORTABLE_CONFIG")" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password actual entrypoint recovers only selected node and returns repaired passwords to device A" {
    _portable_prepare_two_devices || return 1
    local config_hash before_temps
    config_hash=$(_hash_file "$PORTABLE_RUNTIME/config.json")
    before_temps=$(_materialization_temp_inventory "$PORTABLE_CONFIG")
    run bash -c 'printf "%s\n" "$1" | "$0" node password --name portable-b --password-stdin' \
        "$APP/remote-control-essence.sh" synthetic-repaired-b
    assert_success
    [[ "$output" != *synthetic-repaired-b* && "$output" != *synthetic-portable-a* ]] || return 1
    [[ "$(_hash_file "$PORTABLE_RUNTIME/config.json")" == "$config_hash" ]] || return 1
    [[ "$(_portable_get_runtime_password "$PORTABLE_RUNTIME" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" == synthetic-repaired-b ]] || return 1
    jq -e '.portability.status=="ready" and .portability.issues==[]' "$PORTABLE_RUNTIME/manifest.json" || return 1
    [[ "$(_materialization_temp_inventory "$PORTABLE_CONFIG")" == "$before_temps" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]] || return 1
    export HOME="$PORTABLE_HOME_A" TEST_MACHINE_ID=11111111111111111111111111111111
    _rc session open
    assert_success
    local runtime="$HOME/.config/remote-control-essence/github-runtime"
    [[ "$(_portable_get_runtime_password "$runtime" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == synthetic-portable-a ]] || return 1
    [[ "$(_portable_get_runtime_password "$runtime" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" == synthetic-repaired-b ]] || return 1
    jq -e '.portability.status=="ready" and .portability.issues==[]' "$runtime/manifest.json" || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password actual entrypoint empty or absent password input preserves local secrets" {
    _portable_prepare_two_devices || return 1
    _portable_reopen_local || return 1
    local root="$PORTABLE_CONFIG" before input
    before="$(_hash_file "$root/secrets.json") $(_hash_file "$root/manifest.json") $(_hash_file "$root/config.json")"
    for input in '' $'\n' $'\r\n'; do
        run bash -c 'printf "%s" "$1" | "$0" node password --name portable-b --password-stdin' \
            "$APP/remote-control-essence.sh" "$input"
        [ "$status" -eq 2 ]
        [[ "$(_hash_file "$root/secrets.json") $(_hash_file "$root/manifest.json") $(_hash_file "$root/config.json")" == "$before" ]] || return 1
        [[ ! -s "$PORTABLE_SSH_LOG" ]] || return 1
    done
    run bash -c '"$0" node password --name portable-b < /dev/null' "$APP/remote-control-essence.sh"
    [ "$status" -eq 2 ]
    [[ "$(_hash_file "$root/secrets.json") $(_hash_file "$root/manifest.json") $(_hash_file "$root/config.json")" == "$before" ]] || return 1
    _rc session open
    assert_success
    [[ "$(_portable_get_runtime_password "$root" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == synthetic-portable-a ]] || return 1
    run _portable_get_runtime_password "$root" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    [[ "$status" -eq 2 && -z "$output" ]]
}

@test "portable password actual entrypoint failed secret publication restores secrets and manifest" {
    _portable_prepare_two_devices || return 1
    _portable_reopen_local || return 1
    local root="$PORTABLE_CONFIG" before
    before="$(_hash_file "$root/secrets.json") $(_hash_file "$root/manifest.json")"
    export PORTABLE_REAL_MV PORTABLE_WRITE_FAULT="$BATS_TEST_TMPDIR/password-write-failed"
    PORTABLE_REAL_MV=$(command -v mv)
    cat > "$BIN/mv" <<'EOF'
#!/bin/bash
if [[ "$*" == *"$PORTABLE_CONFIG/secrets.json"* && ! -e "$PORTABLE_WRITE_FAULT" ]]; then
    : > "$PORTABLE_WRITE_FAULT"
    exit 89
fi
exec "$PORTABLE_REAL_MV" "$@"
EOF
    chmod +x "$BIN/mv"
    run bash -c 'printf "%s\n" "$1" | "$0" node password --name portable-b --password-stdin' \
        "$APP/remote-control-essence.sh" synthetic-write-failure
    [ "$status" -eq 1 ]
    [[ -f "$PORTABLE_WRITE_FAULT" ]] || return 1
    [[ "$output" != *synthetic-write-failure* ]] || return 1
    [[ "$(_hash_file "$root/secrets.json") $(_hash_file "$root/manifest.json")" == "$before" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password unsupported startup leaves prior runtime auth and staging unchanged" {
    _portable_prepare_two_devices || return 1
    local before auth_before temps updater="$BATS_TEST_TMPDIR/unsupported-updater"
    before=$(_runtime_fingerprint "$PORTABLE_RUNTIME")
    temps=$(_materialization_temp_inventory "$PORTABLE_CONFIG")
    [[ ! -e "$PORTABLE_CONFIG/.auth" ]] || return 1
    git clone "$REMOTE" "$updater" >/dev/null || return 1
    git -C "$updater" config user.name fixture
    git -C "$updater" config user.email fixture@example.invalid
    jq '.vault_version=1' "$updater/manifest.json" > "$updater/manifest.next" &&
        mv "$updater/manifest.next" "$updater/manifest.json" || return 1
    git -C "$updater" add manifest.json
    git -C "$updater" commit -m unsupported >/dev/null
    git -C "$updater" push origin main >/dev/null || return 1
    local main_before
    main_before=$(git --git-dir="$REMOTE" rev-parse main)
    _rc session open
    assert_failure
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$main_before" ]] || return 1
    [[ "$(_runtime_fingerprint "$PORTABLE_RUNTIME")" == "$before" ]] || return 1
    [[ "$(_materialization_temp_inventory "$PORTABLE_CONFIG")" == "$temps" ]] || return 1
    [[ ! -e "$PORTABLE_CONFIG/.auth" && ! -s "$PORTABLE_SSH_LOG" ]]
}

# _portable_publish_v1 — push a vault-1 snapshot whose secrets are device A ciphertext.
_portable_publish_v1() {
    local updater="$BATS_TEST_TMPDIR/v1-updater"
    local device_a="$PORTABLE_HOME_A/.config/remote-control-essence"
    rm -rf "$updater"
    git clone "$REMOTE" "$updater" >/dev/null 2>&1 || return 1
    git -C "$updater" config user.name fixture
    git -C "$updater" config user.email fixture@example.invalid
    jq '.vault_version=1 | .minimum_remote_control_version="1.0.3" |
        .portability={status:"ready",issues:[]}' "$updater/manifest.json" > "$updater/manifest.next" &&
        mv "$updater/manifest.next" "$updater/manifest.json" || return 1
    jq '{schema_version:1,node_passwords}' "$device_a/secrets.json" > "$updater/secrets.json" || return 1
    git -C "$updater" add manifest.json secrets.json
    git -C "$updater" commit -m vault-v1 >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null 2>&1 || return 1
    PORTABLE_V1_COMMIT=$(git --git-dir="$REMOTE" rev-parse main)
}

_portable_use_device_a() {
    export HOME="$PORTABLE_HOME_A" TEST_MACHINE_ID=11111111111111111111111111111111
}

@test "format recovery migrates a v1 GitHub snapshot on top of history" {
    _portable_prepare_two_devices || return 1
    _portable_publish_v1 || return 1
    _portable_use_device_a
    _rc source github-migrate-format
    [ "$status" -eq 2 ]
    assert_output --partial "будут храниться в GitHub без шифрования"
    assert_output --partial "навсегда останутся в истории Git."
    _rc source github-migrate-format --yes
    assert_success
    [[ "$output" != *synthetic-portable* ]] || return 1
    git --git-dir="$REMOTE" show main:manifest.json > "$BATS_TEST_TMPDIR/m.json" || return 1
    jq -e '.vault_version==2 and .minimum_remote_control_version=="1.1.0" and
        .portability.issues==[{node_id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",reason:"missing_secret"}]' "$BATS_TEST_TMPDIR/m.json" || return 1
    git --git-dir="$REMOTE" show main:secrets.json > "$BATS_TEST_TMPDIR/s.json" || return 1
    jq -e '.schema_version==2 and .node_passwords=={"node:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:ssh-password":"synthetic-portable-a"}' "$BATS_TEST_TMPDIR/s.json" || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$PORTABLE_V1_COMMIT" main || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" != "$PORTABLE_V1_COMMIT" ]] || return 1
    [[ "$(_portable_get_runtime_password "$HOME/.config/remote-control-essence/github-runtime" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == synthetic-portable-a ]] || return 1
    # The plaintext logical snapshot is not kept next to the runtime (S-M11).
    [[ ! -e "$HOME/.config/remote-control-essence/runtime-vault.json" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "format recovery refusal and newer snapshots leave GitHub untouched" {
    _portable_prepare_two_devices || return 1
    _portable_publish_v1 || return 1
    _portable_use_device_a
    local input root="$HOME/.config/remote-control-essence" local_before
    # A manifest without .access would be rewritten by state_checkpoint if the snapshot ran before consent.
    jq 'del(.access)' "$root/manifest.json" > "$root/manifest.next" &&
        mv "$root/manifest.next" "$root/manifest.json" || return 1
    local_before="$(_hash_file "$root/config.json") $(_hash_file "$root/manifest.json") $(_hash_file "$root/secrets.json") $(_hash_file "$root/ssh/known_hosts")"
    for input in migrate replace status; do
        case "$input" in
            migrate) _rc source github-migrate-format ;;
            replace) _rc source github-replace-with-local ;;
            status) _rc status ;;
        esac
        assert_failure
        case "$input" in
            migrate) assert_output --partial "Преобразование конфигурации GitHub" ;;
            replace) assert_output --partial "Замена конфигурации GitHub" ;;
        esac
        [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$PORTABLE_V1_COMMIT" ]] || return 1
        [[ "$(_hash_file "$root/config.json") $(_hash_file "$root/manifest.json") $(_hash_file "$root/secrets.json") $(_hash_file "$root/ssh/known_hosts")" == "$local_before" ]] || return 1
    done
    local updater="$BATS_TEST_TMPDIR/v1-updater"
    jq '.minimum_remote_control_version="9.9.9"' "$updater/manifest.json" > "$updater/manifest.next" &&
        mv "$updater/manifest.next" "$updater/manifest.json" || return 1
    git -C "$updater" commit -am newer >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null 2>&1 || return 1
    local newer
    newer=$(git --git-dir="$REMOTE" rev-parse main)
    _rc status
    assert_failure
    assert_output --partial "Remote Control 9.9.9"
    _rc source github-migrate-format --yes
    assert_failure
    _rc source github-replace-with-local --yes
    assert_failure
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$newer" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "format recovery on another device marks foreign passwords as missing" {
    _portable_prepare_two_devices || return 1
    _portable_publish_v1 || return 1
    _rc source github-migrate-format
    [ "$status" -eq 2 ]
    assert_output --partial "Потребуется повторный ввод пароля: portable-a, portable-b"
    _rc source github-migrate-format --yes
    assert_success
    git --git-dir="$REMOTE" show main:manifest.json > "$BATS_TEST_TMPDIR/m.json" || return 1
    jq -e '.vault_version==2 and .portability.status=="needs_setup" and
        (.portability.issues|map(select(.reason=="missing_secret").node_id)|sort)==
        ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]' "$BATS_TEST_TMPDIR/m.json" || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "format recovery replaces GitHub with the device-only configuration" {
    _portable_prepare_two_devices || return 1
    _portable_publish_v1 || return 1
    _portable_use_device_a
    local local_config="$HOME/.config/remote-control-essence/config.json"
    _rc source github-replace-with-local
    [ "$status" -eq 2 ]
    assert_output --partial "будут храниться в GitHub без шифрования"
    assert_output --partial "навсегда останутся в истории Git."
    _rc source github-replace-with-local --yes
    assert_success
    git --git-dir="$REMOTE" show main:config.json > "$BATS_TEST_TMPDIR/c.json" || return 1
    cmp -s <(jq -S . "$BATS_TEST_TMPDIR/c.json") <(jq -S . "$local_config") || return 1
    git --git-dir="$REMOTE" show main:manifest.json | jq -e '.vault_version==2' >/dev/null || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$PORTABLE_V1_COMMIT" main || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "source github-replace-with-local replaces remote config with the device-only configuration" {
    _portable_prepare_two_devices || return 1
    local before local_config="$HOME/.config/remote-control-essence/config.json"
    before=$(git --git-dir="$REMOTE" rev-parse main)
    _rc source github-replace-with-local
    [ "$status" -eq 2 ]
    assert_output --partial "Локальная конфигурация пуста."
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$before" ]] || return 1
    _rc source github-replace-with-local --yes
    assert_success
    git --git-dir="$REMOTE" show main:config.json > "$BATS_TEST_TMPDIR/c.json" || return 1
    cmp -s <(jq -S . "$BATS_TEST_TMPDIR/c.json") <(jq -S . "$local_config") || return 1
    jq -e '.nodes==[]' "$HOME/.config/remote-control-essence/github-runtime/config.json" || return 1
    [[ ! -e "$HOME/.config/remote-control-essence/runtime-vault.json" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "connecting a local device to a v1 repository offers migration" {
    _portable_prepare_two_devices || return 1
    _portable_publish_v1 || return 1
    export HOME="$BATS_TEST_TMPDIR/device-c-home" TEST_MACHINE_ID=33333333333333333333333333333333
    mkdir -p "$HOME"
    _rc source init-local
    assert_success
    _connect_github
    [ "$status" -eq 2 ]
    assert_output --partial "--existing migrate|local"
    _connect_github --existing migrate
    assert_success
    git --git-dir="$REMOTE" show main:manifest.json | jq -e '.vault_version==2' >/dev/null || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$PORTABLE_V1_COMMIT" main || return 1
    jq -e '.type=="github"' "$HOME/.config/remote-control-essence/source.json" || return 1
    jq -e '(.nodes|length)==2' "$HOME/.config/remote-control-essence/github-runtime/config.json" || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password actual entrypoint real age publishes partial state and imports on device B" {
    _real_age_tools
    _portable_install_device_wrappers || return 1
    _rc source init-local
    assert_success
    _portable_seed_local_passwords || return 1
    _age_headless '{"new-vault-password":"synthetic-vault-pass"}' \
        source github-connect --login test-owner --storage age --yes --secrets-stdin
    assert_success
    [[ "$output" != *synthetic-portable* && "$output" != *synthetic-vault-pass* ]] || return 1
    local files
    files=$(git --git-dir="$REMOTE" ls-tree -r --name-only main)
    [[ "$files" == $'recipient.txt\nstate.json.age\nstorage.json\nunlock.age' ]] || return 1
    export HOME="$BATS_TEST_TMPDIR/age-device-b" TEST_MACHINE_ID=22222222222222222222222222222222
    mkdir -p "$HOME"
    _rc source init-local
    assert_success
    _age_headless '{"vault-password":"synthetic-vault-pass"}' \
        source github-connect --login test-owner --existing remote --secrets-stdin
    assert_success
    local runtime="$HOME/.config/remote-control-essence/github-runtime"
    [[ "$(_portable_get_runtime_password "$runtime" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == synthetic-portable-a ]] || return 1
    run _portable_get_runtime_password "$runtime" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    [[ "$status" -eq 2 && -z "$output" ]] || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password actual entrypoint failed issue removal restores both local files" {
    _portable_prepare_two_devices || return 1
    _portable_reopen_local || return 1
    local before="$(_hash_file "$PORTABLE_CONFIG/secrets.json") $(_hash_file "$PORTABLE_CONFIG/manifest.json")"
    export PORTABLE_REAL_MV PORTABLE_SECRET_WRITTEN="$BATS_TEST_TMPDIR/secret-written"
    export PORTABLE_ISSUE_FAULT="$BATS_TEST_TMPDIR/issue-write-failed"
    PORTABLE_REAL_MV=$(command -v mv)
    cat > "$BIN/mv" <<'EOF'
#!/bin/bash
last="${!#}"
if [[ "$last" == "$PORTABLE_CONFIG/secrets.json" ]]; then
    "$PORTABLE_REAL_MV" "$@" || exit $?
    : > "$PORTABLE_SECRET_WRITTEN"
    exit 0
fi
if [[ "$last" == "$PORTABLE_CONFIG/manifest.json" &&
      -e "$PORTABLE_SECRET_WRITTEN" && ! -e "$PORTABLE_ISSUE_FAULT" ]]; then
    : > "$PORTABLE_ISSUE_FAULT"
    exit 88
fi
exec "$PORTABLE_REAL_MV" "$@"
EOF
    chmod +x "$BIN/mv"
    run bash -c 'printf "%s\n" "$1" | "$0" node password --name portable-b --password-stdin' \
        "$APP/remote-control-essence.sh" synthetic-issue-failure
    [ "$status" -eq 1 ]
    [[ -e "$PORTABLE_SECRET_WRITTEN" && -e "$PORTABLE_ISSUE_FAULT" ]] || return 1
    [[ "$(_hash_file "$PORTABLE_CONFIG/secrets.json") $(_hash_file "$PORTABLE_CONFIG/manifest.json")" == "$before" ]] || return 1
    [[ "$output" != *synthetic-issue-failure* && ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password actual entrypoint recovery keeps unrelated host pin issue" {
    _portable_prepare_two_devices || return 1
    _portable_reopen_local || return 1
    ssh-keygen -R 192.0.2.11 -f "$PORTABLE_CONFIG/ssh/known_hosts" >/dev/null 2>&1 || return 1
    jq '.portability.issues += [{node_id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",reason:"missing_host_key"}]' "$PORTABLE_CONFIG/manifest.json" > "$BATS_TEST_TMPDIR/manifest.host-issue" &&
        mv "$BATS_TEST_TMPDIR/manifest.host-issue" "$PORTABLE_CONFIG/manifest.json" || return 1
    chmod 600 "$PORTABLE_CONFIG/manifest.json"
    run bash -c 'printf "%s\n" "$1" | "$0" node password --name portable-b --password-stdin' \
        "$APP/remote-control-essence.sh" synthetic-repaired-b
    assert_success
    [[ "$(_portable_get_runtime_password "$PORTABLE_CONFIG" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" == synthetic-repaired-b ]] || return 1
    jq -e '.portability=={status:"needs_setup",issues:[{node_id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",reason:"missing_host_key"}]}' "$PORTABLE_CONFIG/manifest.json" || return 1
    [[ ! -s "$PORTABLE_SSH_LOG" ]]
}

@test "portable password actual entrypoint import encoding failure preserves prior runtime" {
    _portable_prepare_two_devices || return 1
    local before temps
    before=$(_runtime_fingerprint "$PORTABLE_RUNTIME")
    temps=$(_materialization_temp_inventory "$PORTABLE_CONFIG")
    _publish_plain_marker encoding-failure || return 1
    export PORTABLE_ENCODE_FAULT="$BATS_TEST_TMPDIR/encoding-failed"
    mv "$BIN/openssl" "$BIN/openssl.normal"
    cat > "$BIN/openssl" <<'EOF'
#!/bin/bash
if [[ "$1" == enc && "$*" != *" -d "* ]]; then
    : > "$PORTABLE_ENCODE_FAULT"
    printf 'partial-unpublishable-ciphertext'
    exit 87
fi
exec "$BIN/openssl.normal" "$@"
EOF
    chmod +x "$BIN/openssl"
    _rc session open
    assert_failure
    [[ -e "$PORTABLE_ENCODE_FAULT" ]] || return 1
    [[ "$output" != *synthetic-portable* && "$output" != *partial-unpublishable* ]] || return 1
    [[ "$(_runtime_fingerprint "$PORTABLE_RUNTIME")" == "$before" ]] || return 1
    [[ "$(_materialization_temp_inventory "$PORTABLE_CONFIG")" == "$temps" ]] || return 1
    [[ ! -e "$PORTABLE_CONFIG/.auth" && ! -s "$PORTABLE_SSH_LOG" ]]
}

_portable_reopen_local() {
    _rc source github-switch-local
    assert_success
    local secret_hash
    secret_hash=$(_hash_file "$PORTABLE_CONFIG/secrets.json") || return 1
    jq -S . "$PORTABLE_CONFIG/manifest.json" > "$BATS_TEST_TMPDIR/local-manifest-before.json"
    jq -S . "$PORTABLE_CONFIG/config.json" > "$BATS_TEST_TMPDIR/local-config-before.json"
    # Local startup checkpoints the imported manifest into its canonical key
    # order. Establish the local UI baseline after opening, not before startup.
    _rc session open
    assert_success
    [[ "$(_hash_file "$PORTABLE_CONFIG/secrets.json")" == "$secret_hash" ]] || return 1
    diff -u "$BATS_TEST_TMPDIR/local-manifest-before.json" <(jq -S . "$PORTABLE_CONFIG/manifest.json") || return 1
    diff -u "$BATS_TEST_TMPDIR/local-config-before.json" <(jq -S . "$PORTABLE_CONFIG/config.json") || return 1
}

# No controlling terminal: core age paths must never fall back to a prompt.
_age_headless() {
    local requests="$1"
    shift
    command -v python3 >/dev/null 2>&1 || skip "python3 нужен для headless integration"
    run --separate-stderr python3 -c '
import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    out, err = p.communicate(sys.stdin.buffer.read(), timeout=90)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.communicate()
    raise
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(p.returncode)
' "$APP/remote-control-essence.sh" "$@" <<< "$requests"
}

_real_age_tools() {
    local dir="${RC_TEST_AGE_DIR:-}" path version major minor patch
    if [[ -z "$dir" ]]; then
        path=$(command -v age) || skip "Нужен реальный age >=1.3.2 и batchpass"
        dir=$(dirname "$path")
    fi
    [[ -x "$dir/age" && -x "$dir/age-keygen" && -x "$dir/age-plugin-batchpass" ]] ||
        skip "Нужен реальный age >=1.3.2 и batchpass"
    dir=$(cd "$dir" && pwd -P) || return 1
    version=$("$dir/age" --version) || return 1
    [[ "$version" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
    (( major > 1 || (major == 1 && (minor > 3 || (minor == 3 && patch >= 2))) )) ||
        skip "Нужен реальный age >=1.3.2 и batchpass"
    export AGE_BIN="$dir/age" AGE_KEYGEN_BIN="$dir/age-keygen"
    export RC_TEST_REAL_AGE_DIR="$dir"
}

@test "CLI in plaintext GitHub mode pushes a mutation and honours the session lock" {
    bats_require_minimum_version 1.5.0
    _rc source init-local
    assert_success
    _connect_github --storage none
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"

    run --separate-stderr "$APP/remote-control-essence.sh" status --json < /dev/null
    assert_success
    jq -e '.ok and .data.source.type == "github" and (.sync | type == "string")' <<< "$output"

    run --separate-stderr "$APP/remote-control-essence.sh" group add --name lab --json < /dev/null
    assert_success
    jq -e '.data.name == "LAB"' <<< "$output"
    git --git-dir="$REMOTE" show main:config.json | jq -e 'any(.groups[]; .name == "LAB")'
    [ ! -e "$config_dir/.rc-lock" ]

    sleep 60 &
    local holder=$!
    mkdir "$config_dir/.rc-lock"
    printf 'pid=%s\nkind=session\nlabel=github-session\n' "$holder" > "$config_dir/.rc-lock/owner"
    local start=$SECONDS
    run --separate-stderr "$APP/remote-control-essence.sh" status --json < /dev/null
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = locked ]
    (( SECONDS - start < 10 ))
}

@test "CLI unlocks the age vault only from RC_VAULT_PASSWORD" {
    bats_require_minimum_version 1.5.0
    git --git-dir="$REMOTE" update-ref -d refs/heads/main
    _install_fake_age
    _rc source init-local
    assert_success
    _rc_secrets '{"new-vault-password":"access-pass"}' \
        source github-connect --login test-owner --storage age
    assert_success

    run --separate-stderr "$APP/remote-control-essence.sh" status --json < /dev/null
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = vault_password_required ]

    RC_VAULT_PASSWORD=wrong-pass run --separate-stderr \
        "$APP/remote-control-essence.sh" status --json < /dev/null
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = vault_password_invalid ]

    RC_VAULT_PASSWORD=access-pass run --separate-stderr \
        "$APP/remote-control-essence.sh" status --json < /dev/null
    assert_success
    jq -e '.ok and .data.source.type == "github"' <<< "$output"

    # Через serve пароль приходит только полем secrets запроса session open.
    run --separate-stderr bash -c 'printf "%s\n" "{\"id\":1,\"argv\":[\"status\"]}" \
        "{\"id\":2,\"argv\":[\"session\",\"open\"]}" \
        "{\"id\":3,\"argv\":[\"session\",\"open\"],\"secrets\":{\"vault-password\":\"access-pass\"}}" \
        "{\"id\":4,\"argv\":[\"status\"]}" | RC_VAULT_PASSWORD=access-pass "$0" serve' \
        "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output$stderr" != *access-pass* ]]
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 1 and .error.code == "session_closed")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 2 and .error.code == "vault_password_required")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok and .data.source == "github")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 4 and .ok and .data.source.type == "github")' >/dev/null
}

# Файлы каталога конфигурации (без него самого), по одному на строку.
_config_tree() {
    local dir="$HOME/.config/remote-control-essence"
    [[ -d "$dir" ]] || return 0
    (cd "$dir" && find . -mindepth 1 | LC_ALL=C sort)
}

@test "refused first GitHub connect leaves no configuration and keeps first run" {
    local config_dir="$HOME/.config/remote-control-essence"

    GH_MODE=missing _connect_github --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = repo_create_required ]
    [[ ! -e "$config_dir" ]] || return 1
    _rc session status --json
    [ "$(jq -c '.data | [.configured,.open,.authorized]' <<< "$output")" = '[false,false,false]' ]

    _connect_github --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = storage_mode_required ]
    [[ ! -e "$config_dir" ]] || return 1
    _rc session status --json
    [ "$(jq -r '.data.configured' <<< "$output")" = false ]

    # Профиль входа, созданный до подключения, остаётся; удаляется только новое.
    _rc source github-login --login test-owner
    assert_success
    local before
    before=$(_config_tree)
    [[ "$before" == *"./credentials/gh/test-owner/hosts.yml"* ]] || return 1
    GH_MODE=missing _connect_github --json
    [ "$(jq -r '.error.code' <<< "$output")" = repo_create_required ]
    [ "$(_config_tree)" = "$before" ]
    _rc session status --json
    [ "$(jq -r '.data.configured' <<< "$output")" = false ]
}

@test "failed source init-local removes only the files it created" {
    local config_dir="$HOME/.config/remote-control-essence"
    mkdir -p "$config_dir"
    printf 'not json\n' > "$config_dir/manifest.json"

    _rc source init-local --json
    [ "$status" -ne 0 ]
    [ "$(_config_tree)" = "./manifest.json" ]
    [ "$(cat "$config_dir/manifest.json")" = "not json" ]
    _rc session status --json
    [ "$(jq -r '.data.configured' <<< "$output")" = false ]
}

@test "first GitHub connect retries in one serve process after repo_create_required" {
    export GH_MODE=reconnect GH_REPO_STATE_FILE="$BATS_TEST_TMPDIR/repo-created"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/repo-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    _serve_requests '["source","github-connect","--login","test-owner"]' \
        '["session","status"]' \
        '["source","github-connect","--login","test-owner","--create-repo","--storage","none","--yes"]' \
        '["session","status"]'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 1 and .error.code == "repo_create_required")' >/dev/null || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 2 and .data.configured == false and .data.open == false)' >/dev/null || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok and .data.storage == "none")' >/dev/null || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 4 and .data.configured and .data.source == "github" and .data.open)' >/dev/null || return 1
    [ "$(cat "$GH_CREATE_COUNT_FILE")" = 1 ]
    jq -e '.type == "github"' "$HOME/.config/remote-control-essence/source.json"
}

# ─── security round 1: github (S-M9) ────────────────────────────────────────

# _rc_json ARGV… — разовая команда с --json; конверт в output, журнал отдельно.
_rc_json() {
    bats_require_minimum_version 1.5.0
    run --separate-stderr "$APP/remote-control-essence.sh" "$@" --json < /dev/null
}

@test "refused first connect plan never creates the missing repository" {
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"
    local config_dir="$HOME/.config/remote-control-essence" token

    _rc_json source github-connect --login test-owner --create-repo --storage none
    [ "$(jq -r '.error.code' <<< "$output")" = confirmation_required ]
    jq -e '.error.plan | index("Будет создан приватный репозиторий.") and
        any(.[]; startswith("Пароли SSH и ключи будут храниться в GitHub без шифрования"))' <<< "$output"
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 0 ]] || return 1
    [[ ! -e "$config_dir" ]] || return 1

    token=$(jq -r '.error.plan_token' <<< "$output")
    _rc_json source github-connect --login test-owner --create-repo --storage none --yes --plan-token "$token"
    [ "$(jq -r '.ok' <<< "$output")" = true ]
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 1 ]] || return 1
    jq -e '.type == "github"' "$config_dir/source.json"
}

@test "change-account plans privatization and foreign-file removal before any write" {
    _prepare_alternate_remote
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    _connect_github --storage none
    assert_success
    local seed="$BATS_TEST_TMPDIR/alternate-seed" config_dir="$HOME/.config/remote-control-essence"
    local a_head b_head source_hash token
    printf 'foreign\n' > "$seed/README.md"
    git -C "$seed" add README.md && git -C "$seed" commit -qm foreign && git -C "$seed" push -q origin main || return 1
    a_head=$(git --git-dir="$REMOTE" rev-parse main)
    b_head=$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)
    source_hash=$(_hash_file "$config_dir/source.json")
    export GH_PUBLIC_REPO=alternate-owner/essence-remote-control-config
    export GH_PRIVATE_MARKER="$BATS_TEST_TMPDIR/private-marker"

    # Решения по-прежнему раньше плана.
    _rc_json source github-change-account --login alternate-owner
    [ "$(jq -r '.error.code' <<< "$output")" = repo_private_required ]
    _rc_json source github-change-account --login alternate-owner --make-private
    [ "$(jq -r '.error.code' <<< "$output")" = target_replace_required ]
    _rc_json source github-change-account --login alternate-owner --make-private --replace-target
    [ "$(jq -r '.error.code' <<< "$output")" = storage_mode_required ]

    _rc_json source github-change-account --login alternate-owner --make-private --replace-target --storage none
    [ "$(jq -r '.error.code' <<< "$output")" = confirmation_required ]
    jq -e '.error.plan |
        index("Публичный репозиторий станет приватным.") and
        index("Из alternate-owner/essence-remote-control-config будут удалены все файлы (1); они останутся только в истории Git.") and
        any(.[]; startswith("Пароли SSH и ключи будут храниться в GitHub без шифрования"))' <<< "$output"
    ! grep -q '^repo edit ' "$GH_CALLS_FILE" || return 1
    [[ ! -e "$GH_PRIVATE_MARKER" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" rev-parse main)" == "$b_head" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    [[ "$(_hash_file "$config_dir/source.json")" == "$source_hash" ]] || return 1
    [[ ! -e "$config_dir/account-switch" ]] || return 1

    token=$(jq -r '.error.plan_token' <<< "$output")
    _rc_json source github-change-account --login alternate-owner --make-private --replace-target \
        --storage none --yes --plan-token "$token"
    [ "$(jq -r '.ok' <<< "$output")" = true ]
    [[ -e "$GH_PRIVATE_MARKER" ]] || return 1
    [[ "$(git --git-dir="$ALTERNATE_REMOTE" ls-tree -r --name-only main)" != *README.md* ]] || return 1
    git --git-dir="$ALTERNATE_REMOTE" show main:storage.json | jq -e '.encryption == "none"' >/dev/null
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$a_head" ]] || return 1
    jq -e '.repo == "alternate-owner/essence-remote-control-config"' "$config_dir/source.json"
}

# ─── round 2: github (connect, recovery, self) ──────────────────────────────

# In-process core (cmd_helper) on the local $REMOTE of setup(); the GitHub CLI is
# a function: the repository is private unless R2_PUBLIC=1 (until `repo edit`),
# `api user` fails with R2_API_FAIL=1.
_r2_core() {
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    BUILTIN_TEMPLATES_DIR="$PROJECT_ROOT/remote-control/templates"
    _github_ensure_deps() { return 0; }
    _github_prepare_account() { return 0; }
    _github_gh() {
        shift
        case "$1 $2" in
            "api user")
                [[ "${R2_API_FAIL:-0}" != 1 ]] || { printf 'connection timed out\n'; return 1; }
                printf 'test-owner\n' ;;
            "repo view")
                if [[ "${R2_PUBLIC:-0}" == 1 && ! -e "$BATS_TEST_TMPDIR/r2-privatized" ]]; then
                    printf '{"visibility":"PUBLIC"}\n'
                else
                    printf '{"visibility":"PRIVATE"}\n'
                fi ;;
            "repo edit") touch "$BATS_TEST_TMPDIR/r2-privatized" ;;
            *) return 1 ;;
        esac
    }
    load_fixture_config
    load_fixture_template
    open_local_session || return 1
    # Nodes would add SSH steps to the plan; these tests cover the source only.
    jq_w '.nodes = [] | .connections = [] | .clients |= map(select(.name != "my-pc"))'
}

# Local files the connect rollback must return (config, manifest, auth, source).
_r2_local_files() {
    local f
    for f in config.json manifest.json .auth source.json ssh/known_hosts; do
        printf '%s %s\n' "$f" "$([[ -f "$CONFIG_DIR/$f" ]] && cksum < "$CONFIG_DIR/$f" || echo absent)"
    done
}

_r2_connect() {
    run_cmd source github-connect --login test-owner --storage none --yes "$@"
    [ "$status" -eq 0 ] || { printf 'connect: %s\n' "$CMD_ENVELOPE"; return 1; }
}

@test "R2-L10: connect _required answers remove the cache paths they created" {
    _r2_core
    local before; before=$(_r2_local_files)
    run_cmd source github-connect --login test-owner
    [ "$(cmd_jq -r .error.code)" = storage_mode_required ]
    [ ! -e "$CONFIG_DIR/github-store.git" ] && [ ! -e "$CONFIG_DIR/github-sessions" ]
    [ ! -e "$CONFIG_DIR/credentials" ]
    [ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.github-enable.*')" ]
    [ "$(_r2_local_files)" = "$before" ]
}

@test "R2-L10: connect _required restores the refs of an existing cache store" {
    _r2_core
    local store="$CONFIG_DIR/github-store.git" tree commit refs
    git init -q --bare "$store"
    git --git-dir="$store" remote add origin "https://example.invalid/old.git"
    tree=$(printf '' | git --git-dir="$store" mktree)
    commit=$(printf 'local only\n' | git -c user.name=t -c user.email=t@e.invalid --git-dir="$store" commit-tree "$tree")
    git --git-dir="$store" update-ref refs/heads/main "$commit"
    refs=$(git --git-dir="$store" for-each-ref --format='%(objectname) %(refname)')
    run_cmd source github-connect --login test-owner
    [ "$(cmd_jq -r .error.code)" = storage_mode_required ]
    [ "$(git --git-dir="$store" for-each-ref --format='%(objectname) %(refname)')" = "$refs" ]
    [ "$(git --git-dir="$store" remote get-url origin)" = "https://example.invalid/old.git" ]
}

@test "R2-M11: connect failing after github_enable_local in a state_action step rolls back to local" {
    _r2_core
    local before; before=$(_r2_local_files)
    eval "_r2_orig_checkpoint() $(declare -f github_config_checkpoint | tail -n +2)"
    github_config_checkpoint() {
        [[ $# -gt 0 ]] || { _github_record_error x "injected post checkpoint"; return 1; }
        _r2_orig_checkpoint "$@"
    }
    run_cmd source github-connect --login test-owner --storage none --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq -r .error.code)" = source_failed ]
    [ "$CONFIG_SOURCE" = local ] && [ -z "$GITHUB_WORKTREE" ]
    [ "$_RC_LOCK_DEPTH" = 0 ] && [ "$_RC_LOCK_SESSION" = 0 ] && [ ! -d "$CONFIG_DIR/.rc-lock" ]
    [ "$RC_SESSION_OPEN" = 1 ] && [ "$RC_SESSION_AUTHORIZED" = 1 ]
    [ "$(_r2_local_files)" = "$before" ]
    [ ! -e "$CONFIG_DIR/github-runtime" ] && [ ! -e "$CONFIG_DIR/github-sessions" ]
    run_cmd group list
    [ "$status" -eq 0 ]
}

@test "R2-L13: connect to a public repository needs --make-private and privatizes after consent" {
    _r2_core
    R2_PUBLIC=1
    run_cmd source github-connect --login test-owner --storage none
    [ "$(cmd_jq -r .error.code)" = repo_private_required ]
    [ "$(cmd_jq -r .error.repo)" = test-owner/essence-remote-control-config ]
    run_cmd source github-connect --login test-owner --storage none --make-private
    [ "$(cmd_jq -r .error.code)" = confirmation_required ]
    cmd_jq -e '.error.plan | index("Публичный репозиторий станет приватным.")' >/dev/null
    [ ! -e "$BATS_TEST_TMPDIR/r2-privatized" ]
    run_cmd source github-connect --login test-owner --storage none --make-private --yes \
        --plan-token "$(cmd_jq -r .error.plan_token)"
    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/r2-privatized" ]
}

@test "R2-L13: connect --existing remote to a public repository privatizes only after consent" {
    _r2_core
    _r2_connect
    run_cmd source github-switch-local
    [ "$status" -eq 0 ]
    R2_PUBLIC=1
    run_cmd source github-connect --login test-owner --existing remote
    [ "$(cmd_jq -r .error.code)" = repo_private_required ]
    run_cmd source github-connect --login test-owner --existing remote --make-private
    [ "$(cmd_jq -r .error.code)" = confirmation_required ]
    cmd_jq -e '.error.plan | index("Публичный репозиторий станет приватным.")' >/dev/null
    [ ! -e "$BATS_TEST_TMPDIR/r2-privatized" ]
    run_cmd source github-connect --login test-owner --existing remote --make-private --yes \
        --plan-token "$(cmd_jq -r .error.plan_token)"
    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/r2-privatized" ]
    [ "$CONFIG_SOURCE" = github ]
}

@test "R2-H8: replace-with-local rc 3 closes the session so stale state cannot overwrite the publication" {
    _r2_core
    _r2_connect
    jq '.groups += [{"name":"LOCALONLY","template":"default.yaml"}]' "$CONFIG_DIR/config.json" \
        > "$BATS_TEST_TMPDIR/r2-config" && cp "$BATS_TEST_TMPDIR/r2-config" "$CONFIG_DIR/config.json"
    run_cmd source github-replace-with-local
    local token; token=$(cmd_jq -r .error.plan_token)
    eval "_r2_orig_materialize() $(declare -f _config_source_materialize_state | tail -n +2)"
    _config_source_materialize_state() {
        [[ -z "${R2_FAIL_MATERIALIZE:-}" ]] || { _github_record_error x "injected materialize"; return 1; }
        _r2_orig_materialize "$@"
    }
    R2_FAIL_MATERIALIZE=1 run_cmd source github-replace-with-local --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c .data)" = '{"published":true,"refreshed":false}' ]
    [ "$RC_SESSION_OPEN" = 0 ] && [ -z "$GITHUB_WORKTREE" ]
    run_cmd group add --name AFTER
    [ "$(cmd_jq -r .error.code)" = session_closed ]
    git --git-dir="$REMOTE" show main:config.json | jq -e '.groups | map(.name) | index("LOCALONLY")'
    run_cmd session open
    [ "$status" -eq 0 ]
    jq -e '.groups | map(.name) | index("LOCALONLY")' "$CONFIG_JSON"
}

@test "R2-L12: password-set failing after the .auth write restores the previous password" {
    _r2_core
    _r2_connect
    eval "_r2_orig_checkpoint() $(declare -f github_config_checkpoint | tail -n +2)"
    github_config_checkpoint() {
        [[ $# -gt 0 ]] || { _github_record_error x "injected checkpoint"; return 1; }
        _r2_orig_checkpoint "$@"
    }
    RC_REQUEST_SECRETS='{"password":"newpw"}'
    run_cmd self password-set
    [ "$status" -eq 1 ]
    [ ! -e "$CONFIG_DIR/.auth" ]
    jq -e '.access.script_password_hash == null' "$STATE_MANIFEST"
    [ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.auth.restore.*')" ]
    github_config_checkpoint() { _r2_orig_checkpoint "$@"; }
    RC_REQUEST_SECRETS='{"password":"newpw"}'
    run_cmd self password-set
    [ "$status" -eq 0 ]
    local hash; hash=$(cat "$CONFIG_DIR/.auth")
    github_config_checkpoint() {
        [[ $# -gt 0 ]] || { _github_record_error x "injected checkpoint"; return 1; }
        _r2_orig_checkpoint "$@"
    }
    RC_REQUEST_SECRETS='{"current-password":"newpw"}'
    run_cmd self password-remove --yes
    [ "$status" -eq 1 ]
    [ "$(cat "$CONFIG_DIR/.auth")" = "$hash" ]
}

@test "R2-L15: uninstall --remove-data plan warns about changes not sent to GitHub" {
    _r2_core
    _r2_connect
    _self_is_root() { return 0; }
    run_cmd self uninstall --remove-data
    ! cmd_jq -e '.error.plan | map(select(test("не отправленные в GitHub"))) | length > 0' >/dev/null
    R2_API_FAIL=1 run_cmd group add --name LAB
    [ "$GITHUB_SYNC_STATUS" = pending ]
    run_cmd self uninstall --remove-data
    [ "$(cmd_jq -r .error.code)" = confirmation_required ]
    cmd_jq -e '.error.plan | index("Изменения, не отправленные в GitHub, будут потеряны: сначала выполните source github-push.")' >/dev/null
}

# Real core/serve with official age and batchpass. No crypto test doubles here.
_real_age_spy() {
    local tool dir="$BATS_TEST_TMPDIR/age-spy"
    mkdir -p "$dir"
    export RC_TEST_AGE_ARGV_LOG="$BATS_TEST_TMPDIR/age-argv"
    export RC_TEST_AGE_ENV_LOG="$BATS_TEST_TMPDIR/age-environment"
    for tool in age age-keygen age-plugin-batchpass; do
        cat > "$dir/$tool" <<'EOF'
#!/bin/bash
printf '%s\0' "${0##*/}" "$@" >> "$RC_TEST_AGE_ARGV_LOG"
env >> "$RC_TEST_AGE_ENV_LOG"
if [[ "${0##*/}" == age && " $* " == *' -j batchpass '* && " $* " == *' -o '* ]]; then
    [[ "${AGE_PASSPHRASE_FD:-}" == 9 && -z "${AGE_PASSPHRASE:-}" && -z "${AGEDEBUG:-}" ]] || exit 94
    if IFS= read -r unexpected || [[ -n "$unexpected" ]]; then exit 95; fi
fi
exec "$RC_TEST_REAL_AGE_DIR/${0##*/}" "$@"
EOF
        chmod +x "$dir/$tool"
    done
    export AGE_BIN="$dir/age" AGE_KEYGEN_BIN="$dir/age-keygen"
}

_assert_real_age_secrets_hidden() {
    local secret
    for secret in "$@"; do
        [[ "$output$stderr" != *"$secret"* ]] || return 1
        ! grep -aFq -- "$secret" "$RC_TEST_AGE_ARGV_LOG" "$RC_TEST_AGE_ENV_LOG" || return 1
    done
}

@test "real age headless core: init saved-key reopen fetch rewrap close and password reopen" {
    _real_age_tools
    _real_age_spy
    _rc source init-local
    assert_success
    _age_headless '{"new-vault-password":"s-h3-old-sensitive"}' \
        source github-connect --login test-owner --storage age --remember-key --yes --json --secrets-stdin
    assert_success
    local root="$HOME/.config/remote-control-essence" before_recipient
    [ -f "$root/credentials/github-config.agekey" ]
    [ "$(_file_mode "$root/credentials/github-config.agekey")" = 600 ]
    before_recipient=$(git --git-dir="$REMOTE" show main:recipient.txt)
    [ "$(git --git-dir="$REMOTE" ls-tree -r --name-only main)" = $'recipient.txt\nstate.json.age\nstorage.json\nunlock.age' ]

    # A separate process proves the remembered native key, not a pending password.
    _age_headless '{}' status --json
    assert_success
    jq -e '.ok and .data.source.type=="github"' <<< "$output"
    # EOF closes each serve process and its session; there is no session-close verb.
    _age_headless $'{"id":1,"argv":["session","open"]}\n{"id":2,"argv":["group","add","--name","AGE_REAL"]}\n{"id":3,"argv":["source","github-fetch"]}\n{"id":4,"argv":["source","github-rewrap-password"],"secrets":{"vault-password":"s-h3-old-sensitive","new-vault-password":"s-h3-new-sensitive"}}' serve
    assert_success
    jq -se '[.[] | select(has("ok"))] | length==4 and all(.ok)' <<< "$output" ||
        { printf '%s\n' "$output"; return 1; }
    _assert_real_age_secrets_hidden s-h3-old-sensitive s-h3-new-sensitive
    _age_headless $'{"id":1,"argv":["session","open"]}\n{"id":2,"argv":["status"]}' serve
    assert_success
    jq -se '[.[] | select(has("ok"))] | length==2 and all(.ok)' <<< "$output"
    jq -se 'any(.[]; .id==2 and .data.counts.groups==4)' <<< "$output"
    _assert_real_age_secrets_hidden s-h3-old-sensitive s-h3-new-sensitive
    [ "$(git --git-dir="$REMOTE" show main:recipient.txt)" = "$before_recipient" ]
    [ ! -e "$root/.rc-lock" ]
    rm "$root/credentials/github-config.agekey"

    _age_headless '{"id":1,"argv":["session","open"],"secrets":{"vault-password":"s-h3-old-sensitive"}}' serve
    assert_success
    jq -se 'any(.[]; .id==1 and .error.code=="vault_password_invalid")' <<< "$output"
    _age_headless $'{"id":1,"argv":["session","open"],"secrets":{"vault-password":"s-h3-new-sensitive"}}\n{"id":2,"argv":["source","github-fetch"]}\n{"id":3,"argv":["status"]}' serve
    assert_success
    jq -se '[.[] | select(has("ok"))] | length==3 and all(.ok)' <<< "$output" ||
        { printf '%s\n' "$output"; return 1; }
    _assert_real_age_secrets_hidden s-h3-old-sensitive s-h3-new-sensitive
    _age_headless $'{"id":1,"argv":["session","open"],"secrets":{"vault-password":"s-h3-new-sensitive"}}\n{"id":2,"argv":["status"]}' serve
    assert_success
    jq -se '[.[] | select(has("ok"))] | length==2 and all(.ok)' <<< "$output"
    jq -se 'any(.[]; .id==2 and .data.counts.groups==4)' <<< "$output"
    _assert_real_age_secrets_hidden s-h3-old-sensitive s-h3-new-sensitive
    [ ! -e "$root/credentials/github-config.agekey" ]
    [ ! -e "$root/.rc-lock" ]
    [ -z "$(find "$root" -name '.github-private.*' -o -name '.rewrap-*')" ]
}

# Only legacy artifact generation/decryption gets a tty: the application never does.
_legacy_age_artifact() {
    local secret="$1" mode="$2" input="$3" output_file="$4"
    local legacy="${RC_TEST_OLD_AGE:-}"
    [[ -n "$legacy" && -x "$legacy" ]] || skip "RC_TEST_OLD_AGE нужен для age 1.2.1 compatibility"
    run --separate-stderr python3 -c '
import os, pty, select, signal, sys, time
password = sys.stdin.buffer.read().rstrip(b"\r\n")
mode = sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], mode, "-o", sys.argv[4], sys.argv[3]])
data = b""
sent = 0
limit = 2 if mode == "-p" else 1
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], .1)[0]:
            continue
        try:
            part = os.read(fd, 65536)
        except OSError:
            break
        if not part:
            break
        data += part
        if sent < limit and ((sent == 0 and b"Enter passphrase" in data) or
                             (sent == 1 and b"Confirm passphrase" in data)):
            os.write(fd, password + b"\r")
            sent += 1
    else:
        os.killpg(pid, signal.SIGKILL)
        raise RuntimeError("legacy age timed out")
finally:
    os.close(fd)
_, status = os.waitpid(pid, 0)
assert password not in data, "legacy tty echoed its password"
sys.exit(os.waitstatus_to_exitcode(status))
' "$legacy" "$mode" "$input" "$output_file" <<< "$secret"
    assert_success
}

@test "real age headless core reads legacy age-p unlock and writes old-age-compatible rewrap" {
    _real_age_tools
    [[ -n "${RC_TEST_OLD_AGE:-}" && -x "$RC_TEST_OLD_AGE" ]] ||
        skip "RC_TEST_OLD_AGE нужен для age 1.2.1 compatibility"
    _real_age_spy
    _rc source init-local
    assert_success
    _age_headless '{"new-vault-password":"s-h3-legacy-old"}' \
        source github-connect --login test-owner --storage age --remember-key --yes --json --secrets-stdin
    assert_success
    local root="$HOME/.config/remote-control-essence" updater="$BATS_TEST_TMPDIR/legacy-updater"
    cp "$root/credentials/github-config.agekey" "$BATS_TEST_TMPDIR/identity"
    git --git-dir="$REMOTE" show main:unlock.age > "$BATS_TEST_TMPDIR/new.age"
    _legacy_age_artifact s-h3-legacy-old -d "$BATS_TEST_TMPDIR/new.age" "$BATS_TEST_TMPDIR/old-reader.key"
    cmp "$BATS_TEST_TMPDIR/identity" "$BATS_TEST_TMPDIR/old-reader.key"
    _legacy_age_artifact s-h3-legacy-old -p "$BATS_TEST_TMPDIR/identity" "$BATS_TEST_TMPDIR/legacy.age"
    git clone "$REMOTE" "$updater" >/dev/null
    cp "$BATS_TEST_TMPDIR/legacy.age" "$updater/unlock.age"
    git -C "$updater" -c user.name=test -c user.email=test@example.invalid commit -am legacy-unlock >/dev/null
    git -C "$updater" push origin main >/dev/null
    rm "$root/credentials/github-config.agekey"
    _age_headless $'{"id":1,"argv":["session","open"],"secrets":{"vault-password":"s-h3-legacy-old"}}\n{"id":2,"argv":["status"]}\n{"id":3,"argv":["source","github-rewrap-password"],"secrets":{"vault-password":"s-h3-legacy-old","new-vault-password":"s-h3-legacy-new"}}' serve
    assert_success
    jq -se '[.[] | select(has("ok"))] | length==3 and all(.ok)' <<< "$output" ||
        { printf '%s\n' "$output"; return 1; }
    _assert_real_age_secrets_hidden s-h3-legacy-old s-h3-legacy-new
    _age_headless $'{"id":1,"argv":["session","open"],"secrets":{"vault-password":"s-h3-legacy-new"}}\n{"id":2,"argv":["status"]}' serve
    assert_success
    jq -se '[.[] | select(has("ok"))] | length==2 and all(.ok)' <<< "$output" ||
        { printf '%s\n' "$output"; return 1; }
    _assert_real_age_secrets_hidden s-h3-legacy-old s-h3-legacy-new
    git --git-dir="$REMOTE" show main:unlock.age > "$BATS_TEST_TMPDIR/rewrapped.age"
    _legacy_age_artifact s-h3-legacy-new -d "$BATS_TEST_TMPDIR/rewrapped.age" "$BATS_TEST_TMPDIR/rewrapped.key"
    cmp "$BATS_TEST_TMPDIR/identity" "$BATS_TEST_TMPDIR/rewrapped.key"
}

@test "real age dependency failure returns deps_missing without changing logical state" {
    _real_age_tools
    _forbid_age_package_installers
    local bad="$BIN/unsupported-age" head root="$HOME/.config/remote-control-essence"
    printf '#!/bin/bash\n[[ "$1" == --version ]] && { echo v1.2.1; exit 0; }; exit 99\n' > "$bad"
    chmod +x "$bad"
    export AGE_BIN="$bad"
    head=$(git --git-dir="$REMOTE" rev-parse main)
    _age_headless '{"new-vault-password":"s-h3-deps-secret"}' \
        source github-connect --login test-owner --storage age --yes --json --secrets-stdin
    [ "$status" -eq 1 ]
    jq -e '.error.code=="deps_missing"' <<< "$output"
    [ -z "$(_config_tree)" ]
    [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$head" ]
    _age_headless '{}' session status --json
    assert_success
    jq -e '.data.configured==false' <<< "$output"
    _rc source init-local
    assert_success
    local before_config before_manifest before_secrets
    before_config=$(_hash_file "$root/config.json")
    before_manifest=$(_hash_file "$root/manifest.json")
    before_secrets=$(_hash_file "$root/secrets.json")
    _age_headless '{"new-vault-password":"s-h3-deps-secret"}' \
        source github-connect --login test-owner --storage age --yes --json --secrets-stdin
    [ "$status" -eq 1 ]
    jq -e '.error.code=="deps_missing"' <<< "$output"
    [ "$(_hash_file "$root/config.json")" = "$before_config" ]
    [ "$(_hash_file "$root/manifest.json")" = "$before_manifest" ]
    [ "$(_hash_file "$root/secrets.json")" = "$before_secrets" ]
    [ ! -e "$root/source.json" ]
    [ ! -e "$RC_TEST_FORBIDDEN_INSTALLS" ]
}

@test "real age bootstrap cache survives fresh required rollback and retry without downloading twice" {
    _real_age_tools
    [[ -f "${RC_TEST_AGE_ARCHIVE:-}" ]] || skip "RC_TEST_AGE_ARCHIVE нужен для bootstrap integration"
    unset AGE_BIN AGE_KEYGEN_BIN
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    export RC_TEST_AGE_DOWNLOADS="$BATS_TEST_TMPDIR/downloads"
    local tool
    for tool in age age-keygen; do
        printf '#!/bin/bash\n[[ "$1" == --version ]] && { echo v1.2.1; exit 0; }; exit 99\n' > "$BIN/$tool"
        chmod +x "$BIN/$tool"
    done
    cat > "$BIN/curl" <<'EOF'
#!/bin/bash
output="" url=""
while (( $# )); do
    case "$1" in
        -o|--output) output="$2"; shift 2 ;;
        https://github.com/FiloSottile/age/releases/download/*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$output" && -n "$url" ]] || exit 1
printf '%s\n' "$url" >> "$RC_TEST_AGE_DOWNLOADS"
cp "$RC_TEST_AGE_ARCHIVE" "$output"
EOF
    local cached="$XDG_CACHE_HOME/remote-control-essence/tools/age-v1.3.2/age"
    # Retry in the same serve process: it retains the resolved absolute AGE_BIN.
    _age_headless $'{"id":1,"argv":["source","github-connect","--login","test-owner","--storage","age","--yes"]}\n{"id":2,"argv":["session","status"]}\n{"id":3,"argv":["source","github-connect","--login","test-owner","--storage","age","--yes"],"secrets":{"new-vault-password":"s-h3-cache-password"}}\n{"id":4,"argv":["session","open"],"secrets":{"vault-password":"s-h3-cache-password"}}' serve
    assert_success
    jq -se 'any(.[]; .id==1 and .error.code=="new_vault_password_required") and
        any(.[]; .id==2 and .ok and .data.configured==false) and
        any(.[]; .id==3 and .ok) and any(.[]; .id==4 and .ok)' <<< "$output" ||
        { printf '%s\n' "$output"; return 1; }
    [ -x "$cached" ]
    [ "$(wc -l < "$RC_TEST_AGE_DOWNLOADS" | tr -d ' ')" = 1 ]
    _age_headless '{"id":1,"argv":["session","open"],"secrets":{"vault-password":"s-h3-cache-password"}}' serve
    assert_success
    jq -se 'any(.[]; .id==1 and .ok)' <<< "$output"
}

@test "real age missing plugin fails closed without network package manager or local publication" {
    _real_age_tools
    _forbid_age_package_installers
    local tools="$BATS_TEST_TMPDIR/missing-plugin" isolated="$BATS_TEST_TMPDIR/no-plugin-path"
    local directory executable name head original_path="$PATH"
    mkdir -p "$tools" "$isolated"
    ln -s "$AGE_BIN" "$tools/age"
    ln -s "$AGE_KEYGEN_BIN" "$tools/age-keygen"
    # Retain test/system executables but remove every plugin search location.
    while IFS= read -r directory; do
        [[ -d "$directory" ]] || continue
        for executable in "$directory"/*; do
            [[ -f "$executable" && -x "$executable" ]] || continue
            name=${executable##*/}
            [[ "$name" != age-plugin-batchpass ]] || continue
            [[ -e "$isolated/$name" ]] || ln -s "$executable" "$isolated/$name"
        done
    done < <(tr ':' '\n' <<< "$PATH")
    export AGE_BIN="$tools/age" AGE_KEYGEN_BIN="$tools/age-keygen"
    export PATH="$BIN:$isolated"
    head=$(git --git-dir="$REMOTE" rev-parse main)
    _age_headless '{"new-vault-password":"s-h3-missing-plugin"}' \
        source github-connect --login test-owner --storage age --yes --json --secrets-stdin
    export PATH="$original_path"
    [ "$status" -eq 1 ]
    jq -e '.error.code=="deps_missing"' <<< "$output"
    [ -z "$(_config_tree)" ]
    [ "$(git --git-dir="$REMOTE" rev-parse main)" = "$head" ]
    [ ! -e "$RC_TEST_FORBIDDEN_INSTALLS" ]
}

_forbid_age_package_installers() {
    local tool
    export PM=unsupported RC_TEST_FORBIDDEN_INSTALLS="$BATS_TEST_TMPDIR/forbidden-install"
    for tool in apt-get apt brew dnf yum pacman zypper apk pkg sudo; do
        cat > "$BIN/$tool" <<'EOF'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$RC_TEST_FORBIDDEN_INSTALLS"
exit 99
EOF
        chmod +x "$BIN/$tool"
    done
}

@test "real age rejects malformed recipient even with a valid saved native key" {
    _real_age_tools
    _rc source init-local
    assert_success
    _age_headless '{"new-vault-password":"s-h3-recipient-password"}' \
        source github-connect --login test-owner --storage age --remember-key --yes --json --secrets-stdin
    assert_success
    local root="$HOME/.config/remote-control-essence" updater="$BATS_TEST_TMPDIR/bad-recipient"
    local key_hash config_hash
    key_hash=$(_hash_file "$root/credentials/github-config.agekey")
    config_hash=$(_hash_file "$root/config.json")
    git clone "$REMOTE" "$updater" >/dev/null
    printf 'not-a-recipient\n' > "$updater/recipient.txt"
    git -C "$updater" -c user.name=test -c user.email=test@example.invalid commit -am malformed-recipient >/dev/null
    git -C "$updater" push origin main >/dev/null
    _age_headless '{}' status --json
    [ "$status" -eq 1 ]
    jq -e '.error.code=="github_format_invalid"' <<< "$output"
    [ "$(_hash_file "$root/credentials/github-config.agekey")" = "$key_hash" ]
    [ "$(_hash_file "$root/config.json")" = "$config_hash" ]
}
