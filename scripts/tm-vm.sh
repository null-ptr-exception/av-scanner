#!/bin/bash
#
# tm-vm.sh - Prepare the pre-installed Trend Micro VM for e2e/dev use
#
# Usage:
#   ./scripts/tm-vm.sh prepare            # wait for agent, authorize .vms key
#   ./scripts/tm-vm.sh prepare --revert   # revert to tm-base snapshot first
#   ./scripts/tm-vm.sh ip                 # print the VM's IP
#
# The VM is never created or destroyed by this repo: it needs a registered
# Trend Micro agent (see docs/development.md). It may live outside this
# checkout with its own SSH key, so prepare adds .vms/id_ed25519.pub (the key
# the cluster and tests use) to its authorized_keys after every revert.
#
# Environment:
#   E2E_TM_VM        libvirt VM name (default: e2e-tm)
#   E2E_TM_SSH_KEY   key the VM was built with (default: .vms/id_ed25519)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/virsh.sh"

TM_VM="${E2E_TM_VM:-e2e-tm}"
TM_KEY="${E2E_TM_SSH_KEY:-${PROJECT_DIR}/.vms/id_ed25519}"
RUN_KEY="${PROJECT_DIR}/.vms/id_ed25519"

tm_ssh() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -i "$TM_KEY" "ubuntu@${TM_IP}" "$@"
}

require_vm() {
    if ! _virsh dominfo "$TM_VM" >/dev/null; then
        echo "ERROR: Trend Micro VM '${TM_VM}' not found. Build it as described in docs/development.md," >&2
        echo "       or set E2E_TM_VM to its libvirt name." >&2
        exit 1
    fi
}

cmd_ip() {
    require_vm
    virsh_get_ip "$TM_VM"
}

cmd_prepare() {
    local revert=0
    [[ "${1:-}" == "--revert" ]] && revert=1
    require_vm

    if [[ $revert -eq 1 ]] && virsh_snapshot_exists "$TM_VM" "tm-base"; then
        echo "# Reverting ${TM_VM} to tm-base snapshot..."
        virsh_snapshot_revert "$TM_VM" "tm-base"
    elif ! virsh_is_running "$TM_VM"; then
        _virsh start "$TM_VM"
    fi

    TM_IP=$(virsh_wait_ip "$TM_VM")
    echo "# Waiting for SSH on ${TM_VM} (${TM_IP})..."
    virsh_wait_ssh "$TM_IP" "$TM_KEY"

    if [[ "$TM_KEY" != "$RUN_KEY" ]]; then
        echo "# Authorizing ${RUN_KEY}.pub on ${TM_VM}..."
        # Key goes over stdin, so nothing in it needs quoting
        tm_ssh 'k=$(cat); grep -qxF "$k" ~/.ssh/authorized_keys || echo "$k" >> ~/.ssh/authorized_keys' < "${RUN_KEY}.pub"
    fi

    # After boot or revert the agent needs ~10-20s before it accepts scans
    echo "# Waiting for Trend Micro agent on ${TM_VM}..."
    local code="" i
    for i in $(seq 1 36); do
        # || true: an ssh failure leaves code empty and retries instead of exiting
        code=$(tm_ssh 'echo ok > /tmp/tm-ready.txt; sudo /opt/ds_agent/dsa_scan --target /tmp/tm-ready.txt --json >/dev/null; echo $?; rm -f /tmp/tm-ready.txt') || true
        if [[ "$code" == "0" ]]; then
            echo "# Trend Micro agent ready on ${TM_VM}"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: dsa_scan on ${TM_VM} still exits ${code}" >&2
    echo "  249: enable 'Allow agent to trigger or cancel a manual scan' (policy > Anti-Malware > General)" >&2
    echo "  250: set a Manual Scan configuration    251: Anti-Malware is off (check the endpoint's policy)" >&2
    echo "  253: agent not running" >&2
    exit 1
}

case "${1:-}" in
    ip)      cmd_ip ;;
    prepare) shift; cmd_prepare "$@" ;;
    *) echo "Usage: $0 {prepare [--revert]|ip}"; exit 1 ;;
esac
