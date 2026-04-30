#!/bin/bash
# Common test helpers for av-scanner e2e tests

# Get project root directory
get_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# API URL: from env, .vm-state, or default
if [[ -z "$API_URL" ]]; then
    _state_file="$(get_project_root)/.vm-state"
    if [[ -f "$_state_file" ]]; then
        source "$_state_file"
        if [[ "$HYPERVISOR" == "multipass" ]]; then
            API_URL="http://${VM_IP}:3000"
        else
            API_URL="http://localhost:${API_PORT}"
        fi
    else
        API_URL="http://localhost:3000"
    fi
fi

# Kubernetes context (set by auth.bats setup_file, or from env)
KUBE_CONTEXT="${KUBE_CONTEXT:-}"

# curl wrapper for API calls
curl_api() {
    curl -s "$@"
}

# Upload a file to the scan endpoint
# Usage: upload_file <content> <filename>
upload_file() {
    local content="$1"
    local filename="$2"
    echo "$content" | curl -s -X POST \
        -F "file=@-;filename=${filename}" \
        "${API_URL}/api/v1/scan"
}

# Assert HTTP status code
# Usage: assert_status <url> <expected_code>
assert_status() {
    local url="$1"
    local expected="$2"
    local actual
    actual=$(curl -s -o /dev/null -w '%{http_code}' "$url")
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: expected status $expected, got $actual for $url"
        false
    fi
}

# Assert JSON field value
# Usage: assert_json_field <json> <jq_filter> <expected_value>
assert_json_field() {
    local json="$1"
    local filter="$2"
    local expected="$3"
    local actual
    actual=$(echo "$json" | jq -r "$filter")
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: expected $filter=$expected, got $actual"
        echo "Response: $json"
        false
    fi
}

# Deploy av-scanner on VM via ansible
# Usage: deploy_av_scanner [extra_vars_file]
#   extra_vars_file: optional path to JSON file with extra ansible vars
#
# Supports two modes:
#   1. e2e VM (E2E_SSH_PORT set): uses localhost + SSH port forwarding
#   2. Legacy .vm-state: uses VM_IP from state file
deploy_av_scanner() {
    local extra_vars_file="${1:-}"
    local project_root
    project_root="$(get_project_root)"

    echo "# Building av-scanner binary..."
    local binary_path="/tmp/av-scanner-e2e"
    if ! (cd "${project_root}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$binary_path" main.go); then
        echo "# ERROR: go build failed"
        return 1
    fi

    echo "# Deploying av-scanner on VM..."
    local ansible_extra_args=()
    ansible_extra_args+=(-e "binary_path=${binary_path}")

    if [[ -n "${E2E_SSH_PORT:-}" ]]; then
        # e2e VM mode: localhost with port forwarding
        ansible_extra_args+=(-e "ansible_host=localhost")
        ansible_extra_args+=(-e "ansible_port=${E2E_SSH_PORT}")
        ansible_extra_args+=(-e "ansible_ssh_private_key_file=${E2E_SSH_KEY}")
    else
        # Legacy .vm-state mode
        local state_file="${project_root}/.vm-state"
        if [[ ! -f "$state_file" ]]; then
            echo "# ERROR: .vm-state not found and E2E_SSH_PORT not set."
            return 1
        fi
        source "$state_file"
        ansible_extra_args+=(-e "ansible_host=${VM_IP}")
        if [[ "$HYPERVISOR" != "multipass" ]]; then
            ansible_extra_args+=(-e "ansible_port=${SSH_PORT}")
            ansible_extra_args+=(-e "ansible_ssh_private_key_file=${project_root}/.ssh/id_ed25519")
        fi
    fi

    if [[ -n "$extra_vars_file" ]]; then
        ansible_extra_args+=(-e "@${extra_vars_file}")
    fi

    if ! (
        cd "${project_root}" && \
        if [[ -f venv/bin/activate ]]; then source venv/bin/activate; fi && \
        cd ansible && \
        ansible-playbook deploy.yaml -i inventory.yaml \
            "${ansible_extra_args[@]}"
    ); then
        echo "# ERROR: ansible deploy failed"
        return 1
    fi

    if [[ -n "${E2E_API_PORT:-}" ]]; then
        export API_URL="http://localhost:${E2E_API_PORT}"
    elif [[ -n "${VM_IP:-}" ]]; then
        export API_URL="http://${VM_IP}:3000"
    fi

    echo "# Waiting for av-scanner at ${API_URL}..."
    local i
    for i in $(seq 1 30); do
        if curl -s --connect-timeout 2 "${API_URL}/api/v1/live" >/dev/null 2>&1; then
            echo "# av-scanner ready after ${i}s"
            return 0
        fi
        sleep 2
    done

    echo "# ERROR: av-scanner not ready at ${API_URL}"
    return 1
}

# kubectl wrapper with context
_kubectl() {
    if [[ -n "$KUBE_CONTEXT" ]]; then
        command kubectl --context "$KUBE_CONTEXT" "$@"
    else
        command kubectl "$@"
    fi
}

# Get a ServiceAccount token via kubectl
# Usage: get_sa_token <namespace> <serviceaccount>
get_sa_token() {
    local ns="$1"
    local sa="$2"
    if [[ -n "$TEST_SA_TOKEN" ]]; then
        echo "$TEST_SA_TOKEN"
        return
    fi
    _kubectl -n "$ns" create token "$sa" --duration=1h
}

