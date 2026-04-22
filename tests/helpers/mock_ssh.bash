#!/bin/bash
# ─── SSH/SCP mock functions ────────────────────────────────────────────────────
# Source this after test_helper.bash to mock all remote operations.

SSH_RUN_CALLS=()
SSH_RUN_MOCK_OUTPUT=""
SSH_RUN_MOCK_EXIT=0

SCP_RUN_CALLS=()
UPLOAD_CALLS=()

SSHPASS_AVAILABLE=false

ssh_run() {
    # Strip -- separator like the real function
    local args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
    [[ "$1" == "--" ]] && shift
    SSH_RUN_CALLS+=("$*")
    if [[ -n "$SSH_RUN_MOCK_OUTPUT" ]]; then
        echo "$SSH_RUN_MOCK_OUTPUT"
    fi
    return "${SSH_RUN_MOCK_EXIT:-0}"
}

scp_run() {
    SCP_RUN_CALLS+=("$*")
    return 0
}

upload_scripts() {
    UPLOAD_CALLS+=("$*")
    return 0
}

# Reset all mock state
reset_ssh_mocks() {
    SSH_RUN_CALLS=()
    SSH_RUN_MOCK_OUTPUT=""
    SSH_RUN_MOCK_EXIT=0
    SCP_RUN_CALLS=()
    UPLOAD_CALLS=()
}
