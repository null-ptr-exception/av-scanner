#!/bin/bash
# Suite-level setup/teardown for all e2e BATS files.
#
# Runs once before any test file and once after all test files complete.
# Handles shared infra: VMs (snapshot restore), kind cluster, Istio,
# deployer image, kube-federated-auth.

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

    # --- Kind cluster ---
    export KIND_CLUSTER="av-scanner-e2e"
    export KUBE_CONTEXT="kind-${KIND_CLUSTER}"

    if ! kind get clusters | grep -q "^${KIND_CLUSTER}$"; then
        echo "# Creating kind cluster ${KIND_CLUSTER}..."
        kind create cluster --name "$KIND_CLUSTER" \
            --config "${project_root}/test/kind-config.yaml" \
            --wait 60s
    fi
    kind export kubeconfig --name "$KIND_CLUSTER"

    # --- Istio ingress gateway ---
    if ! kubectl --context "$KUBE_CONTEXT" get namespace istio-system &>/dev/null; then
        echo "# Installing Istio..."
        local istioctl_bin
        istioctl_bin=$(command -v istioctl || echo "/tmp/istioctl")
        if [[ ! -x "$istioctl_bin" ]]; then
            echo "# ERROR: istioctl not found"
            return 1
        fi
        "$istioctl_bin" install --context "$KUBE_CONTEXT" --set profile=default \
            --set values.gateways.istio-ingressgateway.type=NodePort -y
    fi
    kubectl --context "$KUBE_CONTEXT" -n istio-system patch svc istio-ingressgateway --type='json' \
        -p='[{"op":"replace","path":"/spec/ports/1/nodePort","value":30080}]'
    kubectl --context "$KUBE_CONTEXT" -n istio-system rollout status deployment/istio-ingressgateway --timeout=60s

    # --- Istio Gateway ---
    echo "# Reconciling Istio Gateway in istio-system..."
    kubectl --context "$KUBE_CONTEXT" apply -f - <<'GWEOF'
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: av-scanner
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*.corp.localhost"
GWEOF

    # --- Route from kind node to virbr0 ---
    local virbr0_subnet
    virbr0_subnet=$(ip -4 route show dev virbr0 proto kernel | awk '{print $1}')
    if [[ -n "$virbr0_subnet" ]]; then
        local kind_node="${KIND_CLUSTER}-control-plane"
        local host_gateway
        host_gateway=$(docker exec "$kind_node" ip route | awk '/default/{print $3}')
        if [[ -n "$host_gateway" ]]; then
            echo "# Adding route: ${virbr0_subnet} via ${host_gateway} in kind node"
            docker exec "$kind_node" ip route add "$virbr0_subnet" via "$host_gateway" || true
            docker exec "$kind_node" iptables -t nat -A POSTROUTING -d "$virbr0_subnet" -j MASQUERADE || true
        fi
    fi

    # --- Build and load deployer image ---
    local deploy_image="av-scanner-deploy:e2e"
    echo "# Pruning dangling Docker images..."
    docker image prune -f || true
    echo "# Building deployer image..."
    docker build -f "${project_root}/docker/Dockerfile" \
        -t "$deploy_image" "$project_root"
    kind load docker-image "$deploy_image" --name "$KIND_CLUSTER"

    # --- kube-federated-auth ---
    local kfa_image="ghcr.io/rophy/kube-federated-auth:3.4.2"
    if ! docker image inspect "$kfa_image" >/dev/null; then
        local kfa_dir="${project_root}/../kube-federated-auth"
        if [[ -d "$kfa_dir" ]]; then
            echo "# Building ${kfa_image} from local source..."
            docker build -t "$kfa_image" "$kfa_dir"
        else
            echo "# Pulling ${kfa_image}..."
            docker pull "$kfa_image"
        fi
    fi
    kind load docker-image "$kfa_image" --name "$KIND_CLUSTER"

    echo "# Deploying kube-federated-auth..."
    kubectl --context "$KUBE_CONTEXT" apply -f "${project_root}/test/kube-federated-auth.yaml"
    kubectl --context "$KUBE_CONTEXT" rollout status deployment/kube-federated-auth \
        -n kube-federated-auth --timeout=120s

    echo "# Suite setup complete."
}

teardown_suite() {
    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        echo "# Tearing down suite..."
        helm uninstall av-scanner --kube-context "kind-av-scanner-e2e" -n av-scanner || true
        kind delete cluster --name av-scanner-e2e || true

        local project_root
        project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        source "${project_root}/scripts/lib/virsh.sh"
        virsh_destroy_vm "e2e-1"
        virsh_destroy_vm "e2e-2"
    fi
}
