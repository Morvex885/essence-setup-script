#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module state.sh
    source_module nodes.sh
    source_module ssh.sh
    source_module hardening.sh
    export CONFIG_SOURCE=github
    export SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    export SSH_IDENTITIES_DIR="$CONFIG_DIR/identities"
    export STATE_MANIFEST="$CONFIG_DIR/manifest.json"
    export SECRETS_JSON="$CONFIG_DIR/secrets.json"
    export RECOVERY_FIRST_ID=0123456789abcdef0123456789abcdef
    export RECOVERY_SECOND_ID=fedcba9876543210fedcba9876543210
    mkdir -p "$SSH_IDENTITIES_DIR" "$CONFIG_DIR/remote-keys"
    jq -n --arg first "$RECOVERY_FIRST_ID" --arg second "$RECOVERY_SECOND_ID" '
        {schema_version:2,nodes:[
            {id:$first,name:"first",ip:"192.0.2.1",port:22,user:"root",auth:"key",identity:"system",secret_id:null,aliases:{}},
            {id:$second,name:"second",ip:"192.0.2.2",port:22,user:"root",auth:"key",identity:"system",secret_id:null,aliases:{}}
        ],groups:[],clients:[],connections:[]}' > "$CONFIG_JSON"
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$SECRETS_JSON"
    jq -nc --arg first "$RECOVERY_FIRST_ID" --arg second "$RECOVERY_SECOND_ID" '
        {schema_version:2,minimum_remote_control_version:"0.0.0",access:{script_password_hash:null},templates:{},
         portability:{status:"needs_setup",issues:[
             {node_id:$first,reason:"missing_identity"},{node_id:$first,reason:"missing_host_key"},
             {node_id:$second,reason:"missing_identity"},{node_id:$second,reason:"missing_host_key"}]}}' > "$STATE_MANIFEST"
    printf 'original-known-hosts\n' > "$SSH_KNOWN_HOSTS"
    cp "$SSH_KNOWN_HOSTS" "$CONFIG_DIR/original-known-hosts"
    cp "$STATE_MANIFEST" "$CONFIG_DIR/original-manifest"
    cp "$CONFIG_JSON" "$CONFIG_DIR/original-config"
    export RECOVERY_REAL_CP="$(command -v cp)"
    export RECOVERY_REAL_RM="$(command -v rm)"
    export RECOVERY_REAL_MV="$(command -v mv)"
}

teardown() { teardown_test_env; }

# Only the selected rollback write fails; backup creation and other filesystem
# operations still use real binaries. Capture paths rather than guessing mktemp names.
_install_restore_faults() {
    cp() {
        if [[ "$1" == "$SSH_KNOWN_HOSTS" && "$2" == "$CONFIG_DIR"/.known-hosts.* ]]; then
            printf '%s\n' "$2" > "$CONFIG_DIR/known-backup-path"
        elif [[ "$1" == "$STATE_MANIFEST" && "$2" == "$CONFIG_DIR"/.manifest.* ]]; then
            printf '%s\n' "$2" > "$CONFIG_DIR/manifest-backup-path"
        fi
        if [[ "${RECOVERY_ARMED:-0}" == 1 ]]; then
            if [[ "$RECOVERY_FAULT" == copy-known && "$1" == "$CONFIG_DIR"/.known-hosts.* && "$2" == "$SSH_KNOWN_HOSTS" ]] ||
               [[ "$RECOVERY_FAULT" == copy-manifest && "$1" == "$CONFIG_DIR"/.manifest.* && "$2" == "$STATE_MANIFEST" ]]; then
                printf 'copy\n' > "$CONFIG_DIR/restore-fault-hit"
                return 79
            fi
        fi
        "$RECOVERY_REAL_CP" "$@"
    }
    rm() {
        local argument
        if [[ "${RECOVERY_ARMED:-0}" == 1 && "$RECOVERY_FAULT" == remove-known ]]; then
            for argument in "$@"; do
                if [[ "$argument" == "$SSH_KNOWN_HOSTS" ]]; then
                    printf 'remove\n' > "$CONFIG_DIR/restore-fault-hit"
                    return 79
                fi
            done
        fi
        "$RECOVERY_REAL_RM" "$@"
    }
    mv() {
        if [[ "$RECOVERY_BRANCH" == identity-save && "$1" == "$CONFIG_JSON".tmp.* && "$2" == "$CONFIG_JSON" ]]; then
            printf 'rejected\n' > "$CONFIG_DIR/identity-save-rejected"
            _arm_restore_fault
            return 77
        fi
        "$RECOVERY_REAL_MV" "$@"
    }
}

_arm_restore_fault() {
    RECOVERY_ARMED=1
    local backup
    case "$RECOVERY_FAULT" in
        missing-known)
            backup=$(cat "$CONFIG_DIR/known-backup-path") || return 1
            "$RECOVERY_REAL_RM" -f "$backup" || return 1
            printf '%s\n' "$backup" > "$CONFIG_DIR/missing-backup-path"
            ;;
        missing-manifest)
            backup=$(cat "$CONFIG_DIR/manifest-backup-path") || return 1
            "$RECOVERY_REAL_RM" -f "$backup" || return 1
            printf '%s\n' "$backup" > "$CONFIG_DIR/missing-backup-path"
            ;;
    esac
    return 0
}

_install_onboarding_transport() {
    _provision_portable_identity() {
        printf '%s\n' "$1" >> "$CONFIG_DIR/provision-attempts"
        if [[ "$RECOVERY_BRANCH" == provision-cancel && "$1" == "$RECOVERY_SECOND_ID" ]]; then
            _arm_restore_fault
            return 1
        fi
        printf 'fixture-private-key\n' > "$SSH_IDENTITIES_DIR/$1"
        printf 'fixture-public-key-%s\n' "$1" > "$SSH_IDENTITIES_DIR/$1.pub"
        printf 'installed\n' > "$CONFIG_DIR/remote-keys/$1"
        printf 'partially-updated-known-hosts\n' > "$SSH_KNOWN_HOSTS"
        NODE_IDENTITY="$1"
    }
    _ssh_pin_host_key() {
        printf '%s\n' "$NODE_ID" >> "$CONFIG_DIR/pin-attempts"
        if [[ "$RECOVERY_BRANCH" == pin-cancel ]]; then
            _arm_restore_fault
            return 1
        fi
        return 0
    }
    # Real key revocation loads the fixture public key and calls this sandbox
    # transport. No production revoke, config, manifest or node loader is replaced.
    ssh_run() {
        printf '%s\n' "$NODE_ID" >> "$CONFIG_DIR/revoked-ids"
        "$RECOVERY_REAL_RM" -f "$CONFIG_DIR/remote-keys/$NODE_ID"
    }
}

_run_onboarding_rollback() {
    case "$RECOVERY_BRANCH" in
        provision-cancel|pin-cancel) complete_portable_node_setup <<< $'y\n3' ;;
        identity-save) complete_portable_node_setup <<< $'y' ;;
    esac
}

_assert_onboarding_rollback() {
    export RECOVERY_BRANCH="$1" RECOVERY_FAULT="$2" RECOVERY_ARMED=0
    if [[ "$RECOVERY_FAULT" == remove-known ]]; then
        "$RECOVERY_REAL_RM" -f "$SSH_KNOWN_HOSTS"
    fi
    _install_restore_faults
    _install_onboarding_transport
    run _run_onboarding_rollback
    assert_failure
    [[ "$output" != *'[✓]'* ]]
    [[ "$output" != *fixture-private-key* && "$output" != *fixture-public-key* ]]
    cmp "$CONFIG_DIR/original-config" "$CONFIG_JSON"
    [[ "$(cat "$CONFIG_DIR/provision-attempts")" == "$RECOVERY_FIRST_ID"$'\n'"$RECOVERY_SECOND_ID" ]]
    if [[ "$RECOVERY_BRANCH" == provision-cancel ]]; then
        [[ ! -e "$CONFIG_DIR/pin-attempts" ]]
        [[ "$(cat "$CONFIG_DIR/revoked-ids")" == "$RECOVERY_FIRST_ID" ]]
    elif [[ "$RECOVERY_BRANCH" == pin-cancel ]]; then
        [[ "$(cat "$CONFIG_DIR/pin-attempts")" == "$RECOVERY_FIRST_ID" ]]
    else
        [[ -f "$CONFIG_DIR/identity-save-rejected" ]]
        [[ "$(cat "$CONFIG_DIR/pin-attempts")" == "$RECOVERY_FIRST_ID"$'\n'"$RECOVERY_SECOND_ID" ]]
    fi
    [[ ! -e "$SSH_IDENTITIES_DIR/$RECOVERY_FIRST_ID" && ! -e "$SSH_IDENTITIES_DIR/$RECOVERY_FIRST_ID.pub" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$RECOVERY_SECOND_ID" && ! -e "$SSH_IDENTITIES_DIR/$RECOVERY_SECOND_ID.pub" ]]
    [[ ! -e "$CONFIG_DIR/remote-keys/$RECOVERY_FIRST_ID" && ! -e "$CONFIG_DIR/remote-keys/$RECOVERY_SECOND_ID" ]]
    if [[ "$RECOVERY_BRANCH" != provision-cancel ]]; then
        [[ "$(cat "$CONFIG_DIR/revoked-ids")" == "$RECOVERY_FIRST_ID"$'\n'"$RECOVERY_SECOND_ID" ]]
    fi

    local known_backup="" manifest_backup
    [[ ! -f "$CONFIG_DIR/known-backup-path" ]] || known_backup=$(cat "$CONFIG_DIR/known-backup-path")
    manifest_backup=$(cat "$CONFIG_DIR/manifest-backup-path")
    case "$RECOVERY_FAULT" in
        none)
            cmp "$CONFIG_DIR/original-known-hosts" "$SSH_KNOWN_HOSTS"
            cmp "$CONFIG_DIR/original-manifest" "$STATE_MANIFEST"
            [[ ! -e "$known_backup" && ! -e "$manifest_backup" ]]
            ;;
        copy-known|copy-manifest)
            [[ "$(cat "$CONFIG_DIR/restore-fault-hit")" == copy ]]
            cmp "$CONFIG_DIR/original-known-hosts" "$known_backup"
            cmp "$CONFIG_DIR/original-manifest" "$manifest_backup"
            [[ "$output" == *"$known_backup"* && "$output" == *"$manifest_backup"* ]]
            if [[ "$RECOVERY_FAULT" == copy-known ]]; then
                [[ "$(cat "$SSH_KNOWN_HOSTS")" == partially-updated-known-hosts ]]
            fi
            ;;
        remove-known)
            [[ "$(cat "$CONFIG_DIR/restore-fault-hit")" == remove ]]
            [[ -z "$known_backup" ]]
            [[ "$(cat "$SSH_KNOWN_HOSTS")" == partially-updated-known-hosts ]]
            cmp "$CONFIG_DIR/original-manifest" "$manifest_backup"
            [[ "$output" == *"$manifest_backup"* ]]
            ;;
        missing-known)
            [[ "$(cat "$CONFIG_DIR/missing-backup-path")" == "$known_backup" && ! -e "$known_backup" ]]
            [[ "$(cat "$SSH_KNOWN_HOSTS")" == partially-updated-known-hosts ]]
            cmp "$CONFIG_DIR/original-manifest" "$manifest_backup"
            [[ "$output" == *"$known_backup"* && "$output" == *"$manifest_backup"* ]]
            ;;
        missing-manifest)
            [[ "$(cat "$CONFIG_DIR/missing-backup-path")" == "$manifest_backup" && ! -e "$manifest_backup" ]]
            [[ -f "$STATE_MANIFEST" ]]
            cmp "$CONFIG_DIR/original-known-hosts" "$known_backup"
            [[ "$output" == *"$known_backup"* && "$output" == *"$manifest_backup"* ]]
            ;;
    esac
}

@test "provision cancellation retains both backups when known_hosts restore fails" {
    _assert_onboarding_rollback provision-cancel copy-known
}

@test "host pin cancellation retains both backups when known_hosts restore fails" {
    _assert_onboarding_rollback pin-cancel copy-known
}

@test "identity save rejection retains both backups when known_hosts restore fails" {
    _assert_onboarding_rollback identity-save copy-known
}

@test "provision cancellation retains both backups when manifest restore fails" {
    _assert_onboarding_rollback provision-cancel copy-manifest
}

@test "host pin cancellation retains both backups when manifest restore fails" {
    _assert_onboarding_rollback pin-cancel copy-manifest
}

@test "identity save rejection retains both backups when manifest restore fails" {
    _assert_onboarding_rollback identity-save copy-manifest
}

@test "provision cancellation retains manifest backup when newly created known_hosts cannot be removed" {
    _assert_onboarding_rollback provision-cancel remove-known
}

@test "host pin cancellation retains manifest backup when newly created known_hosts cannot be removed" {
    _assert_onboarding_rollback pin-cancel remove-known
}

@test "identity save rejection retains manifest backup when newly created known_hosts cannot be removed" {
    _assert_onboarding_rollback identity-save remove-known
}

@test "provision cancellation preserves live known_hosts and manifest backup if expected host backup disappeared" {
    _assert_onboarding_rollback provision-cancel missing-known
}

@test "host pin cancellation preserves live known_hosts and manifest backup if expected host backup disappeared" {
    _assert_onboarding_rollback pin-cancel missing-known
}

@test "identity save rejection preserves live known_hosts and manifest backup if expected host backup disappeared" {
    _assert_onboarding_rollback identity-save missing-known
}

@test "provision cancellation preserves known_hosts backup if expected manifest backup disappeared" {
    _assert_onboarding_rollback provision-cancel missing-manifest
}

@test "host pin cancellation preserves known_hosts backup if expected manifest backup disappeared" {
    _assert_onboarding_rollback pin-cancel missing-manifest
}

@test "identity save rejection preserves known_hosts backup if expected manifest backup disappeared" {
    _assert_onboarding_rollback identity-save missing-manifest
}

@test "provision cancellation restores resources before retiring backups" {
    _assert_onboarding_rollback provision-cancel none
}

@test "host pin cancellation restores resources before retiring backups" {
    _assert_onboarding_rollback pin-cancel none
}

@test "identity save rejection restores resources before retiring backups" {
    _assert_onboarding_rollback identity-save none
}
