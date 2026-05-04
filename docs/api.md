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

### Error responses

| Status | Scenario |
|--------|----------|
| 401 | Missing or invalid Authorization header |
| 401 | Token validation failed (expired, invalid signature) |
| 403 | ServiceAccount not in allowlist |
