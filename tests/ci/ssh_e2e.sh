#!/usr/bin/env bash
# Runs the real transport against a disposable, loopback-only OpenSSH server.
set -euo pipefail
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
container=''
image="essence-ssh-e2e-$(basename "$tmp" | tr '[:upper:]' '[:lower:]')"
cleanup() {
    local status=$?
    if [[ -n $container ]]; then
        if (( status != 0 )); then docker logs "$container" >&2 || true; fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    fi
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ssh-keygen -q -t ed25519 -N '' -f "$tmp/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/other_host_key"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/client_key"
docker build -t "$image" "$root/tests/ci/ssh-e2e" >/dev/null
container=$(docker run -d -p 127.0.0.1::2222 -v "$tmp:/fixture:ro" "$image")
address=$(docker port "$container" 2222/tcp)
port=${address##*:}
[[ $address == 127.0.0.1:* && $port =~ ^[0-9]+$ && $port -gt 1023 ]] || { echo "Invalid loopback mapping: $address" >&2; exit 1; }
# Docker's port proxy accepts TCP before sshd listens, so only an SSH banner proves readiness.
ssh_banner_ready() (
    exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
    IFS= read -r -t 1 banner <&3 || exit 1
    [[ $banner == SSH-* ]]
)
ready=false
for _ in {1..100}; do
    if ssh_banner_ready 2>/dev/null; then ready=true; break; fi
    if [[ $(docker inspect -f '{{.State.Running}}' "$container") != true ]]; then break; fi
    sleep 0.1
done
[[ $ready == true ]] || { echo 'OpenSSH fixture failed to start' >&2; exit 1; }
fingerprint=$(ssh-keygen -lf "$tmp/host_key.pub" -E sha256 | cut -d' ' -f2)
other_fingerprint=$(ssh-keygen -lf "$tmp/other_host_key.pub" -E sha256 | cut -d' ' -f2)
export E2E_SSH=1 E2E_SSH_HOST=127.0.0.1 E2E_SSH_PORT="$port" E2E_SSH_USER=e2e
export E2E_SSH_PASSWORD=essence-e2e-password E2E_SSH_KEY="$tmp/client_key"
export E2E_SSH_FINGERPRINT="$fingerprint" E2E_SSH_OTHER_FINGERPRINT="$other_fingerprint"
cd "$root/remote-control"
cargo test -p rc-core --test ssh_e2e --locked -- --nocapture
