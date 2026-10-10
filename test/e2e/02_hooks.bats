#!/usr/bin/env bats
# Tests for Helm hook deployments (post-install, post-upgrade).
#
# Verifies that hooks actually deploy av-scanner to VMs, not just
# that Jobs complete. Reverts VMs to clean snapshot before install
# to ensure hooks are the sole deployment mechanism.
#
# Prerequisites: make env

setup_file() {
    load 'vm_helper'
    load 'test_helper'

    local project_root
    project_root="$(get_project_root)"

    _e2e_init
    local ssh_key="${project_root}/.vms/id_ed25519"

    # --- Revert VMs to base snapshots (truly clean state) ---
    e2e_vm_revert

    # --- Re-discover VM IPs ---
    export E2E_VM1_IP=$(virsh_get_ip "$E2E_VM1_NAME")
    export E2E_VM2_IP=$(virsh_get_ip "$E2E_VM2_NAME")
    export E2E_SSH_KEY="$ssh_key"
    echo "# VMs reverted: ${E2E_VM1_NAME}=${E2E_VM1_IP} (${E2E_VM1_ENGINE}), ${E2E_VM2_NAME}=${E2E_VM2_IP} (${E2E_VM2_ENGINE})"

    export MINIKUBE_PROFILE="av-scanner"
    export KUBE_CONTEXT="${MINIKUBE_PROFILE}"

    # --- Clean slate + deploy via skaffold (hooks-only, no controller) ---
    # skaffold runs with fd 3 closed: on the containerd runtime, minikube docker-env
    # spawns a long-lived ssh-agent that would otherwise hold bats' fd 3 open and hang the run
    (cd "$project_root" && skaffold delete --kube-context "$KUBE_CONTEXT" 3>&-) >&3 2>&1 || true

    echo "# Deploying via skaffold (e2e-hooks profile)..." >&3
    (cd "$project_root" && skaffold run -p e2e-hooks --kube-context "$KUBE_CONTEXT" 3>&-) >&3 2>&1

    echo "# Post-install hooks completed." >&3
}

teardown_file() {
    :
}

setup() {
    load 'test_helper'
    load 'vm_helper'
    _e2e_init
    export MINIKUBE_PROFILE="av-scanner"
    export KUBE_CONTEXT="${MINIKUBE_PROFILE}"
    export E2E_VM1_IP="${E2E_VM1_IP:-$(virsh_get_ip "$E2E_VM1_NAME")}"
    export E2E_VM2_IP="${E2E_VM2_IP:-$(virsh_get_ip "$E2E_VM2_NAME")}"
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

@test "post-install: each VM runs its configured engine" {
    local unit
    unit=$(vm_ssh "$E2E_VM1_IP" "systemctl cat av-scanner")
    echo "$unit" | grep -Fq "AV_ENGINE=${E2E_VM1_ENGINE}" || { echo "ERROR: vm1 is not ${E2E_VM1_ENGINE}"; false; }
    unit=$(vm_ssh "$E2E_VM2_IP" "systemctl cat av-scanner")
    echo "$unit" | grep -Fq "AV_ENGINE=${E2E_VM2_ENGINE}" || { echo "ERROR: vm2 is not ${E2E_VM2_ENGINE}"; false; }
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

    echo "# Running skaffold run -p e2e-hooks (upgrade)..." >&3
    (cd "$project_root" && skaffold run -p e2e-hooks --kube-context "$KUBE_CONTEXT" 3>&-) >&3 2>&1
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
