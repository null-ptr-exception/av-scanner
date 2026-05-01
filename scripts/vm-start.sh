#!/bin/bash
#
# vm-start.sh - Start an existing VM
#
# Usage:
#   ./scripts/vm-start.sh              # start "av-scanner"
#   ./scripts/vm-start.sh my-vm        # start "my-vm"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/virsh.sh"

VM_NAME="${1:-av-scanner}"
SSH_KEY="${PROJECT_DIR}/.vms/id_ed25519"

if ! _virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "VM '$VM_NAME' not found. Run './scripts/vm-init.sh --name $VM_NAME' first."
    exit 1
fi

if virsh_is_running "$VM_NAME"; then
    echo "VM $VM_NAME already running at $(virsh_get_ip "$VM_NAME")"
    exit 0
fi

echo "Starting VM ${VM_NAME}..."
_virsh start "$VM_NAME"

echo "Waiting for IP..."
VM_IP=$(virsh_wait_ip "$VM_NAME")

echo "Waiting for SSH..."
virsh_wait_ssh "$VM_IP" "$SSH_KEY"

echo "VM ready: ssh -i $SSH_KEY ubuntu@$VM_IP"
