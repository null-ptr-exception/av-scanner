#!/bin/bash
# VM discovery helpers for BATS e2e tests.
#
# Two VMs:
#   vm1 = e2e-1                          ClamAV, created by make env / setup_suite
#   vm2 = e2e-2 (default)                ClamAV, created by make env / setup_suite
#       = $E2E_TM_VM (when set)          Trend Micro, pre-installed (see scripts/tm-vm.sh)
#
# Environment variables:
#   E2E_TM_VM=<name>  - use this pre-installed Trend Micro VM as vm2
#   E2E_CLEAN_ALL=1   - destroy the ClamAV VMs on teardown

E2E_VM1_NAME="e2e-1"
E2E_VM1_ENGINE="clamav"
if [[ -n "${E2E_TM_VM:-}" ]]; then
    E2E_VM2_NAME="$E2E_TM_VM"
    E2E_VM2_ENGINE="trendmicro"
else
    E2E_VM2_NAME="e2e-2"
    E2E_VM2_ENGINE="clamav"
fi
export E2E_VM1_NAME E2E_VM1_ENGINE E2E_VM2_NAME E2E_VM2_ENGINE

# ClamAV VMs, which make env / setup_suite create and e2e_vm_teardown destroys
e2e_clamav_vms() {
    echo "$E2E_VM1_NAME"
    [[ "$E2E_VM2_ENGINE" == "clamav" ]] && echo "$E2E_VM2_NAME"
    return 0
}

_e2e_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

_e2e_init() {
    source "$(_e2e_project_root)/scripts/lib/virsh.sh"
}

e2e_vm_setup() {
    _e2e_init
    local ssh_key="$(_e2e_project_root)/.vms/id_ed25519"

    for name in "$E2E_VM1_NAME" "$E2E_VM2_NAME"; do
        if ! virsh_is_running "$name"; then
            echo "# ERROR: VM $name not running. Run: make env"
            return 1
        fi
    done

    local vm1_ip vm2_ip
    vm1_ip=$(virsh_get_ip "$E2E_VM1_NAME")
    vm2_ip=$(virsh_get_ip "$E2E_VM2_NAME")

    if [[ -z "$vm1_ip" || -z "$vm2_ip" ]]; then
        echo "# ERROR: cannot get IPs for e2e VMs"
        return 1
    fi

    export E2E_VM1_IP="$vm1_ip"
    export E2E_VM2_IP="$vm2_ip"
    export E2E_SSH_KEY="$ssh_key"
    echo "# Using existing VMs: ${E2E_VM1_NAME}=${vm1_ip} (${E2E_VM1_ENGINE}), ${E2E_VM2_NAME}=${vm2_ip} (${E2E_VM2_ENGINE})"
}

# Revert both VMs to their base snapshots: ClamAV VMs to clean-base, the Trend
# Micro VM to tm-base (agent installed, nothing else).
e2e_vm_revert() {
    _e2e_init
    local project_root ssh_key name vm_ip
    project_root="$(_e2e_project_root)"
    ssh_key="${project_root}/.vms/id_ed25519"

    for name in $(e2e_clamav_vms); do
        echo "# Reverting ${name} to clean-base snapshot..."
        virsh_snapshot_revert "$name" "clean-base"
    done
    if [[ "$E2E_VM2_ENGINE" == "trendmicro" ]]; then
        "${project_root}/scripts/tm-vm.sh" prepare --revert
    fi

    for name in $(e2e_clamav_vms); do
        vm_ip=$(virsh_wait_ip "$name")
        echo "# Waiting for SSH on ${name} (${vm_ip})..."
        virsh_wait_ssh "$vm_ip" "$ssh_key"
    done
}

# ssh to a VM with the shared e2e key
vm_ssh() {
    local vm_ip="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -i "$E2E_SSH_KEY" "ubuntu@${vm_ip}" "$@"
}

e2e_vm_teardown() {
    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        _e2e_init
        local name
        for name in $(e2e_clamav_vms); do
            virsh_destroy_vm "$name"
        done
    fi
}
