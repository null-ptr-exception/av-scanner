#!/bin/bash
#
# e2e-logs.sh - Print av-scanner and engine logs from the e2e VMs
#
# Usage:
#   ./scripts/e2e-logs.sh            # VMs from the current layout (see test/e2e/vm_helper.bash)
#
# Run after a failed e2e run, before the VMs are destroyed. Never fails:
# a VM that is down or unreachable is reported and skipped.
#
# Environment:
#   E2E_TM_VM    Trend Micro VM name (vm2); unset means vm2 is e2e-2 (ClamAV)
#   LOG_LINES    lines per log (default: 200)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/virsh.sh"

SSH_KEY="${PROJECT_DIR}/.vms/id_ed25519"
LINES="${LOG_LINES:-200}"

if [[ -n "${E2E_TM_VM:-}" ]]; then
    VMS=("e2e-1:clamav" "${E2E_TM_VM}:trendmicro")
else
    VMS=("e2e-1:clamav" "e2e-2:clamav")
fi

vm_ssh() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -i "$SSH_KEY" "ubuntu@${1}" "${@:2}"
}

for entry in "${VMS[@]}"; do
    name="${entry%%:*}"
    engine="${entry##*:}"
    echo "=================== ${name} (${engine}) ==================="
    if ! virsh_is_running "$name"; then
        echo "${name} is not running, skipped"
        continue
    fi
    ip=$(virsh_get_ip "$name")

    echo "----- journalctl -u av-scanner -----"
    vm_ssh "$ip" "sudo journalctl -u av-scanner --no-pager -n ${LINES}" || echo "(ssh failed)"

    if [[ "$engine" == "trendmicro" ]]; then
        # ds_am.log holds binary bytes; -a prints the text lines
        echo "----- /var/opt/ds_agent/diag/ds_am.log -----"
        vm_ssh "$ip" "sudo grep -a . /var/opt/ds_agent/diag/ds_am.log | tail -n ${LINES}" || echo "(ssh failed)"
    else
        echo "----- journalctl -u clamav-daemon -u clamav-clamonacc -----"
        vm_ssh "$ip" "sudo journalctl -u clamav-daemon -u clamav-clamonacc --no-pager -n ${LINES}" || echo "(ssh failed)"
        echo "----- /var/log/clamav/clamonacc.log -----"
        vm_ssh "$ip" "sudo tail -n ${LINES} /var/log/clamav/clamonacc.log" || echo "(ssh failed)"
    fi
done
exit 0
