#!/usr/bin/env bats
# End-to-end tests for av-scanner
#
# Deploys the controller Deployment into a kind cluster, runs molecule
# inside it to deploy av-scanner to 2 VMs, then tests scan and auth
# behavior from outside.
#
# Requires: kind, docker, kubectl, helm, virsh
#
# Prerequisites:
#   ./scripts/vm-init.sh --name e2e --count 2
#
# Env vars:
#   E2E_CLEAN_ALL=1   - delete all artifacts (VMs, kind cluster) on teardown

setup_file() {
    load 'vm_helper'
    load 'test_helper'

    local project_root
    project_root="$(get_project_root)"

    # --- VMs ---
    e2e_vm_setup

    # --- Kind cluster ---
    export KIND_CLUSTER="av-scanner-e2e"
    export KUBE_CONTEXT="kind-${KIND_CLUSTER}"

    if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
        echo "# Creating kind cluster ${KIND_CLUSTER}..."
        kind create cluster --name "$KIND_CLUSTER" \
            --config "${project_root}/test/kind-config.yaml" \
            --wait 60s
    fi
    kind export kubeconfig --name "$KIND_CLUSTER" 2>/dev/null

    # --- Istio ingress gateway ---
    if ! _kubectl get namespace istio-system &>/dev/null; then
        echo "# Installing Istio..."
        local istioctl_bin
        istioctl_bin=$(command -v istioctl 2>/dev/null || echo "/tmp/istioctl")
        if [[ ! -x "$istioctl_bin" ]]; then
            echo "# ERROR: istioctl not found"
            false
        fi
        "$istioctl_bin" install --context "$KUBE_CONTEXT" --set profile=default \
            --set values.gateways.istio-ingressgateway.type=NodePort -y
    fi
    _kubectl -n istio-system patch svc istio-ingressgateway --type='json' \
        -p='[{"op":"replace","path":"/spec/ports/1/nodePort","value":30080}]'
    _kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=60s

    # --- Istio Gateway (lives in istio-system with the ingress gateway pods) ---
    echo "# Reconciling Istio Gateway in istio-system..."
    _kubectl apply -f - <<'GWEOF'
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

    # --- Route from kind node to virbr0 so pods can SSH to VMs ---
    local virbr0_subnet
    virbr0_subnet=$(ip -4 route show dev virbr0 proto kernel | awk '{print $1}')
    if [[ -n "$virbr0_subnet" ]]; then
        local kind_node="${KIND_CLUSTER}-control-plane"
        local host_gateway
        host_gateway=$(docker exec "$kind_node" ip route | awk '/default/{print $3}')
        if [[ -n "$host_gateway" ]]; then
            echo "# Adding route: ${virbr0_subnet} via ${host_gateway} in kind node"
            docker exec "$kind_node" ip route add "$virbr0_subnet" via "$host_gateway" 2>/dev/null || true
            docker exec "$kind_node" iptables -t nat -A POSTROUTING -d "$virbr0_subnet" -j MASQUERADE 2>/dev/null || true
        fi
    fi

    # --- Build and load deployer image ---
    local deploy_image="av-scanner-deploy:e2e"
    echo "# Building deployer image..."
    docker build -f "${project_root}/docker/Dockerfile" \
        -t "$deploy_image" "$project_root" >/dev/null 2>&1
    kind load docker-image "$deploy_image" --name "$KIND_CLUSTER" 2>/dev/null || true

    # --- kube-federated-auth ---
    local kfa_image="ghcr.io/rophy/kube-federated-auth:3.4.2"
    if ! docker image inspect "$kfa_image" >/dev/null 2>&1; then
        local kfa_dir="${project_root}/../kube-federated-auth"
        if [[ -d "$kfa_dir" ]]; then
            echo "# Building ${kfa_image} from local source..."
            docker build -t "$kfa_image" "$kfa_dir"
        else
            echo "# Pulling ${kfa_image}..."
            docker pull "$kfa_image"
        fi
    fi
    kind load docker-image "$kfa_image" --name "$KIND_CLUSTER" 2>/dev/null || true

    echo "# Deploying kube-federated-auth..."
    _kubectl apply -f "${project_root}/test/kube-federated-auth.yaml"
    _kubectl rollout status deployment/kube-federated-auth \
        -n kube-federated-auth --timeout=120s

    # --- kube-federated-auth endpoint as seen from the VMs ---
    local vm_gateway
    vm_gateway=$(ip -4 addr show virbr0 | grep -oP '(\d+\.){3}\d+' | head -1)
    local kfa_endpoint="http://${vm_gateway}:30082"

    # --- Clean slate for Helm ---
    helm uninstall av-scanner --kube-context "$KUBE_CONTEXT" -n av-scanner 2>/dev/null || true
    _kubectl delete namespace av-scanner --ignore-not-found 2>/dev/null || true
    _kubectl create namespace av-scanner

    # --- SSH key secret ---
    _kubectl -n av-scanner create secret generic av-scanner-ssh-key \
        --from-file=id_ed25519="${E2E_SSH_KEY}"

    # --- Helm install with controller ---
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

    echo "# Installing Helm chart..."
    helm upgrade --install av-scanner "${project_root}/charts/av-scanner" \
        --kube-context "$KUBE_CONTEXT" \
        -n av-scanner --create-namespace \
        --set controller.enabled=true \
        --set image.registry="" \
        --set image.repository=av-scanner-deploy \
        --set image.tag=e2e \
        --set sshKey.existingSecret=av-scanner-ssh-key \
        --set-string "inventory=${inventory}" \
        --set istio.enabled=true \
        --set istio.gatewayRef=istio-system/av-scanner \
        --set "istio.workloadEntries[0].name=vm1" \
        --set "istio.workloadEntries[0].address=${E2E_VM1_IP}" \
        --set "istio.workloadEntries[1].name=vm2" \
        --set "istio.workloadEntries[1].address=${E2E_VM2_IP}" \
        --wait --timeout 120s

    # --- Test service accounts ---
    _kubectl create namespace test-client 2>/dev/null || true
    _kubectl -n test-client create serviceaccount scanner-client 2>/dev/null || true

    # --- Mint SA token inside controller pod ---
    local controller_pod
    controller_pod=$(_kubectl -n av-scanner get pod \
        -l app.kubernetes.io/name=av-scanner-controller \
        -o jsonpath='{.items[0].metadata.name}')

    echo "# Minting SA token inside controller pod..."
    _kubectl -n av-scanner exec "$controller_pod" -- bash -c '
        kubectl create token av-scanner -n av-scanner --duration=1h > /tmp/sa-token
        chmod 600 /tmp/sa-token
    '

    # --- Run molecule inside controller pod ---
    echo "# Running molecule inside controller pod..."

    # Verify network connectivity from kind node and controller pod to VMs
    local kind_node="${KIND_CLUSTER}-control-plane"
    echo "# DEBUG: kind node routes:"
    docker exec "$kind_node" ip route 2>&1 | while IFS= read -r l; do echo "# $l"; done
    echo "# DEBUG: host nftables ruleset:"
    sudo nft list ruleset 2>&1 | while IFS= read -r l; do echo "# $l"; done || true
    echo "# DEBUG: host iptables FORWARD chain (first 20 rules):"
    sudo iptables -L FORWARD -n -v 2>&1 | head -25 | while IFS= read -r l; do echo "# $l"; done || true

    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        echo "# Testing SSH to ${vm_ip} from controller pod..."
        if ! _kubectl -n av-scanner exec "$controller_pod" -- \
            ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 -i /ssh/id_ed25519 \
                "ubuntu@${vm_ip}" "echo ok" 2>&1 | while IFS= read -r l; do echo "# $l"; done; then
            echo "# ERROR: controller pod cannot SSH to ${vm_ip}"
            false
        fi
    done

    # Write allowlist content to a file inside the pod (avoids quoting issues)
    _kubectl -n av-scanner exec "$controller_pod" -- bash -c \
        'printf "allowlist:\n  - test-client/scanner-client\n" > /tmp/allowlist.yaml'

    local molecule_log="/tmp/e2e-molecule.log"
    local molecule_rc=0
    _kubectl -n av-scanner exec "$controller_pod" -- env \
        MOLECULE_VM1_IP="${E2E_VM1_IP}" \
        MOLECULE_VM2_IP="${E2E_VM2_IP}" \
        MOLECULE_SSH_KEY="/ssh/id_ed25519" \
        MOLECULE_AV_SCANNER_BINARY="/app/av-scanner" \
        MOLECULE_NODE_EXPORTER_BINARY="/app/node_exporter" \
        MOLECULE_AUTH_ENABLED="true" \
        MOLECULE_K8S_API_ENDPOINT="${kfa_endpoint}" \
        MOLECULE_AUTH_ALLOWLIST_FILE="/tmp/allowlist.yaml" \
        MOLECULE_TOKEN_FILE="/tmp/sa-token" \
        bash -c "cd /app/ansible/roles/av-scanner && molecule test --destroy never" \
        > "$molecule_log" 2>&1 || molecule_rc=$?

    # Show molecule summary
    echo "# --- Molecule output ---"
    grep -E 'INFO|WARNING|ERROR|CRITICAL|PLAY RECAP|Molecule executed|ok=|changed=|failed=' \
        "$molecule_log" | while IFS= read -r line; do
        echo "# $line"
    done
    echo "# --- End molecule output ---"

    if [[ $molecule_rc -ne 0 ]]; then
        echo "# ERROR: molecule failed (exit code $molecule_rc). Full log: $molecule_log"
        false
    fi

    # --- Verify av-scanner is ready on both VMs ---
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        echo "# Waiting for av-scanner at http://${vm_ip}:3000..."
        local i
        for i in $(seq 1 30); do
            if curl -s --connect-timeout 2 "http://${vm_ip}:3000/api/v1/live" >/dev/null 2>&1; then
                echo "# av-scanner ready on ${vm_ip}"
                break
            fi
            sleep 2
        done
        if ! curl -s --connect-timeout 2 "http://${vm_ip}:3000/api/v1/live" >/dev/null 2>&1; then
            echo "# ERROR: av-scanner not ready at http://${vm_ip}:3000"
            false
        fi
    done

    # --- Verify Istio gateway is routing ---
    export API_URL="http://av-scanner.corp.localhost:30080"
    echo "# Waiting for Istio gateway at ${API_URL}..."
    for i in $(seq 1 15); do
        if curl -4 -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
            echo "# Istio gateway ready"
            break
        fi
        sleep 2
    done
    if ! curl -4 -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
        echo "# ERROR: Istio gateway not routing at ${API_URL}"
        false
    fi

    echo "# Setup complete: API_URL=${API_URL} (via Istio gateway)"
}

teardown_file() {
    load 'vm_helper'
    load 'test_helper'
    e2e_vm_teardown

    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        echo "# Cleaning up Helm release..."
        helm uninstall av-scanner --kube-context "kind-av-scanner-e2e" -n av-scanner 2>/dev/null || true
        echo "# Deleting kind cluster..."
        kind delete cluster --name av-scanner-e2e 2>/dev/null || true
    fi
}

setup() {
    load 'test_helper'
    AUTH_TOKEN=$(get_sa_token "test-client" "scanner-client")
}

# ============================================
# Scan tests (auth enabled, using allowed SA token)
# ============================================

@test "health endpoint returns healthy status" {
    local resp
    resp=$(curl_api -H "Authorization: Bearer ${AUTH_TOKEN}" "${API_URL}/api/v1/health")
    assert_json_field "$resp" '.status' 'healthy'
}

@test "scan clean file returns clean" {
    local resp
    resp=$(echo "clean test content" | curl -4 -s -X POST \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -F "file=@-;filename=clean.txt" \
        "${API_URL}/api/v1/scan")
    assert_json_field "$resp" '.status' 'clean'
}

@test "scan EICAR test file returns infected" {
    local eicar
    eicar=$(echo 'X5x!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | sed 's/x/O/')

    local resp
    resp=$(echo "$eicar" | curl -4 -s -X POST \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -F "file=@-;filename=eicar.com" \
        "${API_URL}/api/v1/scan")
    assert_json_field "$resp" '.status' 'infected'
}

@test "gateway load-balances across both VMs" {
    load 'vm_helper'

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

    # baseline request counts
    local base_vm1 base_vm2
    base_vm1=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM1_IP}" \
        "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'" 2>/dev/null)
    base_vm2=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM2_IP}" \
        "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'" 2>/dev/null)

    # send 10 requests through the gateway
    for i in $(seq 1 10); do
        curl -4 -s -H "Authorization: Bearer ${AUTH_TOKEN}" "${API_URL}/api/v1/health" >/dev/null
    done

    # count new requests per VM (retry to allow journal flush lag)
    local post_vm1 post_vm2 new_vm1 new_vm2 total
    for _ in $(seq 1 10); do
        post_vm1=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM1_IP}" \
            "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'" 2>/dev/null)
        post_vm2=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM2_IP}" \
            "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'" 2>/dev/null)

        new_vm1=$((post_vm1 - base_vm1))
        new_vm2=$((post_vm2 - base_vm2))
        total=$((new_vm1 + new_vm2))
        [[ $total -ge 10 ]] && break
        sleep 1
    done

    echo "VM1: $new_vm1, VM2: $new_vm2, total: $total"

    # both VMs must have received at least 1 request
    [[ $new_vm1 -gt 0 ]] || { echo "ERROR: VM1 got 0 requests"; false; }
    [[ $new_vm2 -gt 0 ]] || { echo "ERROR: VM2 got 0 requests"; false; }
    [[ $total -eq 10 ]] || { echo "ERROR: expected 10 total, got $total"; false; }
}

@test "metrics endpoint exposes expected metrics" {
    # Check metrics directly on both VMs — gateway LB may route to a VM
    # that hasn't processed scans yet, so av_scans_total may be absent.
    local all_metrics=""
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        all_metrics+=$(curl -4 -s "http://${vm_ip}:3000/metrics")
    done

    local missing=""
    echo "$all_metrics" | grep -q "av_http_requests_total" || missing="$missing av_http_requests_total"
    echo "$all_metrics" | grep -q "av_http_request_duration_seconds" || missing="$missing av_http_request_duration_seconds"
    echo "$all_metrics" | grep -q "av_scans_total" || missing="$missing av_scans_total"

    if [[ -n "$missing" ]]; then
        echo "ERROR: Missing metrics:$missing"
        false
    fi
}

# ============================================
# Auth tests
# ============================================

@test "allowed service account can access protected endpoint" {
    local token
    token=$(get_sa_token "test-client" "scanner-client")

    local status_code
    status_code=$(curl -4 -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${API_URL}/api/v1/health")

    [[ "$status_code" == "200" ]] || {
        echo "ERROR: expected 200, got $status_code"; false
    }
}

@test "denied service account gets 403" {
    _kubectl create namespace denied-client 2>/dev/null || true
    _kubectl -n denied-client create serviceaccount denied-sa 2>/dev/null || true

    local token
    token=$(get_sa_token "denied-client" "denied-sa")

    local status_code
    status_code=$(curl -4 -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${API_URL}/api/v1/health")

    [[ "$status_code" == "403" ]] || {
        echo "ERROR: expected 403, got $status_code"; false
    }
}

@test "missing token gets 401" {
    local status_code
    status_code=$(curl -4 -s -o /dev/null -w '%{http_code}' "${API_URL}/api/v1/health")

    [[ "$status_code" == "401" ]] || {
        echo "ERROR: expected 401, got $status_code"; false
    }
}

@test "probe endpoints skip auth" {
    for endpoint in /api/v1/live /api/v1/ready; do
        local status_code
        status_code=$(curl -4 -s -o /dev/null -w '%{http_code}' "${API_URL}${endpoint}")

        [[ "$status_code" == "200" ]] || {
            echo "ERROR: expected 200 for ${endpoint}, got $status_code"; false
        }
    done
}
