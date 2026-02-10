#!/usr/bin/env bats
# E2e scan tests for av-scanner

setup() {
    load 'test_helper'
}

@test "health endpoint returns healthy status" {
    local resp
    resp=$(curl_api "${API_URL}/api/v1/health")

    assert_json_field "$resp" '.status' 'healthy'
    echo "# Health: healthy"
}

@test "scan clean file returns clean" {
    local resp
    resp=$(upload_file "clean test content" "clean.txt")

    assert_json_field "$resp" '.status' 'clean'
    echo "# Clean file: clean"
}

@test "scan EICAR test file returns infected" {
    # EICAR with 'O' replaced by 'x' to avoid triggering local AV
    local eicar
    eicar=$(echo 'X5x!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | sed 's/x/O/')

    local resp
    resp=$(upload_file "$eicar" "eicar.com")

    assert_json_field "$resp" '.status' 'infected'
    echo "# EICAR: infected"
}

@test "metrics endpoint exposes expected metrics" {
    local metrics
    metrics=$(curl_api "${API_URL}/metrics")

    local missing=""
    echo "$metrics" | grep -q "av_http_requests_total" || missing="$missing av_http_requests_total"
    echo "$metrics" | grep -q "av_http_request_duration_seconds" || missing="$missing av_http_request_duration_seconds"
    echo "$metrics" | grep -q "av_scans_total" || missing="$missing av_scans_total"

    if [[ -n "$missing" ]]; then
        echo "ERROR: Missing metrics:$missing"
        echo "Available av_ metrics:"
        echo "$metrics" | grep "^av_" || true
        false
    fi

    echo "# All expected metrics present"
}
