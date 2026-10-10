# API Reference

## Endpoints

### POST /api/v1/scan

Upload and scan a file.

```bash
curl -X POST -F "file=@testfile.txt" http://<VM_IP>:3000/api/v1/scan
```

**Response (clean):**
```json
{
  "fileId": "550e8400-e29b-41d4-a716-446655440000",
  "fileName": "testfile.txt",
  "status": "clean",
  "engine": "clamav",
  "duration": 65
}
```

**Response (infected):**
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

**Response (scan failed, 500):** when the on-demand scan gives no definitive verdict (e.g. the engine reports an error, skips the file, or its output cannot be parsed), the service waits briefly for a real-time detection of the file. If one arrives, the response is `infected`; otherwise it is 500. Clients must treat 500 as not clean.
```json
{"error": "Scan failed: ..."}
```

### GET /api/v1/health

Health check for all engines.

### GET /api/v1/engines

List available engines.

### GET /api/v1/ready

Readiness probe (checks active engine health).

### GET /api/v1/live

Liveness probe.

### GET /metrics

Prometheus metrics.

## Authentication

av-scanner supports Kubernetes ServiceAccount token authentication via [kube-federated-auth](https://github.com/null-ptr-exception/kube-federated-auth).

### Flow

1. Client sends `Authorization: Bearer <k8s-sa-token>` header
2. av-scanner forwards the token to kube-federated-auth's TokenReview API
3. If `K8S_AUTH_TOKEN_PATH` is set, av-scanner authenticates itself to kube-federated-auth using its own SA token
4. av-scanner checks if the client's ServiceAccount is in the allowlist
5. Request proceeds if authorized

### Unauthenticated endpoints

These endpoints skip authentication even when `AUTH_ENABLED=true`:

- `GET /api/v1/live`
- `GET /api/v1/ready`
- `GET /metrics`

### Allowlist

```yaml
# /etc/av-scanner/allowlist.yaml
allowlist:
  - namespace/serviceaccount
  - ci-cd/pipeline-runner
```

The file is watched and reloaded automatically on change.

### Rate limits

Optional per-account limits on `POST /api/v1/scan`, configured in the same allowlist file:

```yaml
allowlist:
  - team-a/uploader
  - team-b/batch-job

rateLimits:
  default:
    maxConcurrent: 4        # in-flight scans per account
    requestsPerMinute: 60   # sustained rate
    burst: 10               # token bucket size
  overrides:
    team-b/batch-job:
      maxConcurrent: 16
      requestsPerMinute: 600
      burst: 50
```

- No `rateLimits` section → no limits.
- `0` → unlimited for that field.
- Overrides merge field-by-field over `default`.
- `burst` must be > 0 when `requestsPerMinute` is set.
- Limits are enforced per av-scanner instance. Behind a load balancer with N VMs, an account can reach up to N× the configured limit.
- Edits to the file on the VM are hot-reloaded: an invalid file is rejected and the previous config stays active. Changes deployed via Ansible (`auth_allowlist_content`) restart the service, which resets limiter state.

Rejected requests get `429` with a `Retry-After` header (seconds):

```json
{"error": "rate limit exceeded for team-a/uploader: concurrent scans (4/4)", "reason": "concurrency"}
```

`reason` is `concurrency` or `rate`. Metrics: `av_ratelimit_rejected_total{account,reason}`, `av_ratelimit_inflight_scans{account}`.

### Error responses

| Status | Scenario |
|--------|----------|
| 401 | Missing or invalid Authorization header |
| 401 | Token validation failed (expired, invalid signature) |
| 403 | ServiceAccount not in allowlist |
| 429 | Per-account rate limit exceeded (`reason`: `concurrency` or `rate`) |
