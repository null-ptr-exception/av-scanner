#!/bin/bash
# Suite-level setup/teardown for all e2e BATS files.
#
# Runs once before any test file and once after all test files complete.
# Handles VM snapshot management and e2e values file generation.
#
# Prerequisites: make env (VMs, minikube, Istio, kfa, SSH secret, skaffold-values.yaml)
# and the pre-installed Trend Micro VM ($E2E_TM_VM, see scripts/tm-vm.sh).

setup_suite() {
    local project_root
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    source "${project_root}/test/e2e/test_helper.bash"
    source "${project_root}/test/e2e/vm_helper.bash"

    # --- VMs: e2e-1 (ClamAV) reverted or created; Trend Micro VM reverted to tm-base ---
    _e2e_init
    if virsh_snapshot_exists "e2e-1" "clean-base"; then
        e2e_vm_revert
    else
        echo "# No snapshot for e2e-1, creating from scratch..."
        VM_MEMORY="${VM_MEMORY:-2048}" "${project_root}/scripts/vm-init.sh" --name e2e-1 --force
        "${project_root}/scripts/tm-vm.sh" prepare --revert
    fi

    # --- Generate .e2e-values.yaml for skaffold e2e profile ---
    local vm1_ip vm2_ip vm_gateway
    vm1_ip=$(virsh_get_ip "e2e-1")
    vm2_ip=$(virsh_get_ip "$E2E_TM_VM")
    vm_gateway=$(ip -4 addr show virbr0 | grep -oP '(\d+\.){3}\d+' | head -1)
    local kfa_endpoint="http://${vm_gateway}:${KFA_PORT:-31082}"

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
          - test-client/rate-client
          - test-client/concurrency-client
          - av-scanner/av-scanner
        rateLimits:
          overrides:
            test-client/rate-client:
              requestsPerMinute: 1
              burst: 1
            test-client/concurrency-client:
              maxConcurrent: 1
    children:
      av_scanner:
        hosts:
          vm1:
            ansible_host: ${vm1_ip}
            ansible_user: ubuntu
          vm2:
            ansible_host: ${vm2_ip}
            ansible_user: ubuntu
            av_engine: trendmicro
            tm_rts_log_path: ${TM_RTS_LOG_PATH:-/var/opt/ds_agent/diag/ds_am.log}

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
    fi
}
