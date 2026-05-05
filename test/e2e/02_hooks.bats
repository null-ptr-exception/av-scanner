#!/usr/bin/env bats
# Tests for Helm hook deployments (post-install, post-upgrade).
#
# Verifies that hooks actually deploy av-scanner to VMs, not just
# that Jobs complete. Cleans VM state before install to ensure
# hooks are the sole deployment mechanism.
#
# Requires: kind, docker, kubectl, helm, virsh
#
# Prerequisites:
#   ./scripts/vm-init.sh --name e2e --count 2

setup_file() {
    load 'vm_helper'
    load 'test_helper'

    local project_root
    project_root="$(get_project_root)"

    _e2e_init
    local ssh_key="${project_root}/.vms/id_ed25519"

    # --- Revert VMs to clean-base snapshot (truly clean state) ---
    for name in e2e-1 e2e-2; do
        echo "# Reverting $name to clean-base snapshot..."
        virsh_snapshot_revert "$name" "clean-base"
    done

    # --- Wait for VMs after revert ---
    for name in e2e-1 e2e-2; do
        local vm_ip
        vm_ip=$(virsh_wait_ip "$name")
        echo "# Waiting for SSH on $name ($vm_ip)..."
        virsh_wait_ssh "$vm_ip" "$ssh_key"
    done

    # --- Re-discover VM IPs ---
    export E2E_VM1_IP=$(virsh_get_ip "e2e-1")
    export E2E_VM2_IP=$(virsh_get_ip "e2e-2")
    export E2E_SSH_KEY="$ssh_key"
    echo "# VMs reverted: e2e-1=${E2E_VM1_IP}, e2e-2=${E2E_VM2_IP}"

    export KIND_CLUSTER="av-scanner-e2e"
    export KUBE_CONTEXT="kind-${KIND_CLUSTER}"
    kind export kubeconfig --name "$KIND_CLUSTER"

    # --- Clean Helm state ---
    helm uninstall av-scanner --kube-context "$KUBE_CONTEXT" -n av-scanner || true
    _kubectl delete namespace av-scanner --ignore-not-found
    _kubectl wait --for=delete namespace/av-scanner --timeout=120s 2>/dev/null || true
    _kubectl create namespace av-scanner

    # --- SSH key secret ---
    _kubectl -n av-scanner create secret generic av-scanner-ssh-key \
        --from-file=id_ed25519="${E2E_SSH_KEY}"

    # --- Inventory ---
    local inventory
    inventory=$(cat <<INVEOF
all:
  vars:
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ansible_ssh_private_key_file: /ssh/id_ed25519
  hosts:
    vm1:
      ansible_host: ${E2E_VM1_IP}
      ansible_user: ubuntu
    vm2:
      ansible_host: ${E2E_VM2_IP}
      ansible_user: ubuntu
INVEOF
)

    # --- Helm install (hooks do the deployment) ---
    echo "# Installing Helm chart (hooks enabled, controller disabled)..."
    helm upgrade --install av-scanner "${project_root}/charts/av-scanner" \
        --kube-context "$KUBE_CONTEXT" \
        -n av-scanner --create-namespace \
        --set controller.enabled=false \
        --set autoDeploy.enabled=true \
        --set preInstallCheck.enabled=true \
        --set image.registry="" \
        --set image.repository=av-scanner-deploy \
        --set image.tag=e2e \
        --set sshKey.existingSecret=av-scanner-ssh-key \
        --set-string "inventory=${inventory}" \
        --wait --timeout 600s

    echo "# Post-install hooks completed."
}

teardown_file() {
    :
}

setup() {
    load 'test_helper'
    load 'vm_helper'
    _e2e_init
    export KIND_CLUSTER="av-scanner-e2e"
    export KUBE_CONTEXT="kind-${KIND_CLUSTER}"
    export E2E_VM1_IP="${E2E_VM1_IP:-$(virsh_get_ip e2e-1)}"
    export E2E_VM2_IP="${E2E_VM2_IP:-$(virsh_get_ip e2e-2)}"
    export E2E_SSH_KEY="${E2E_SSH_KEY:-$(get_project_root)/.vms/id_ed25519}"
}

# ============================================
# Post-install hook tests
# ============================================

@test "post-install: deploy Job completed successfully" {
    local status
    status=$(_kubectl -n av-scanner get job av-scanner-deploy \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')
    [[ "$status" == "True" ]]
}

@test "post-install: deploy Job logs show both VMs targeted" {
    local logs
    logs=$(_kubectl -n av-scanner logs job/av-scanner-deploy)
    echo "$logs" | grep -q "PLAY RECAP"
    echo "$logs" | grep -Fq "vm1"
    echo "$logs" | grep -Fq "vm2"
}

@test "post-install: av-scanner service running on both VMs" {
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        local result
        result=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${vm_ip}" \
            "systemctl is-active av-scanner")
        [[ "$result" == "active" ]] || {
            echo "ERROR: av-scanner not active on ${vm_ip}, got: ${result}"; false
        }
    done
}

@test "post-install: health endpoint responds on both VMs" {
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        curl -sf --connect-timeout 5 "http://${vm_ip}:3000/api/v1/live" >/dev/null || {
            echo "ERROR: av-scanner not responding on ${vm_ip}"; false
        }
    done
}

@test "post-install: SA token deployed to both VMs" {
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        local exists
        exists=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${vm_ip}" \
            "test -f /etc/av-scanner/sa-token && echo yes || echo no")
        [[ "$exists" == "yes" ]] || {
            echo "ERROR: SA token not found on ${vm_ip}"; false
        }
    done
}

# ============================================
# Post-upgrade hook tests
# ============================================

@test "helm upgrade triggers post-upgrade hook" {
    local project_root
    project_root="$(get_project_root)"

    local inventory
    inventory=$(cat <<INVEOF
all:
  vars:
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ansible_ssh_private_key_file: /ssh/id_ed25519
  hosts:
    vm1:
      ansible_host: ${E2E_VM1_IP}
      ansible_user: ubuntu
    vm2:
      ansible_host: ${E2E_VM2_IP}
      ansible_user: ubuntu
INVEOF
)

    helm upgrade av-scanner "${project_root}/charts/av-scanner" \
        --kube-context "$KUBE_CONTEXT" \
        -n av-scanner \
        --set controller.enabled=false \
        --set autoDeploy.enabled=true \
        --set preInstallCheck.enabled=true \
        --set image.registry="" \
        --set image.repository=av-scanner-deploy \
        --set image.tag=e2e \
        --set sshKey.existingSecret=av-scanner-ssh-key \
        --set-string "inventory=${inventory}" \
        --wait --timeout 600s
}

@test "post-upgrade: deploy Job completed successfully" {
    local status
    status=$(_kubectl -n av-scanner get job av-scanner-deploy \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')
    [[ "$status" == "True" ]]
}

@test "post-upgrade: deploy Job logs show both VMs targeted" {
    local logs
    logs=$(_kubectl -n av-scanner logs job/av-scanner-deploy)
    echo "$logs" | grep -q "PLAY RECAP"
    echo "$logs" | grep -Fq "vm1"
    echo "$logs" | grep -Fq "vm2"
}

@test "post-upgrade: av-scanner still running after upgrade" {
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        curl -sf --connect-timeout 5 "http://${vm_ip}:3000/api/v1/live" >/dev/null || {
            echo "ERROR: av-scanner not responding on ${vm_ip} after upgrade"; false
        }
    done
}
