#!/bin/bash
# Suite-level setup/teardown for all e2e BATS files.
#
# Runs once before any test file and once after all test files complete.
# Handles VM snapshot management and e2e values file generation.
#
# Prerequisites: make env (VMs, minikube, Istio, kfa, SSH secret, skaffold-values.yaml)

setup_suite() {
    local project_root
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    source "${project_root}/test/e2e/test_helper.bash"
    source "${project_root}/test/e2e/vm_helper.bash"

    # --- VMs: revert to clean-base snapshot or create from scratch ---
    _e2e_init
    local ssh_key="${project_root}/.vms/id_ed25519"

    for name in e2e-1 e2e-2; do
        if virsh_snapshot_exists "$name" "clean-base"; then
            echo "# Reverting $name to clean-base snapshot..."
            virsh_snapshot_revert "$name" "clean-base"
        else
            echo "# No snapshot for $name, destroying and recreating..."
            virsh_destroy_vm "$name"
        fi
    done

    # If VMs don't exist (no snapshot path), create them
    local need_create=false
    for name in e2e-1 e2e-2; do
        if ! _virsh dominfo "$name" &>/dev/null; then
            need_create=true
            break
        fi
    done

    if [[ "$need_create" == "true" ]]; then
        echo "# Creating e2e VMs from scratch..."
        VM_MEMORY="${VM_MEMORY:-2048}" "${project_root}/scripts/vm-init.sh" \
            --name e2e --count 2 --force
    fi

    # Wait for VMs to be ready
    for name in e2e-1 e2e-2; do
        local vm_ip
        vm_ip=$(virsh_wait_ip "$name")
        echo "# Waiting for SSH on $name ($vm_ip)..."
        virsh_wait_ssh "$vm_ip" "$ssh_key"
    done

    # --- Generate .e2e-values.yaml for skaffold e2e profile ---
    local vm1_ip vm2_ip vm_gateway
    vm1_ip=$(virsh_get_ip "e2e-1")
    vm2_ip=$(virsh_get_ip "e2e-2")
    vm_gateway=$(ip -4 addr show virbr0 | grep -oP '(\d+\.){3}\d+' | head -1)
    local kfa_endpoint="http://${vm_gateway}:30082"

    cat > "${project_root}/.e2e-values.yaml" <<VALEOF
inventory: |
  all:
    vars:
      ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      ansible_ssh_private_key_file: /ssh/id_ed25519
      auth_enabled: "true"
      k8s_api_endpoint: "${kfa_endpoint}"
      auth_allowlist_content: |
        allowlist:
          - test-client/scanner-client
          - av-scanner/av-scanner
    children:
      av_scanner:
        hosts:
          vm1:
            ansible_host: ${vm1_ip}
            ansible_user: ubuntu
          vm2:
            ansible_host: ${vm2_ip}
            ansible_user: ubuntu

istio:
  enabled: true
  gatewayRef: istio-system/av-scanner
  virtualServiceHost: av-scanner.corp.localhost
  serviceEntryHost: av-scanner.internal
  endpoints:
    - address: ${vm1_ip}
    - address: ${vm2_ip}
VALEOF
    echo "# Generated .e2e-values.yaml (kfa_endpoint=${kfa_endpoint})"

    echo "# Suite setup complete."
}

teardown_suite() {
    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        echo "# Tearing down suite..."
        helm uninstall av-scanner --kube-context "av-scanner" -n av-scanner || true
        minikube delete --profile av-scanner || true

        local project_root
        project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        source "${project_root}/scripts/lib/virsh.sh"
        virsh_destroy_vm "e2e-1"
        virsh_destroy_vm "e2e-2"
    fi
}
