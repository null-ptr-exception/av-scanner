# AV Scanner - Antivirus Abstraction Layer

A unified antivirus scanning service that supports multiple AV engines (ClamAV and Trend Micro DS Agent) running on a **dedicated VM** with a consistent API.

## Architecture

Both ClamAV and Trend Micro DS Agent run on a **dedicated Ubuntu VM**. The scanner uses a **hybrid approach** combining real-time scanning (RTS) and on-demand scanning for reliability:

| Component | ClamAV | Trend Micro DS Agent |
|-----------|--------|----------------------|
| **RTS Log** | `/var/log/clamav/clamonacc.log` | `/var/log/ds_agent/ds_agent.log` |
| **On-demand Binary** | `clamdscan` | `dsa_scan` |

```mermaid
flowchart TB
    subgraph VM["Scanning VM (Ubuntu)"]
        subgraph engines["AV Engines"]
            clamav["ClamAV<br/>clamonacc (RTS) + clamdscan (on-demand)"]
            trendmicro["Trend Micro DS Agent<br/>ds_agent (RTS) + dsa_scan (on-demand)"]
        end

        subgraph scanner["AV Scanner Service (systemd)"]
            upload["1. File uploaded to /tmp/av-scanner"]
            ondemand["2. On-demand scan"]
            rtscheck["3. Wait for RTS cache (if file missing)"]
            result["4. Return result"]
        end

        upload --> ondemand
        ondemand -->|success| result
        ondemand -->|file missing| rtscheck --> result
        clamav -.->|quarantine| rtscheck
    end
```

## Scan Flow

1. **File uploaded** to scan directory
2. **On-demand scan** - run `clamdscan`/`dsa_scan`
   - If scan completes successfully, use its result (clean/infected)
3. **RTS fallback** - if on-demand scan fails (file missing = RTS quarantined it):
   - Wait for RTS cache with configurable timeout (default: 500ms + 10ms per MB)
   - Return infected if found in cache, error if timeout

This hybrid approach ensures:
- **Fast detection** (~200ms avg) for most files via on-demand scan
- **Reliable detection** even when RTS quarantines files before on-demand scan runs
- **No false negatives** from race conditions

## Features

- **Hybrid scanning**: Combines RTS (fast) and on-demand (reliable) scanning
- **Unified interface**: Both engines use the same Driver interface
- **Isolated VM**: AV engines run in a dedicated Ubuntu VM
- **Race condition handling**: Checks RTS cache before and after on-demand scan
- **Ephemeral file handling**: Files are deleted immediately after scanning
- **Native systemd integration**: Runs as a native binary via systemd

## Quick Start

### 1. Install Prerequisites

```bash
# Install Multipass (Ubuntu/Debian)
sudo snap install multipass

# Install Ansible (in a virtualenv named 'venv' - required by Makefile)
python3 -m venv venv
source venv/bin/activate
pip install ansible
```

> **Note:** The `venv` directory must exist with Ansible installed. `make deploy` automatically activates it.

### 2. Create the Scanning VM

```bash
# Create Ubuntu VM with 2 CPUs, 2GB RAM, 10GB disk
multipass launch --name av-scanner --cpus 2 --memory 2G --disk 10G 24.04

# Verify VM is running
multipass list
```

### 3. Build and Deploy

```bash
# Get VM IP address
export AV_SCANNER_IP=$(multipass info av-scanner | grep IPv4 | awk '{print $2}')

# Copy your SSH key to the VM
multipass exec av-scanner -- bash -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/id_rsa.pub | multipass exec av-scanner -- bash -c "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# Build the Docker image locally and deploy to VM
make deploy
```

The `make deploy` command will:
1. Build the Docker image locally (contains Go binary)
2. Save it to a tarball
3. Transfer the image to the VM via Ansible
4. Extract the binary from the image using Podman
5. Install the binary to `/usr/local/bin/av-scanner`
6. Create a systemd service
7. Start and enable the service
8. Wait for health check to pass

### 4. Access the Scanner API

```bash
# Get VM IP address
multipass info av-scanner | grep IPv4

# Test the API (from host)
curl http://<VM_IP>:3000/api/v1/health

# Scan a file
curl -X POST -F "file=@testfile.txt" http://<VM_IP>:3000/api/v1/scan
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make build` | Build the Docker image locally |
| `make deploy` | Build, save, and deploy image to VM |
| `make test` | Upload EICAR test file to VM and verify detection |
| `make clean` | Remove local image and tarball |

## Service Management

The scanner runs as a native systemd service:

```bash
# SSH into VM
multipass shell av-scanner

# Check service status
sudo systemctl status av-scanner

# View logs
sudo journalctl -u av-scanner -f

# Restart service
sudo systemctl restart av-scanner

# Stop service
sudo systemctl stop av-scanner
```

## Multipass VM Management

```bash
# List VMs
multipass list

# Start/Stop VM
multipass start av-scanner
multipass stop av-scanner

# Shell into VM
multipass shell av-scanner

# Delete VM
multipass delete av-scanner
multipass purge
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 3000 | HTTP server port |
| `AV_ENGINE` | clamav | Active engine (clamav/trendmicro) |
| `UPLOAD_DIR` | /tmp/av-scanner | Shared scan directory |
| `MAX_FILE_SIZE` | 104857600 | Max upload size in bytes (100MB) |
| `LOG_LEVEL` | info | Log level |
| `CLAMAV_RTS_LOG_PATH` | /var/log/clamav/clamonacc.log | ClamAV RTS log file |
| `CLAMAV_SCAN_BINARY` | /usr/bin/clamdscan | ClamAV on-demand scan binary |
| `CLAMAV_TIMEOUT` | 15000 | ClamAV scan timeout in ms |
| `CLAMAV_RTS_CACHE_BASE_DELAY` | 500 | Base delay (ms) when waiting for RTS cache |
| `CLAMAV_RTS_CACHE_DELAY_PER_MB` | 10 | Additional delay (ms) per MB of file size |
| `TM_RTS_LOG_PATH` | /var/log/ds_agent/ds_agent.log | DS Agent RTS log file |
| `TM_SCAN_BINARY` | /opt/ds_agent/dsa_scan | DS Agent on-demand scan binary |
| `TM_TIMEOUT` | 15000 | DS Agent scan timeout in ms |
| `TM_RTS_CACHE_BASE_DELAY` | 500 | Base delay (ms) when waiting for RTS cache |
| `TM_RTS_CACHE_DELAY_PER_MB` | 10 | Additional delay (ms) per MB of file size |

### Authentication Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_ENABLED` | false | Enable K8s ServiceAccount authentication |
| `K8S_API_ENDPOINT` | (required if enabled) | URL of kube-federated-auth service |
| `K8S_AUTH_TIMEOUT` | 5000 | Auth service timeout in ms |
| `AUTH_ALLOWLIST_FILE` | /etc/av-scanner/allowlist.yaml | Path to ServiceAccount allowlist |

## Authentication

When deployed in Kubernetes, av-scanner supports authentication using Kubernetes ServiceAccount tokens via [kube-federated-auth](https://github.com/rophy/kube-federated-auth).

### How it works

1. Client sends request with `Authorization: Bearer <k8s-sa-token>` header
2. av-scanner validates token via kube-federated-auth TokenReview API (`/apis/authentication.k8s.io/v1/tokenreviews`)
3. av-scanner checks if the ServiceAccount is in the allowlist
4. Request proceeds if authorized, otherwise returns 401/403

### Enable authentication

```bash
export AUTH_ENABLED=true
export K8S_API_ENDPOINT=http://kube-federated-auth:8080
export AUTH_ALLOWLIST_FILE=/etc/av-scanner/allowlist.yaml
```

### Allowlist file format

```yaml
# /etc/av-scanner/allowlist.yaml
allowlist:
  - namespace1/serviceaccount1
  - namespace2/serviceaccount2
  - ci-cd/pipeline-runner
```

Format: `{namespace}/{serviceAccount}`

The file is watched for changes and reloaded automatically (hot-reload).

### Endpoints that skip authentication

- `GET /api/v1/live` - Kubernetes liveness probe
- `GET /api/v1/ready` - Kubernetes readiness probe
- `GET /metrics` - Prometheus metrics

### Error responses

| Status | Scenario |
|--------|----------|
| 401 | Missing or invalid Authorization header |
| 401 | Token validation failed (expired, invalid signature) |
| 403 | ServiceAccount not in allowlist |

### Kubernetes deployment example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: av-scanner-allowlist
data:
  allowlist.yaml: |
    allowlist:
      - my-cluster/app-namespace/app-sa
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: av-scanner
spec:
  template:
    spec:
      containers:
      - name: av-scanner
        env:
        - name: AUTH_ENABLED
          value: "true"
        - name: K8S_API_ENDPOINT
          value: "http://kube-federated-auth.kube-federated-auth:8080"
        volumeMounts:
        - name: allowlist
          mountPath: /etc/av-scanner
      volumes:
      - name: allowlist
        configMap:
          name: av-scanner-allowlist
```

To change configuration, edit the systemd service file on the VM:

```bash
sudo vi /etc/systemd/system/av-scanner.service
sudo systemctl daemon-reload
sudo systemctl restart av-scanner
```

## API

### POST /api/v1/scan
Upload and scan a file.

```bash
curl -X POST -F "file=@testfile.txt" http://<VM_IP>:3000/api/v1/scan
```

**Response (clean file):**
```json
{
  "fileId": "550e8400-e29b-41d4-a716-446655440000",
  "fileName": "testfile.txt",
  "status": "clean",
  "engine": "clamav",
  "duration": 65
}
```

**Response (infected file):**
```json
{
  "fileId": "550e8400-e29b-41d4-a716-446655440000",
  "fileName": "eicar.com",
  "status": "infected",
  "engine": "clamav",
  "signature": "Win.Test.EICAR_HDB-1",
  "duration": 51
}
```

### GET /api/v1/health
Health check for all engines.

### GET /api/v1/engines
List available engines.

### GET /api/v1/ready
Readiness probe (checks active engine health).

### GET /api/v1/live
Liveness probe.

## Testing with EICAR

```bash
# Run the EICAR test via Makefile
make test
```

Or manually:

```bash
# Download official EICAR test file
curl -s https://secure.eicar.org/eicar.com -o /tmp/eicar.com

# Test via API
curl -X POST -F "file=@/tmp/eicar.com" http://<VM_IP>:3000/api/v1/scan
# Expected response: status = "infected", signature = "Win.Test.EICAR_HDB-1"
```

## Stress Testing with k6

A [k6](https://k6.io/) stress test script is included to verify scan accuracy under load.

### Setup

```bash
# Install k6
sudo snap install k6
```

> **Note:** The test script generates EICAR test content dynamically from character codes to avoid triggering AV software on developer machines.

### Run Stress Test

```bash
# Default: 10 VUs for 30 seconds
k6 run k6-stress-test.js

# Custom API URL
k6 run -e API_URL=http://192.168.1.100:3000 k6-stress-test.js

# Higher load: 50 VUs for 60 seconds
k6 run --vus 50 --duration 60s k6-stress-test.js
```

### Test Behavior

- **80% clean files / 20% infected files** (EICAR)
- Verifies **100% correct scan results** (clean→"clean", infected→"infected")
- Reports any mismatches as failures

### Example Output

```
========== STRESS TEST SUMMARY ==========
Total requests:    3240
Clean files:       2553 (78.8%)
Infected files:    687 (21.2%)
Correct results:   100.00%
Scan errors:       0
Avg scan duration: 88.1ms
==========================================
```

### Thresholds

The test enforces:
- `correct_results`: Must be 100% (all scan results match expected)
- `http_req_failed`: Must be <1% (minimal HTTP errors)

## License

MIT
