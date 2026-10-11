#!/usr/bin/env bats
# ClamAV-specific e2e tests, against vm1 (e2e-1) directly.
#
# Needs av-scanner deployed on the VMs: by the earlier test files when run as
# part of the suite, or by make deploy.

setup_file() {
    load 'vm_helper'
    load 'test_helper'
    e2e_vm_setup
    export KUBE_CONTEXT="av-scanner"
}

setup() {
    load 'test_helper'
    # Auth may be disabled depending on which deploy ran last; the header is then ignored
    AUTH_TOKEN=$(get_sa_token "test-client" "scanner-client" || true)
}

@test "clamav: archive exceeding scan limits is reported with a Heuristics.Limits signature" {
    # 200MB of zeros gzips to ~200KB but expands past clamd's MaxFileSize (100M)
    local archive="${BATS_TEST_TMPDIR}/oversized.gz"
    python3 - "$archive" <<'EOF'
import gzip, sys
with gzip.open(sys.argv[1], "wb") as f:
    chunk = b"\0" * (1 << 20)
    for _ in range(200):
        f.write(chunk)
EOF

    local resp
    resp=$(curl -4 -s -X POST \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -F "file=@${archive};filename=oversized.gz" \
        "http://${E2E_VM1_IP}:3000/api/v1/scan")
    assert_json_field "$resp" '.status' 'infected'
    assert_json_field "$resp" '.engine' 'clamav'
    assert_json_field "$resp" '.signature | startswith("Heuristics.Limits.Exceeded")' 'true'
}
