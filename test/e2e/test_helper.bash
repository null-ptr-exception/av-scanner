#!/bin/bash
# Common test helpers for av-scanner e2e tests

# Get project root directory
get_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# Kubernetes context (set by setup_file)
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
    if [[ -n "${TEST_SA_TOKEN:-}" ]]; then
        echo "$TEST_SA_TOKEN"
        return
    fi
    _kubectl -n "$ns" create token "$sa" --duration=1h
}
