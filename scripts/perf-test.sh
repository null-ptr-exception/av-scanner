#!/bin/bash
#
# perf-test.sh - Run k6 load tests against av-scanner VM and report Prometheus metrics
#
# Generates test data files locally, runs k6 on the host, then queries
# Prometheus for VM resource usage during the test window.
#
# Prerequisites:
#   - VM running with av-scanner deployed (make deploy)
#   - k6 installed (go install go.k6.io/k6@latest)
#   - Prometheus running (optional, for metrics report)
#
# Usage:
#   ./scripts/perf-test.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="/tmp/k6-perf-data"
PROM_URL="http://localhost:30090"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header(){ echo -e "\n${BOLD}$1${NC}"; }

# ============================================
# Preflight
# ============================================

preflight() {
    log_header "=== Preflight Checks ==="

    # k6
    if ! command -v k6 &>/dev/null; then
        log_error "k6 not found. Install: go install go.k6.io/k6@latest"
        exit 1
    fi
    log_ok "k6 $(k6 version 2>&1 | head -1)"

    # VM discovery via virsh
    source "$SCRIPT_DIR/lib/virsh.sh"
    VM_IP=$(virsh_get_ip "av-scanner")
    if [[ -z "$VM_IP" ]]; then
        log_error "VM 'av-scanner' not running. Run 'make vm-init && make deploy' first."
        exit 1
    fi
    export VM_IP
    export API_URL="http://${VM_IP}:3000"

    if ! curl -sf --connect-timeout 3 "${API_URL}/api/v1/live" >/dev/null; then
        log_error "av-scanner not reachable at ${API_URL}"
        exit 1
    fi
    log_ok "av-scanner reachable at ${API_URL}"

    # Prometheus (optional)
    if curl -sf --connect-timeout 3 "${PROM_URL}/-/ready" >/dev/null; then
        log_ok "Prometheus reachable at ${PROM_URL}"
        HAS_PROM=true
    else
        log_warn "Prometheus not reachable at ${PROM_URL} — metrics report will be skipped"
        HAS_PROM=false
    fi
}

# ============================================
# Generate test data
# ============================================

generate_test_data() {
    log_header "=== Generating Test Data ==="

    mkdir -p "$DATA_DIR"

    # Clean zip: ~1MB of random data in a zip
    dd if=/dev/urandom bs=1M count=1 of="${DATA_DIR}/random.dat"
    (cd "${DATA_DIR}" && zip -j clean.zip random.dat) >/dev/null

    # Eicar zip: EICAR + padding in a zip (~1MB compressed)
    # ClamAV only detects EICAR as exactly 68 bytes, so we embed it in a zip with padding.
    local eicar_hex="58354f2150254041505b345c505a58353428505e2937434329377d2445494341522d5354414e444152442d414e544956495255532d544553542d46494c452124482b482a"
    echo "$eicar_hex" | xxd -r -p > "${DATA_DIR}/eicar.com"
    (cd "${DATA_DIR}" && zip -j eicar.zip eicar.com random.dat) >/dev/null

    rm -f "${DATA_DIR}/random.dat" "${DATA_DIR}/eicar.com"

    log_ok "Test data:"
    ls -lh "${DATA_DIR}"/*.zip | awk '{print "  " $5 "  " $NF}'
}

# ============================================
# Run k6
# ============================================

run_k6() {
    log_header "=== Running k6 Load Test ==="
    log_info "Target: ${API_URL}"

    LOAD_TEST_START=$(date +%s)

    set +e
    k6 run "${PROJECT_ROOT}/test/perf/loadtest.js" 2>&1 | tee /tmp/k6-output.log
    K6_EXIT=$?
    set -e

    LOAD_TEST_END=$(date +%s)
    local elapsed=$((LOAD_TEST_END - LOAD_TEST_START))

    if [[ $K6_EXIT -eq 0 ]]; then
        log_ok "k6 completed in ${elapsed}s"
    else
        log_error "k6 exited with code ${K6_EXIT} after ${elapsed}s"
        return 1
    fi
}

# ============================================
# Prometheus report
# ============================================

prom_query() {
    local query="$1"
    curl -s --data-urlencode "query=${query}" "${PROM_URL}/api/v1/query" \
        | python3 -c "
import json, sys
r = json.load(sys.stdin)
if r['status'] != 'success' or not r['data']['result']:
    print('N/A')
else:
    print(r['data']['result'][0]['value'][1])
" || echo "N/A"
}

prom_query_multi() {
    local query="$1"
    curl -s --data-urlencode "query=${query}" "${PROM_URL}/api/v1/query" \
        | python3 -c "
import json, sys
r = json.load(sys.stdin)
if r['status'] != 'success': sys.exit(0)
for m in r['data']['result']:
    labels = ', '.join(f'{k}={v}' for k,v in m['metric'].items() if k != '__name__')
    val = m['value'][1]
    print(f'    {labels}: {val}')
"
}

show_prometheus_report() {
    if [[ "$HAS_PROM" != "true" ]]; then
        return
    fi

    local duration=$((LOAD_TEST_END - LOAD_TEST_START))
    local range="${duration}s"
    [[ $duration -lt 60 ]] && range="60s"

    log_header "=== VM Resource Usage (during load test) ==="

    echo -e "\n${BOLD}CPU${NC}"
    local cpu
    cpu=$(prom_query "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[${range}])))")
    [[ "$cpu" != "N/A" ]] && printf "  Usage: %.1f%%\n" "$cpu" || echo "  N/A"

    echo -e "\n${BOLD}Memory${NC}"
    local mem_total mem_avail mem_used_pct
    mem_total=$(prom_query "node_memory_MemTotal_bytes")
    mem_avail=$(prom_query "node_memory_MemAvailable_bytes")
    mem_used_pct=$(prom_query "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)")
    if [[ "$mem_total" != "N/A" ]]; then
        printf "  Total:     %.1f GB\n" "$(echo "$mem_total / 1073741824" | bc -l)"
        printf "  Available: %.1f GB\n" "$(echo "$mem_avail / 1073741824" | bc -l)"
        printf "  Used:      %.1f%%\n" "$mem_used_pct"
    fi

    echo -e "\n${BOLD}Disk I/O${NC}"
    local disk_read disk_write
    disk_read=$(prom_query "rate(node_disk_read_bytes_total{device=\"sda\"}[${range}])")
    disk_write=$(prom_query "rate(node_disk_written_bytes_total{device=\"sda\"}[${range}])")
    if [[ "$disk_read" != "N/A" ]]; then
        printf "  sda read:  %.1f KB/s\n" "$(echo "$disk_read / 1024" | bc -l)"
        printf "  sda write: %.1f KB/s\n" "$(echo "$disk_write / 1024" | bc -l)"
    else
        echo "  N/A"
    fi

    echo -e "\n${BOLD}Network I/O${NC}"
    local net_rx net_tx
    net_rx=$(prom_query "rate(node_network_receive_bytes_total{device=\"ens3\"}[${range}])")
    net_tx=$(prom_query "rate(node_network_transmit_bytes_total{device=\"ens3\"}[${range}])")
    if [[ "$net_rx" != "N/A" ]]; then
        printf "  ens3 rx: %.1f KB/s\n" "$(echo "$net_rx / 1024" | bc -l)"
        printf "  ens3 tx: %.1f KB/s\n" "$(echo "$net_tx / 1024" | bc -l)"
    else
        echo "  N/A"
    fi

    log_header "=== av-scanner API Metrics (during load test) ==="

    echo -e "\n${BOLD}Request Rate${NC}"
    local total_rps
    total_rps=$(prom_query "sum(rate(av_http_requests_total{endpoint=\"/api/v1/scan\"}[${range}]))")
    [[ "$total_rps" != "N/A" ]] && printf "  Scan RPS: %.1f req/s\n" "$total_rps" || echo "  N/A"

    echo -e "\n${BOLD}Error Rate${NC}"
    local err_rate
    err_rate=$(prom_query "sum(rate(av_http_requests_total{endpoint=\"/api/v1/scan\",status_code!=\"200\"}[${range}])) / sum(rate(av_http_requests_total{endpoint=\"/api/v1/scan\"}[${range}])) * 100")
    [[ "$err_rate" != "N/A" ]] && printf "  Scan errors: %.2f%%\n" "$err_rate" || echo "  Scan errors: 0.00%"

    echo -e "\n${BOLD}Server-side Latency (p95)${NC}"
    local p95
    p95=$(prom_query "histogram_quantile(0.95, sum(rate(av_http_request_duration_seconds_bucket{endpoint=\"/api/v1/scan\"}[${range}])) by (le))")
    [[ "$p95" != "N/A" ]] && printf "  Scan p95: %.0f ms\n" "$(echo "$p95 * 1000" | bc -l)" || echo "  N/A"

    echo -e "\n${BOLD}Scan Results${NC}"
    prom_query_multi "increase(av_scans_total[${range}])"

    echo ""
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    rm -rf "$DATA_DIR"
}

# ============================================
# Main
# ============================================

main() {
    echo ""
    echo "============================================"
    echo "  av-scanner Performance Test"
    echo "============================================"

    preflight
    generate_test_data

    if ! run_k6; then
        cleanup
        exit 1
    fi

    show_prometheus_report
    cleanup

    log_ok "Performance test complete"
}

main "$@"
