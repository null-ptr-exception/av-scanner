#!/bin/bash
#
# perf-test.sh - k6 load test against one av-scanner VM
#
# Modes:
#   load   (default) 5 clean + 2 EICAR virtual users for 30s (test/perf/loadtest.js)
#   sweep  fixed arrival rates (scans/s) in steps until p95 > 5s or >5% failures
#          (test/perf/sweep.js); reports the highest rate with p95 <= PERF_P95_MS
#
# Files: 1MB zips, clean or with EICAR. Each step also reports the VM's CPU use.
#
# Prerequisites:
#   - av-scanner deployed on the VM (make env && make deploy)
#   - k6 and python3 on this host
#
# Usage:
#   ./scripts/perf-test.sh [load|sweep]
#
# Environment:
#   PERF_VM       libvirt VM to test (default: e2e-1; e.g. $E2E_TM_VM for Trend Micro)
#   PERF_RATES    sweep rates in scans/s (default: "1 2 4 8 16 32 64 128")
#   PERF_P95_MS   latency limit for the sweep result (default: 1000)
#   AUTH_TOKEN    bearer token, if the VM has auth enabled

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/virsh.sh"

MODE="${1:-load}"
PERF_VM="${PERF_VM:-e2e-1}"
PERF_RATES="${PERF_RATES:-1 2 4 8 16 32 64 128}"
PERF_P95_MS="${PERF_P95_MS:-1000}"
SSH_KEY="${PROJECT_ROOT}/.vms/id_ed25519"

case "$MODE" in
    load|sweep) ;;
    *) echo "Usage: $0 [load|sweep]"; exit 1 ;;
esac

for cmd in k6 python3 jq; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

VM_IP=$(virsh_get_ip "$PERF_VM")
if [[ -z "$VM_IP" ]]; then
    echo "ERROR: VM '$PERF_VM' not running. Run: make env && make deploy"
    exit 1
fi
API_URL="http://${VM_IP}:3000"
curl -sf --connect-timeout 3 "${API_URL}/api/v1/live" >/dev/null || {
    echo "ERROR: av-scanner not reachable at ${API_URL}"
    exit 1
}

# Under the project, not /tmp: a snap-packaged k6 has a private /tmp
mkdir -p "${PROJECT_ROOT}/test-results"
DATA_DIR=$(mktemp -d "${PROJECT_ROOT}/test-results/perf-data.XXXXXX")
trap 'rm -rf "$DATA_DIR"' EXIT

# EICAR is stored with 'O' replaced by 'x' and fixed at runtime (see CLAUDE.md)
echo 'X5x!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' | sed 's/x/O/' \
    | python3 -c '
import os, sys, zipfile
eicar = sys.stdin.buffer.read().rstrip(b"\n")
rnd = os.urandom(1 << 20)
d = sys.argv[1]
with zipfile.ZipFile(f"{d}/clean.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("random.dat", rnd)
with zipfile.ZipFile(f"{d}/eicar.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("eicar.com", eicar)
    z.writestr("random.dat", rnd)
' "$DATA_DIR"

# VM CPU counters: "<busy> <total>" jiffies from /proc/stat
cpu_sample() {
    # -n: never read stdin, which may be the caller's script
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -i "$SSH_KEY" "ubuntu@${VM_IP}" \
        "awk '/^cpu /{print \$2+\$3+\$4+\$7+\$8, \$2+\$3+\$4+\$5+\$6+\$7+\$8}' /proc/stat"
}

cpu_pct() {
    awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, " "); split(b, y, " ");
        printf "%.0f", 100 * (y[1] - x[1]) / (y[2] - x[2]) }'
}

export API_URL DATA_DIR AUTH_TOKEN="${AUTH_TOKEN:-}"
echo "Target: ${PERF_VM} (${API_URL}), mode: ${MODE}"

if [[ "$MODE" == "load" ]]; then
    before=$(cpu_sample)
    k6 run "${PROJECT_ROOT}/test/perf/loadtest.js"
    echo "VM CPU during test: $(cpu_pct "$before" "$(cpu_sample)")%"
    exit 0
fi

results=()
printf "%6s %9s %8s %8s %7s %9s %8s %5s\n" rate achieved p50_ms p95_ms failed mismatch dropped cpu
for rate in $PERF_RATES; do
    before=$(cpu_sample)
    line=$(RATE="$rate" k6 run -q --no-color "${PROJECT_ROOT}/test/perf/sweep.js" | grep '^{"rate"')
    cpu=$(cpu_pct "$before" "$(cpu_sample)")
    line=$(echo "$line" | jq -c --argjson cpu "$cpu" '. + {cpu: $cpu}')
    results+=("$line")
    echo "$line" | jq -r '[.rate, (.achieved*100|round/100), (.p50|round), (.p95|round),
        "\(.failed*100|round)%", .mismatches, .dropped, "\(.cpu)%"] | @tsv' \
        | awk -F'\t' '{printf "%6s %9s %8s %8s %7s %9s %8s %5s\n", $1, $2, $3, $4, $5, $6, $7, $8}'
    echo "$line" | jq -e '.p95 > 5000 or .failed > 0.05' >/dev/null && break
    sleep 10
done

printf '%s\n' "${results[@]}" | jq -rs --argjson lim "$PERF_P95_MS" '
    map(select(.p95 <= $lim and .failed == 0 and .mismatches == 0)) | max_by(.achieved)
    | if . then "Saturation (p95 <= \($lim)ms): \(.achieved*100|round/100) scans/s at offered \(.rate)/s, p95 \(.p95|round)ms, VM CPU \(.cpu)%"
      else "No rate met p95 <= \($lim)ms without errors" end'
