#!/usr/bin/env bats
# Trend Micro-specific e2e tests, against vm2 ($E2E_TM_VM) directly.
# Skipped unless E2E_TM_VM names a pre-installed Trend Micro VM.
#
# Needs av-scanner deployed on the VMs: by the earlier test files when run as
# part of the suite, or by make deploy.

setup_file() {
    load 'vm_helper'
    load 'test_helper'
    if [[ "$E2E_VM2_ENGINE" != "trendmicro" ]]; then
        skip "no Trend Micro VM (set E2E_TM_VM, see docs/development.md)"
    fi
    e2e_vm_setup
    export KUBE_CONTEXT="av-scanner"
    export TM_RTS_LOG_PATH="${TM_RTS_LOG_PATH:-/var/opt/ds_agent/diag/ds_am.log}"
}

setup() {
    load 'test_helper'
    load 'vm_helper'
    # Auth may be disabled depending on which deploy ran last; the header is then ignored
    AUTH_TOKEN=$(get_sa_token "test-client" "scanner-client" || true)
}

@test "trendmicro: agent allows dsa_scan" {
    local out code
    out=$(vm_ssh "$E2E_VM2_IP" 'echo ok > /tmp/e2e-preflight.txt; sudo /opt/ds_agent/dsa_scan --target /tmp/e2e-preflight.txt --json; echo "exit=$?"; rm -f /tmp/e2e-preflight.txt')
    echo "$out"
    code=$(echo "$out" | grep -o 'exit=[0-9]*')
    [[ "$code" == "exit=0" ]] || {
        echo "ERROR: dsa_scan $code. 249 = enable 'Allow agent to trigger or cancel a manual scan' (Anti-Malware > General)"
        false
    }
}

@test "trendmicro: service watches the agent's RTS log" {
    vm_ssh "$E2E_VM2_IP" "systemctl cat av-scanner" | grep -Fq "TM_RTS_LOG_PATH=${TM_RTS_LOG_PATH}"
    vm_ssh "$E2E_VM2_IP" "sudo test -f ${TM_RTS_LOG_PATH}"
}

@test "trendmicro: EICAR detection is logged by the agent" {
    local eicar="${BATS_TEST_TMPDIR}/eicar.com"
    echo 'X5x!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | sed 's/x/O/' > "$eicar"

    local resp
    resp=$(curl -4 -s -X POST \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -F "file=@${eicar};filename=eicar.com" \
        "http://${E2E_VM2_IP}:3000/api/v1/scan")
    assert_json_field "$resp" '.status' 'infected'
    assert_json_field "$resp" '.engine' 'trendmicro'

    # ds_am.log contains binary bytes, so grep needs -a to print matching lines
    local file_id
    file_id=$(echo "$resp" | jq -r '.fileId')
    vm_ssh "$E2E_VM2_IP" "sudo grep -aF 'virus found' ${TM_RTS_LOG_PATH}" | grep -Fq "$file_id" || {
        echo "ERROR: no ${TM_RTS_LOG_PATH} detection for fileId ${file_id}"
        false
    }
}
