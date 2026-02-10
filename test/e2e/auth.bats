#!/usr/bin/env bats
# Auth tests for av-scanner (TokenReview + middleware)

setup() {
    load 'test_helper'
}

# --- TokenReview API tests (require K8S_API_ENDPOINT) ---

@test "TokenReview validates valid service account token" {
    if [[ -z "$K8S_API_ENDPOINT" ]]; then
        skip "K8S_API_ENDPOINT not set"
    fi

    local token
    token=$(get_sa_token "test-client" "scanner-client")

    local resp
    resp=$(token_review "$token")

    local status_code authenticated username
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
    if [[ -z "$K8S_API_ENDPOINT" ]]; then
        skip "K8S_API_ENDPOINT not set"
    fi

    local resp
    resp=$(token_review "invalid-token")

    local authenticated
    authenticated=$(echo "$resp" | jq -r '.status.authenticated')

    if [[ "$authenticated" != "false" ]]; then
        echo "ERROR: expected authenticated=false for invalid token"
        echo "Response: $resp"
        false
    fi

    echo "# Invalid token correctly rejected"
}

# --- Auth middleware tests (require AUTH_ENABLED + K8S_API_ENDPOINT) ---

@test "allowed service account can access protected endpoint" {
    if [[ "$AUTH_ENABLED" != "true" ]]; then
        skip "AUTH_ENABLED not set"
    fi

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
    if [[ "$AUTH_ENABLED" != "true" ]]; then
        skip "AUTH_ENABLED not set"
    fi

    # Create a non-allowlisted service account
    kubectl create namespace denied-client 2>/dev/null || true
    kubectl -n denied-client create serviceaccount denied-sa 2>/dev/null || true

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
    if [[ "$AUTH_ENABLED" != "true" ]]; then
        skip "AUTH_ENABLED not set"
    fi

    local status_code
    status_code=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/api/v1/health")

    if [[ "$status_code" != "401" ]]; then
        echo "ERROR: expected 401 for missing token, got $status_code"
        false
    fi

    echo "# Missing token: 401 Unauthorized"
}

@test "probe endpoints skip auth" {
    if [[ "$AUTH_ENABLED" != "true" ]]; then
        skip "AUTH_ENABLED not set"
    fi

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
