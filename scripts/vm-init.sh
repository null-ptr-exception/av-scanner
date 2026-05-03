#!/bin/bash
#
# vm-init.sh - Create one or more VMs via libvirt/virsh
#
# Usage:
#   ./scripts/vm-init.sh                              # 1 VM named "av-scanner"
#   ./scripts/vm-init.sh --name molecule --count 2     # molecule-1, molecule-2
#   ./scripts/vm-init.sh --name av-scanner-e2e --force # destroy+recreate
#
# All VMs share a single SSH key at .vms/id_ed25519.
# virsh is the source of truth — no state files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/virsh.sh"

PREFIX="av-scanner"
COUNT=1
FORCE=0
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK="${VM_DISK:-10}"
VM_DIR="${PROJECT_DIR}/.vms"
SSH_KEY="${VM_DIR}/id_ed25519"

log_info()    { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

usage() {
    echo "Usage: $0 [--name PREFIX] [--count N] [--force]"
    echo ""
    echo "Options:"
    echo "  --name PREFIX   VM name prefix (default: av-scanner)"
    echo "  --count N       Number of VMs (default: 1)"
    echo "  --force         Destroy existing VMs without prompting"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)   PREFIX="$2"; shift 2 ;;
        --count)  COUNT="$2"; shift 2 ;;
        --force)  FORCE=1; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Build VM name list
vm_names=()
if [[ $COUNT -eq 1 ]]; then
    vm_names+=("$PREFIX")
else
    for i in $(seq 1 "$COUNT"); do
        vm_names+=("${PREFIX}-${i}")
    done
fi

main() {
    echo
    echo "=== VM Init ==="
    echo

    for cmd in virsh virt-install qemu-img cloud-localds; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "$cmd not found. Install with: sudo apt install libvirt-daemon-system virtinst qemu-utils cloud-image-utils"
            exit 1
        fi
    done

    # Check for existing VMs
    local existing=()
    for name in "${vm_names[@]}"; do
        if _virsh dominfo "$name" &>/dev/null; then
            existing+=("$name")
        fi
    done

    if [[ ${#existing[@]} -gt 0 ]]; then
        if [[ $FORCE -eq 1 ]]; then
            for name in "${existing[@]}"; do
                log_info "Destroying existing VM: $name"
                virsh_destroy_vm "$name"
            done
        else
            echo "Existing VMs found: ${existing[*]}"
            read -p "Delete and recreate? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                for name in "${existing[@]}"; do
                    virsh_destroy_vm "$name"
                done
            else
                echo "Aborted."
                exit 0
            fi
        fi
    fi

    echo "Creating ${#vm_names[@]} VM(s): ${vm_names[*]}"
    echo "Memory: ${VM_MEMORY}MB | CPUs: $VM_CPUS | Disk: ${VM_DISK}G"
    echo

    mkdir -p "$VM_DIR"

    # Shared SSH key
    virsh_ensure_ssh_key "$SSH_KEY"
    local ssh_pub
    ssh_pub=$(cat "${SSH_KEY}.pub")

    # Base image (download once)
    log_info "Preparing base image..."
    local base_image
    base_image=$(virsh_base_image "$VM_DIR")

    # Create all VMs
    for name in "${vm_names[@]}"; do
        log_info "Creating cloud-init seed for $name..."
        rm -f "${VM_DIR}/${name}-seed.img"
        local seed
        seed=$(virsh_create_seed "$name" "$ssh_pub" "$VM_DIR")

        log_info "Creating VM $name..."
        virsh_create_vm "$name" "$base_image" "$seed" "$VM_DIR" "$VM_MEMORY" "$VM_CPUS" "$VM_DISK"
    done

    # Wait for all VMs
    for name in "${vm_names[@]}"; do
        log_info "Waiting for $name IP..."
        local vm_ip
        vm_ip=$(virsh_wait_ip "$name")
        log_success "$name IP: $vm_ip"

        log_info "Waiting for $name SSH..."
        virsh_wait_ssh "$vm_ip" "$SSH_KEY"

        log_info "Waiting for $name cloud-init..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$SSH_KEY" "ubuntu@${vm_ip}" "cloud-init status --wait" || true

        log_success "$name ready"
    done

    # Print summary
    echo
    echo "============================================"
    echo "  All VMs Ready"
    echo "============================================"
    for name in "${vm_names[@]}"; do
        local ip
        ip=$(virsh_get_ip "$name")
        echo "  $name: ssh -i $SSH_KEY ubuntu@$ip"
    done
    echo "============================================"
}

main
