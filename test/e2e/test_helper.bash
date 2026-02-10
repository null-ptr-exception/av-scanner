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

# K8s API endpoint for TokenReview tests
K8S_API_ENDPOINT="${K8S_API_ENDPOINT:-}"

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

# Send a TokenReview request
# Usage: token_review <token>
token_review() {
    local token="$1"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"apiVersion\":\"authentication.k8s.io/v1\",\"kind\":\"TokenReview\",\"spec\":{\"token\":\"${token}\"}}" \
        "${K8S_API_ENDPOINT}/apis/authentication.k8s.io/v1/tokenreviews"
}
