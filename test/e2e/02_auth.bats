#!/usr/bin/env bats
# Auth e2e tests for av-scanner
#
# Automatically bootstraps:
#   - kind cluster with kube-federated-auth (TokenReview API via NodePort)
#   - Deploys av-scanner on multipass VM with ClamAV + auth enabled
#
# Requires: VM running (make vm-init && make setup-vm), kind, docker, kubectl
#
# Resources are left running for fast re-runs. Clean up manually:
#   kind delete cluster --name av-scanner-e2e

setup_file() {
    load 'test_helper'

    local project_root
    project_root="$(get_project_root)"

    # Require VM
    local state_file="${project_root}/.vm-state"
    if [[ ! -f "$state_file" ]]; then
        echo "# ERROR: .vm-state not found. Run 'make vm-init && make setup-vm' first."
        false
    fi
    source "$state_file"
    export VM_IP

    # --- Kind cluster + kube-federated-auth ---
    export KIND_CLUSTER="av-scanner-e2e"
    export KUBE_CONTEXT="kind-${KIND_CLUSTER}"

    if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
        echo "# Creating kind cluster ${KIND_CLUSTER}..."
        kind create cluster --name "$KIND_CLUSTER" \
            --config "${project_root}/test/kind-config.yaml" \
            --wait 60s
    fi
    kind export kubeconfig --name "$KIND_CLUSTER" 2>/dev/null

    # Pre-load images into Kind (build kube-federated-auth locally if needed)
    local kfa_image="rophy/kube-federated-auth:3.4.2"
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

    local prom_image="docker.io/prom/prometheus:v3.3.0"
    if ! docker image inspect "$prom_image" >/dev/null 2>&1; then
        echo "# Pulling ${prom_image}..."
        docker pull "$prom_image"
    fi
    kind load docker-image "$prom_image" --name "$KIND_CLUSTER" 2>/dev/null || true

    echo "# Deploying kube-federated-auth..."
    _kubectl apply -f "${project_root}/test/kube-federated-auth.yaml"
    _kubectl rollout status deployment/kube-federated-auth \
        -n kube-federated-auth --timeout=120s

    # Create test service accounts
    _kubectl create namespace test-client 2>/dev/null || true
    _kubectl -n test-client create serviceaccount scanner-client 2>/dev/null || true

    # Get host bridge IP (reachable from VM via NodePort mapping)
    local bridge_ip
    bridge_ip=$(ip route get "$VM_IP" 2>/dev/null | grep -oP 'src \K\S+')
    if [[ -z "$bridge_ip" ]]; then
        echo "# ERROR: cannot determine host bridge IP for VM at $VM_IP"
        false
    fi
    echo "# Host bridge IP: ${bridge_ip}"

    # Deploy Prometheus with VM_IP substituted for scrape targets
    echo "# Deploying Prometheus (VM_IP=${VM_IP})..."
    sed "s/VM_IP_PLACEHOLDER/${VM_IP}/g" "${project_root}/test/prometheus.yaml" \
        | _kubectl apply -f -
    _kubectl rollout restart deployment/prometheus -n monitoring
    _kubectl rollout status deployment/prometheus \
        -n monitoring --timeout=120s

    # Verify kube-federated-auth is reachable via host NodePort
    local kfa_endpoint="http://${bridge_ip}:30082"
    echo "# kube-federated-auth endpoint: ${kfa_endpoint}"
    if ! curl -s --connect-timeout 5 "${kfa_endpoint}/health" >/dev/null 2>&1; then
        echo "# ERROR: kube-federated-auth not reachable at ${kfa_endpoint}"
        false
    fi

    # --- Deploy av-scanner on VM with auth ---
    local extra_vars_file="/tmp/av-scanner-e2e-extra-vars.json"
    python3 -c "
import json, sys
json.dump({
    'auth_enabled': True,
    'k8s_api_endpoint': '${kfa_endpoint}',
    'auth_allowlist_content': 'allowlist:\n  - test-client/scanner-client\n'
}, sys.stdout)
" > "$extra_vars_file"
    if ! deploy_av_scanner "$extra_vars_file"; then
        rm -f "$extra_vars_file"
        false
    fi
    rm -f "$extra_vars_file"

    echo "# Setup complete: API_URL=${API_URL}"
}

teardown_file() {
    # Resources left running for fast re-runs.
    # Clean up: kind delete cluster --name av-scanner-e2e
    true
}

setup() {
    load 'test_helper'
}

@test "allowed service account can access protected endpoint" {
    local token
    token=$(get_sa_token "test-client" "scanner-client")

    local status_code
    status_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${API_URL}/api/v1/health")

    if [[ "$status_code" != "200" ]]; then
        echo "ERROR: expected 200 for allowed SA, got $status_code"
        false
    fi

    echo "# Allowed SA: 200 OK"
}

@test "denied service account gets 403" {
    _kubectl create namespace denied-client 2>/dev/null || true
    _kubectl -n denied-client create serviceaccount denied-sa 2>/dev/null || true

    local token
    token=$(get_sa_token "denied-client" "denied-sa")

    local status_code
    status_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${API_URL}/api/v1/health")

    if [[ "$status_code" != "403" ]]; then
        echo "ERROR: expected 403 for denied SA, got $status_code"
        false
    fi

    echo "# Denied SA: 403 Forbidden"
}

@test "missing token gets 401" {
    local status_code
    status_code=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/api/v1/health")

    if [[ "$status_code" != "401" ]]; then
        echo "ERROR: expected 401 for missing token, got $status_code"
        false
    fi

    echo "# Missing token: 401 Unauthorized"
}

@test "probe endpoints skip auth" {
    for endpoint in /api/v1/live /api/v1/ready; do
        local status_code
        status_code=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}${endpoint}")

        if [[ "$status_code" != "200" ]]; then
            echo "ERROR: expected 200 for ${endpoint} without auth, got $status_code"
            false
        fi
    done

    echo "# Probe endpoints: 200 OK without auth"
}
