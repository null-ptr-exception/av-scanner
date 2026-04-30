#!/usr/bin/env bats
# End-to-end tests for av-scanner
#
# Creates a QEMU VM and a kind cluster, then deploys av-scanner via a K8s Job
# (the same deployer image used by the CronJob in production). Tests both
# scan functionality and SA token auth.
#
# Requires: kind, docker, kubectl, qemu-system-x86_64, cloud-localds
#
# Env vars:
#   E2E_CLEAN_ALL=1   - delete all artifacts (VM, kind cluster) on teardown

setup_file() {
    load 'vm_helper'
    load 'test_helper'

    local project_root
    project_root="$(get_project_root)"

    # --- VM ---
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

    # --- Build and load deployer image ---
    local deploy_image="av-scanner-deploy:e2e"
    echo "# Building deployer image..."
    docker build -f "${project_root}/deploy/Dockerfile" \
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

    # --- Deployer RBAC + SA ---
    echo "# Setting up deployer RBAC..."
    _kubectl apply -f "${project_root}/deploy/cronjob.yaml"

    # --- Test service accounts ---
    _kubectl create namespace test-client 2>/dev/null || true
    _kubectl -n test-client create serviceaccount scanner-client 2>/dev/null || true

    # --- Discover host IP reachable from kind pods ---
    # kind nodes are docker containers; the host is reachable via docker bridge gateway
    local host_ip
    host_ip=$(docker inspect "${KIND_CLUSTER}-control-plane" \
        --format '{{ .NetworkSettings.Networks.kind.Gateway }}')
    if [[ -z "$host_ip" ]]; then
        echo "# ERROR: cannot determine host IP from kind network"
        false
    fi
    echo "# Host IP from kind: ${host_ip}"

    # kube-federated-auth endpoint as seen from the VM:
    # QEMU user-mode networking uses 10.0.2.2 as the host gateway,
    # and kind maps NodePort 30082 to the host.
    local vm_gateway="10.0.2.2"
    local kfa_endpoint="http://${vm_gateway}:30082"

    # --- Create secrets and config ---
    _kubectl -n av-scanner delete secret av-scanner-ssh-key 2>/dev/null || true
    _kubectl -n av-scanner create secret generic av-scanner-ssh-key \
        --from-file=id_ed25519="${E2E_SSH_KEY}"

    # Ansible extra vars as JSON file mounted into the pod
    _kubectl -n av-scanner delete configmap deploy-extra-vars 2>/dev/null || true
    _kubectl -n av-scanner create configmap deploy-extra-vars \
        --from-literal=extra-vars.json="$(cat <<'VARSEOF'
{
  "auth_enabled": true,
  "k8s_api_endpoint": "PLACEHOLDER_KFA",
  "auth_allowlist_content": "allowlist:\n  - test-client/scanner-client\n"
}
VARSEOF
)"
    # Patch in the actual kfa_endpoint (can't use shell var inside single-quoted heredoc)
    local cm_json
    cm_json=$(_kubectl -n av-scanner get configmap deploy-extra-vars -o jsonpath='{.data.extra-vars\.json}')
    cm_json="${cm_json//PLACEHOLDER_KFA/$kfa_endpoint}"
    _kubectl -n av-scanner delete configmap deploy-extra-vars
    _kubectl -n av-scanner create configmap deploy-extra-vars \
        --from-literal=extra-vars.json="$cm_json"

    # --- Run deployer Job ---
    echo "# Running deployer Job..."
    local ssh_port="${E2E_SSH_PORT:-2222}"

    # Delete previous Job if exists
    _kubectl -n av-scanner delete job av-scanner-deploy-e2e 2>/dev/null || true

    cat <<JOBEOF | _kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: av-scanner-deploy-e2e
  namespace: av-scanner
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: av-scanner-deployer
      restartPolicy: Never
      containers:
        - name: deploy
          image: ${deploy_image}
          imagePullPolicy: Never
          env:
            - name: SA_NAME
              value: "av-scanner"
            - name: SA_NAMESPACE
              value: "av-scanner"
            - name: TOKEN_DURATION
              value: "1h"
            - name: AV_SCANNER_IP
              value: "${host_ip}"
            - name: AV_SCANNER_PORT
              value: "${ssh_port}"
            - name: AV_SCANNER_KEY
              value: "/ssh/id_ed25519"
          args:
            - "-e"
            - "@/etc/deploy/extra-vars.json"
          volumeMounts:
            - name: ssh-key
              mountPath: /ssh
              readOnly: true
            - name: extra-vars
              mountPath: /etc/deploy
              readOnly: true
      volumes:
        - name: ssh-key
          secret:
            secretName: av-scanner-ssh-key
            defaultMode: 0400
        - name: extra-vars
          configMap:
            name: deploy-extra-vars
JOBEOF

    echo "# Waiting for deployer Job to complete..."
    if ! _kubectl -n av-scanner wait --for=condition=complete \
        job/av-scanner-deploy-e2e --timeout=600s; then
        echo "# ERROR: deployer Job failed. Logs:"
        _kubectl -n av-scanner logs job/av-scanner-deploy-e2e || true
        false
    fi

    # --- Verify av-scanner is running ---
    export API_URL="http://localhost:${E2E_API_PORT:-3000}"
    echo "# Waiting for av-scanner at ${API_URL}..."
    local i
    for i in $(seq 1 30); do
        if curl -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
            echo "# av-scanner ready after $((i * 2))s"
            break
        fi
        sleep 2
    done

    if ! curl -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
        echo "# ERROR: av-scanner not ready at ${API_URL}"
        false
    fi

    echo "# Setup complete: API_URL=${API_URL}"
}

teardown_file() {
    load 'vm_helper'
    e2e_vm_teardown

    if [[ "${E2E_CLEAN_ALL:-0}" == "1" ]]; then
        echo "# Deleting kind cluster..."
        kind delete cluster --name av-scanner-e2e 2>/dev/null || true
    fi
}

setup() {
    load 'test_helper'
    # Get a token for the allowed SA to use in scan tests
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
    resp=$(echo "clean test content" | curl -s -X POST \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -F "file=@-;filename=clean.txt" \
        "${API_URL}/api/v1/scan")
    assert_json_field "$resp" '.status' 'clean'
}

@test "scan EICAR test file returns infected" {
    local eicar
    eicar=$(echo 'X5x!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | sed 's/x/O/')

    local resp
    resp=$(echo "$eicar" | curl -s -X POST \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -F "file=@-;filename=eicar.com" \
        "${API_URL}/api/v1/scan")
    assert_json_field "$resp" '.status' 'infected'
}

@test "metrics endpoint exposes expected metrics" {
    # /metrics is in the auth skip paths, no token needed
    local metrics
    metrics=$(curl_api "${API_URL}/metrics")

    local missing=""
    echo "$metrics" | grep -q "av_http_requests_total" || missing="$missing av_http_requests_total"
    echo "$metrics" | grep -q "av_http_request_duration_seconds" || missing="$missing av_http_request_duration_seconds"
    echo "$metrics" | grep -q "av_scans_total" || missing="$missing av_scans_total"

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
    status_code=$(curl -s -o /dev/null -w '%{http_code}' \
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
    status_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${API_URL}/api/v1/health")

    [[ "$status_code" == "403" ]] || {
        echo "ERROR: expected 403, got $status_code"; false
    }
}

@test "missing token gets 401" {
    local status_code
    status_code=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/api/v1/health")

    [[ "$status_code" == "401" ]] || {
        echo "ERROR: expected 401, got $status_code"; false
    }
}

@test "probe endpoints skip auth" {
    for endpoint in /api/v1/live /api/v1/ready; do
        local status_code
        status_code=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}${endpoint}")

        [[ "$status_code" == "200" ]] || {
            echo "ERROR: expected 200 for ${endpoint}, got $status_code"; false
        }
    done
}
