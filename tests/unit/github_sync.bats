#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'github-config.sh'
    export REMOTE="$BATS_TEST_TMPDIR/remote.git"
    export GITHUB_REMOTE="$REMOTE" GITHUB_STORE="$BATS_TEST_TMPDIR/store.git" GITHUB_SESSIONS_DIR="$BATS_TEST_TMPDIR/sessions"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git init --bare -b main "$REMOTE" >/dev/null
}
teardown() { teardown_test_env; }

_file_mode() {
    case "${OSTYPE:-}" in
        darwin*) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

@test "transport init does not persist metadata until explicit writer" {
    export GITHUB_OWNER=test-owner GITHUB_REPO_NAME=essence-remote-control-config
    rm -f "$CONFIG_DIR/source.json"

    github_sync_init
    [[ ! -e "$CONFIG_DIR/source.json" ]]

    github_source_metadata_write
    github_source_metadata_valid "$CONFIG_DIR/source.json"
    [[ "$(_file_mode "$CONFIG_DIR/source.json")" == 600 ]]
}


@test "transport creates independent session worktree" {
    github_sync_init
    [[ -d "$GITHUB_WORKTREE" ]]
    [[ -d "$GITHUB_STORE" ]]
    [[ "$(_file_mode "$GITHUB_WORKTREE")" == 700 ]]
}

@test "repeated transport initialization keeps the live session worktree" {
    github_sync_init
    local first_session="$GITHUB_SESSION_ID" first_worktree="$GITHUB_WORKTREE"
    run github_sync_init
    assert_success
    [[ "$GITHUB_SESSION_ID" == "$first_session" ]]
    [[ "$GITHUB_WORKTREE" == "$first_worktree" ]]
    [[ -d "$first_worktree" ]]
}

@test "flush commits with repository-local identity and reports pending offline" {
    github_sync_init
    rm -rf "$REMOTE"
    printf '{"storage_version":1,"encryption":"none"}\n' > "$GITHUB_WORKTREE/storage.json"
    git -C "$GITHUB_WORKTREE" add storage.json
    if github_sync_flush; then
        return 1
    fi
    [[ $GITHUB_SYNC_STATUS == pending ]]
    run git -C "$GITHUB_WORKTREE" log -1 --format='%an <%ae>'
    assert_output 'Essence Remote Control <remote-control@localhost>'
}

@test "pending offline commit survives a fresh session and retry pushes it" {
    github_sync_init
    printf '{"storage_version":1,"encryption":"none","revision":1}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.revision')" == 1 ]]

    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    git --git-dir="$GITHUB_STORE" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
    if github_sync_flush; then
        return 1
    fi
    [[ "$GITHUB_SYNC_STATUS" == pending ]]
    local pending_head
    pending_head=$(git --git-dir="$GITHUB_STORE" rev-parse main)

    github_config_close
    git --git-dir="$GITHUB_STORE" remote set-url origin "$REMOTE"
    github_sync_init
    [[ "$GITHUB_SYNC_STATUS" == pending ]]
    [[ "$(git -C "$GITHUB_WORKTREE" rev-parse HEAD)" == "$pending_head" ]]
    [[ "$(jq -r '.revision' "$GITHUB_WORKTREE/storage.json")" == 2 ]]

    github_sync_flush
    [[ "$GITHUB_SYNC_STATUS" == clean ]]
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.revision')" == 2 ]]
}

@test "divergent local and remote commits stop without overwriting local recovery" {
    github_sync_init
    printf '{"storage_version":1,"encryption":"none","revision":1}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush

    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    git --git-dir="$GITHUB_STORE" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
    run github_sync_flush
    assert_failure
    local pending_head
    pending_head=$(git --git-dir="$GITHUB_STORE" rev-parse main)

    local updater="$BATS_TEST_TMPDIR/updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    printf '{"storage_version":1,"encryption":"none","revision":3}\n' \
        > "$updater/storage.json"
    git -C "$updater" add storage.json
    git -C "$updater" commit -m remote-change >/dev/null
    git -C "$updater" push origin main >/dev/null

    github_config_close
    git --git-dir="$GITHUB_STORE" remote set-url origin "$REMOTE"
    if github_sync_init; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "сверка локальных и удалённых изменений" ]]
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$pending_head" ]]
    [[ "$(git --git-dir="$GITHUB_STORE" show main:storage.json | jq -r '.revision')" == 2 ]]
}

@test "onboarding archives divergent cached main and opens remote head" {
    local seed="$BATS_TEST_TMPDIR/seed"
    git init --bare -b main "$REMOTE" >/dev/null
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    printf '{"storage_version":1,"encryption":"none","revision":"base"}\n' \
        > "$seed/storage.json"
    git -C "$seed" add storage.json
    git -C "$seed" commit -m base >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null

    github_sync_init
    local base_oid
    base_oid=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    github_config_close
    local tree local_oid
    tree=$(git --git-dir="$GITHUB_STORE" rev-parse "$base_oid^{tree}")
    local_oid=$(printf 'offline local state\n' |
        git -c user.name='Essence Remote Control' \
            -c user.email='remote-control@localhost' \
            --git-dir="$GITHUB_STORE" commit-tree "$tree" -p "$base_oid")
    git --git-dir="$GITHUB_STORE" update-ref refs/heads/main "$local_oid"

    local updater="$BATS_TEST_TMPDIR/updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    printf '{"storage_version":1,"encryption":"none","revision":"remote"}\n' \
        > "$updater/storage.json"
    git -C "$updater" add storage.json
    git -C "$updater" commit -m remote >/dev/null
    git -C "$updater" push origin main >/dev/null
    local remote_oid
    remote_oid=$(git --git-dir="$REMOTE" rev-parse main)

    github_sync_init true onboarding
    [[ "$(git -C "$GITHUB_WORKTREE" rev-parse HEAD)" == "$remote_oid" ]]
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$remote_oid" ]]
    [[ "$(git --git-dir="$GITHUB_STORE" for-each-ref --format='%(objectname)' 'refs/archive/onboarding-*')" == "$local_oid" ]]
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_oid" ]]
}

@test "onboarding confirms empty remote and rejects network errors" {
    local seed="$BATS_TEST_TMPDIR/seed"
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    git -C "$seed" commit --allow-empty -m cached >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null

    github_sync_init
    local cached_oid
    cached_oid=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    github_config_close
    git --git-dir="$REMOTE" update-ref -d refs/heads/main

    github_sync_init true onboarding
    local empty_oid
    empty_oid=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    [[ "$empty_oid" != "$cached_oid" ]]
    [[ -z "$(git -C "$GITHUB_WORKTREE" ls-files)" ]]
    [[ "$(git --git-dir="$GITHUB_STORE" for-each-ref --format='%(objectname)' 'refs/archive/onboarding-*')" == "$cached_oid" ]]
    github_config_close

    local missing="$BATS_TEST_TMPDIR/missing.git" before
    before=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    GITHUB_REMOTE="$missing"
    if github_sync_init true onboarding; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "загрузка репозитория GitHub" ]]
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$before" ]]
}

@test "switching repository updates origin and never pushes new data to old remote" {
    github_sync_init
    printf '{"storage_version":1,"encryption":"none","revision":1}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush
    github_config_close

    local new_remote="$BATS_TEST_TMPDIR/new-remote.git"
    git init --bare "$new_remote" >/dev/null
    GITHUB_REMOTE="$new_remote"
    github_sync_init
    [[ "$(git --git-dir="$GITHUB_STORE" remote get-url origin)" == "$new_remote" ]]
    git --git-dir="$GITHUB_STORE" for-each-ref --format='%(refname)' \
        refs/archive | grep -q '^refs/archive/remote-switch-'

    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush
    [[ "$(git --git-dir="$new_remote" show main:storage.json | jq -r '.revision')" == 2 ]]
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.revision')" == 1 ]]
    [[ "$(git --git-dir="$new_remote" rev-list --count main)" == 2 ]]
    ! git --git-dir="$new_remote" show main^:storage.json >/dev/null 2>&1
}

@test "composed EXIT cleanup removes update temp and GitHub session secrets" {
    local meta="$BATS_TEST_TMPDIR/cleanup-meta"
    local child_config="$BATS_TEST_TMPDIR/child-config"
    local child_store="$BATS_TEST_TMPDIR/child-store.git"
    local child_sessions="$BATS_TEST_TMPDIR/child-sessions"
    run env PROJECT_ROOT="$PROJECT_ROOT" REMOTE="$REMOTE" \
        CHILD_CONFIG="$child_config" CHILD_STORE="$child_store" \
        CHILD_SESSIONS="$child_sessions" CLEANUP_META="$meta" \
        /bin/bash -c '
            source "$PROJECT_ROOT/common/common.sh"
            CONFIG_DIR="$CHILD_CONFIG"
            source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
            GITHUB_REMOTE="$REMOTE"
            GITHUB_STORE="$CHILD_STORE"
            GITHUB_SESSIONS_DIR="$CHILD_SESSIONS"
            github_sync_init
            identity="$CHILD_CONFIG/.unlock-check.test"
            printf identity > "$identity"
            GITHUB_IDENTITY="$identity"
            register_exit_cleanup github_config_close
            curl() { printf "%s\n" "{\"tag_name\":\"v1.2.3\"}"; }
            check_update_start
            printf "%s\n%s\n%s\n%s\n" \
                "$GITHUB_WORKTREE" "$GITHUB_SESSION_ID" "$identity" "$_UPDATE_TMP" \
                > "$CLEANUP_META"
        '
    assert_success

    local worktree session identity update_tmp
    {
        IFS= read -r worktree
        IFS= read -r session
        IFS= read -r identity
        IFS= read -r update_tmp
    } < "$meta"
    [[ ! -d "$worktree" ]]
    [[ ! -e "$identity" ]]
    [[ ! -e "$update_tmp" ]]
    ! git --git-dir="$child_store" show-ref --verify --quiet \
        "refs/heads/session/$session"
}

@test "config close removes session state and permits a fresh session" {
    github_sync_init
    local old_session="$GITHUB_SESSION_ID" old_worktree="$GITHUB_WORKTREE"
    git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session"

    github_config_close
    [[ -z "$GITHUB_SESSION_ID" ]]
    [[ -z "$GITHUB_WORKTREE" ]]
    [[ ! -d "$old_worktree" ]]
    ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session"

    github_sync_init
    [[ -n "$GITHUB_SESSION_ID" ]]
    [[ "$GITHUB_SESSION_ID" != "$old_session" ]]
    [[ -d "$GITHUB_WORKTREE" ]]
}

@test "status exposes clean default" {
    run github_sync_status
    assert_success
    assert_output 'clean'
}
