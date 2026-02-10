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

    # Verify kube-federated-auth is reachable via host NodePort
    local kfa_endpoint="http://${bridge_ip}:30082"
    echo "# kube-federated-auth endpoint: ${kfa_endpoint}"
    if ! curl -s --connect-timeout 5 "${kfa_endpoint}/health" >/dev/null 2>&1; then
        echo "# ERROR: kube-federated-auth not reachable at ${kfa_endpoint}"
        false
    fi

    # K8S_API_ENDPOINT for TokenReview tests from host
    export K8S_API_ENDPOINT="${kfa_endpoint}"

    # --- Deploy av-scanner on VM with auth ---
    local image_tag
    image_tag=$(cd "${project_root}" && git describe --tags --always --dirty 2>/dev/null || echo "dev")

    echo "# Building and pushing av-scanner image (${image_tag})..."
    if ! (cd "${project_root}" && make push); then
        echo "# ERROR: make push failed"
        false
    fi

    echo "# Deploying av-scanner on VM with auth enabled..."
    local extra_vars_file="/tmp/av-scanner-e2e-extra-vars.json"
    python3 -c "
import json, sys
json.dump({
    'ansible_host': '${VM_IP}',
    'image_tag': '${image_tag}',
    'auth_enabled': True,
    'k8s_api_endpoint': '${kfa_endpoint}',
    'auth_allowlist_content': 'allowlist:\n  - test-client/scanner-client\n'
}, sys.stdout)
" > "$extra_vars_file"
    if ! (
        cd "${project_root}" && \
        if [[ -f venv/bin/activate ]]; then source venv/bin/activate; fi && \
        cd ansible && \
        ansible-playbook deploy.yaml -i inventory.yaml \
            -e "@${extra_vars_file}"
    ); then
        rm -f "$extra_vars_file"
        echo "# ERROR: ansible deploy failed"
        false
    fi
    rm -f "$extra_vars_file"

    # Wait for av-scanner to be ready
    export API_URL="http://${VM_IP}:3000"
    export AUTH_ENABLED="true"
    echo "# Waiting for av-scanner at ${API_URL}..."
    local i
    for i in $(seq 1 30); do
        if curl -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
            echo "# av-scanner ready after ${i}s"
            break
        fi
        sleep 2
    done

    if ! curl -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
        echo "# ERROR: av-scanner not ready at ${API_URL}"
        false
    fi

    echo "# Setup complete: API_URL=${API_URL}, K8S_API_ENDPOINT=${K8S_API_ENDPOINT}"
}

teardown_file() {
    # Everything is left running for fast re-runs.
    # Clean up manually:
    #   kind delete cluster --name av-scanner-e2e
    #   # To restore av-scanner without auth:
    #   make deploy
    true
}

setup() {
    load 'test_helper'
}

# --- TokenReview API tests ---

@test "TokenReview validates valid service account token" {
    local token
    token=$(get_sa_token "test-client" "scanner-client")

    local resp
    resp=$(token_review "$token")

    local authenticated username
    authenticated=$(echo "$resp" | jq -r '.status.authenticated')
    username=$(echo "$resp" | jq -r '.status.user.username')

    if [[ "$authenticated" != "true" ]]; then
        echo "ERROR: expected authenticated=true"
        echo "Response: $resp"
        false
    fi

    local expected="system:serviceaccount:test-client:scanner-client"
    if [[ "$username" != "$expected" ]]; then
        echo "ERROR: expected username=$expected, got $username"
        false
    fi

    echo "# TokenReview: authenticated as $username"
}

@test "TokenReview rejects invalid token" {
    local resp
    resp=$(token_review "invalid-token")

    local authenticated
    authenticated=$(echo "$resp" | jq -r '.status.authenticated')

    # kube-federated-auth may return authenticated=false or omit the field (null)
    if [[ "$authenticated" == "true" ]]; then
        echo "ERROR: expected authenticated!=true for invalid token"
        echo "Response: $resp"
        false
    fi

    echo "# Invalid token correctly rejected"
}

# --- Auth middleware tests ---

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
