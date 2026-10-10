#!/bin/bash
# VM discovery helpers for BATS e2e tests.
#
# Two VMs, one per engine:
#   vm1 = e2e-1          ClamAV, created by make env / setup_suite
#   vm2 = $E2E_TM_VM     Trend Micro, pre-installed (see scripts/tm-vm.sh)
#
# Environment variables:
#   E2E_TM_VM=e2e-tm  - libvirt name of the Trend Micro VM
#   E2E_CLEAN_ALL=1   - destroy the ClamAV VM on teardown

E2E_VM1_ENGINE="clamav"
E2E_VM2_ENGINE="trendmicro"
export E2E_VM1_ENGINE E2E_VM2_ENGINE
export E2E_TM_VM="${E2E_TM_VM:-e2e-tm}"

_e2e_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

_e2e_init() {
    source "$(_e2e_project_root)/scripts/lib/virsh.sh"
}

e2e_vm_setup() {
    _e2e_init
    local ssh_key="$(_e2e_project_root)/.vms/id_ed25519"

    for name in e2e-1 "$E2E_TM_VM"; do
        if ! virsh_is_running "$name"; then
            echo "# ERROR: VM $name not running. Run: make env"
            return 1
        fi
    done

    local vm1_ip vm2_ip
    vm1_ip=$(virsh_get_ip "e2e-1")
    vm2_ip=$(virsh_get_ip "$E2E_TM_VM")

    if [[ -z "$vm1_ip" || -z "$vm2_ip" ]]; then
        echo "# ERROR: cannot get IPs for e2e VMs"
        return 1
    fi

    export E2E_VM1_IP="$vm1_ip"
    export E2E_VM2_IP="$vm2_ip"
    export E2E_SSH_KEY="$ssh_key"
    echo "# Using existing VMs: e2e-1=${vm1_ip} (clamav), ${E2E_TM_VM}=${vm2_ip} (trendmicro)"
}

# Revert both VMs to their base snapshots: e2e-1 to clean-base, the Trend Micro
# VM to tm-base (agent installed, nothing else).
e2e_vm_revert() {
    _e2e_init
    local project_root ssh_key
    project_root="$(_e2e_project_root)"
    ssh_key="${project_root}/.vms/id_ed25519"

    echo "# Reverting e2e-1 to clean-base snapshot..."
    virsh_snapshot_revert "e2e-1" "clean-base"
    "${project_root}/scripts/tm-vm.sh" prepare --revert

    local vm_ip
    vm_ip=$(virsh_wait_ip "e2e-1")
    echo "# Waiting for SSH on e2e-1 (${vm_ip})..."
    virsh_wait_ssh "$vm_ip" "$ssh_key"
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
        virsh_destroy_vm "e2e-1"
    fi
}
