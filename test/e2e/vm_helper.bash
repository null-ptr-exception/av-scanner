#!/bin/bash
# VM discovery helpers for BATS e2e tests.
#
# Assumes VMs were created before running tests:
#   ./scripts/vm-init.sh --name e2e --count 2
#
# Environment variables:
#   E2E_CLEAN_ALL=1  - destroy VMs on teardown

_e2e_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

_e2e_init() {
    source "$(_e2e_project_root)/scripts/lib/virsh.sh"
}

e2e_vm_setup() {
    _e2e_init
    local ssh_key="$(_e2e_project_root)/.vms/id_ed25519"

    for name in e2e-1 e2e-2; do
        if ! virsh_is_running "$name"; then
            echo "# ERROR: VM $name not running. Run: ./scripts/vm-init.sh --name e2e --count 2"
            return 1
        fi
    done

    local vm1_ip vm2_ip
    vm1_ip=$(virsh_get_ip "e2e-1")
    vm2_ip=$(virsh_get_ip "e2e-2")

    if [[ -z "$vm1_ip" || -z "$vm2_ip" ]]; then
        echo "# ERROR: cannot get IPs for e2e VMs"
        return 1
    fi

    export E2E_VM1_IP="$vm1_ip"
    export E2E_VM2_IP="$vm2_ip"
    export E2E_SSH_KEY="$ssh_key"
    echo "# Using existing VMs: e2e-1=${vm1_ip}, e2e-2=${vm2_ip}"
}

e2e_vm_teardown() {
    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        _e2e_init
        virsh_destroy_vm "e2e-1"
        virsh_destroy_vm "e2e-2"
    fi
}
