#!/usr/bin/env bats
# Scan and auth e2e tests for av-scanner.
#
# Deploys via skaffold (e2e profile) + molecule inside the controller pod,
# then tests scan/auth behavior through the Istio gateway.
#
# Suite-level infra (VMs, Istio, kfa) is handled by setup_suite.bash.

setup_file() {
    load 'vm_helper'
    load 'test_helper'

    local project_root
    project_root="$(get_project_root)"

    e2e_vm_setup

    export MINIKUBE_PROFILE="av-scanner"
    export KUBE_CONTEXT="${MINIKUBE_PROFILE}"

    # --- kube-federated-auth endpoint as seen from the VMs ---
    local vm_gateway
    vm_gateway=$(ip -4 addr show virbr0 | grep -oP '(\d+\.){3}\d+' | head -1)
    local kfa_endpoint="http://${vm_gateway}:30082"

    # --- Deploy via skaffold ---
    (cd "$project_root" && skaffold delete) >&3 2>&1 || true

    echo "# Deploying via skaffold (e2e profile)..." >&3
    (cd "$project_root" && skaffold run -p e2e) >&3 2>&1

    # --- Test service accounts ---
    _kubectl create namespace test-client --dry-run=client -o yaml | _kubectl apply -f -
    _kubectl -n test-client create serviceaccount scanner-client --dry-run=client -o yaml | _kubectl apply -f -

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

    # Extract allowlist from mounted ConfigMap
    _kubectl -n av-scanner exec "$controller_pod" -- \
        python3 -c "import yaml; inv=yaml.safe_load(open('/etc/ansible/hosts')); open('/tmp/allowlist.yaml','w').write(inv['all']['vars']['auth_allowlist_content'])"

    echo "# Running molecule test..." >&3
    _kubectl -n av-scanner exec "$controller_pod" -- env \
        MOLECULE_AUTH_ENABLED="true" \
        MOLECULE_K8S_API_ENDPOINT="${kfa_endpoint}" \
        MOLECULE_AUTH_ALLOWLIST_FILE="/tmp/allowlist.yaml" \
        bash -c "cd /app/ansible/roles/av-scanner && molecule test --destroy never" \
        >&3 2>&1

    # --- Verify av-scanner is ready on both VMs ---
    for vm_ip in "$E2E_VM1_IP" "$E2E_VM2_IP"; do
        echo "# Waiting for av-scanner at http://${vm_ip}:3000..."
        local i
        for i in $(seq 1 30); do
            if curl -sf --connect-timeout 2 "http://${vm_ip}:3000/api/v1/live" >/dev/null; then
                echo "# av-scanner ready on ${vm_ip}"
                break
            fi
            sleep 2
        done
        if ! curl -sf --connect-timeout 2 "http://${vm_ip}:3000/api/v1/live" >/dev/null; then
            echo "# ERROR: av-scanner not ready at http://${vm_ip}:3000"
            false
        fi
    done

    # --- Verify Istio gateway is routing ---
    export API_URL="http://av-scanner.corp.localhost:30080"
    echo "# Waiting for Istio gateway at ${API_URL}..."
    for i in $(seq 1 15); do
        if curl -4 -sf --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null; then
            echo "# Istio gateway ready"
            break
        fi
        sleep 2
    done
    if ! curl -4 -sf --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null; then
        echo "# ERROR: Istio gateway not routing at ${API_URL}"
        false
    fi

    echo "# Setup complete: API_URL=${API_URL} (via Istio gateway)"
}

teardown_file() {
    :
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
        "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'")
    base_vm2=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM2_IP}" \
        "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'")

    # send 10 requests through the gateway
    for i in $(seq 1 10); do
        curl -4 -s -H "Authorization: Bearer ${AUTH_TOKEN}" "${API_URL}/api/v1/health" >/dev/null
    done

    # count new requests per VM (retry to allow journal flush lag)
    local post_vm1 post_vm2 new_vm1 new_vm2 total
    for _ in $(seq 1 10); do
        post_vm1=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM1_IP}" \
            "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'")
        post_vm2=$(ssh $ssh_opts -i "$E2E_SSH_KEY" "ubuntu@${E2E_VM2_IP}" \
            "sudo journalctl -u av-scanner --no-pager | awk '/Request completed/{c++} END{print c+0}'")

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
# Auth tests (via Istio gateway)
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
    _kubectl create namespace denied-client --dry-run=client -o yaml | _kubectl apply -f -
    _kubectl -n denied-client create serviceaccount denied-sa --dry-run=client -o yaml | _kubectl apply -f -

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

# ============================================
# API test playbook (controller → VMs directly)
# ============================================

@test "test-api playbook: controller token denied, av-scanner token allowed" {
    local controller_pod
    controller_pod=$(_kubectl -n av-scanner get pod \
        -l app.kubernetes.io/name=av-scanner-controller \
        -o jsonpath='{.items[0].metadata.name}')

    run _kubectl -n av-scanner exec "$controller_pod" -- \
        ansible-playbook playbooks/test-api.yaml -i /etc/ansible/hosts
    echo "$output"
    [[ $status -eq 0 ]]
}
