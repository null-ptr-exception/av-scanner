# Design: Migrate to Kubernetes TokenReview API

## Overview

Migrate av-scanner authentication from a custom `/validate` endpoint to the standard Kubernetes TokenReview API (`/apis/authentication.k8s.io/v1/tokenreviews`).

## Motivation

The current implementation uses a custom API specific to kube-federated-auth V1. By migrating to the standard Kubernetes TokenReview API:

1. **Decoupling**: av-scanner becomes compatible with any TokenReview-compliant service, not just kube-federated-auth
2. **Standards compliance**: Uses the official Kubernetes authentication API
3. **Future-proof**: Benefits from TokenReview improvements (e.g., real-time revocation)
4. **Simplified config**: No need to specify cluster in requests (auto-detected by the auth service)

## Current State (V1)

### Endpoint
```
POST {AUTH_URL}/validate
```

### Request
```json
{
  "token": "<jwt-token>",
  "cluster": "<cluster-name>"
}
```

### Response (Success)
```json
{
  "kubernetes.io": {
    "namespace": "my-namespace",
    "serviceaccount": {
      "name": "my-sa",
      "uid": "abc-123"
    }
  }
}
```

### Response (Error)
```json
{
  "error": "invalid_signature",
  "message": "Token signature verification failed"
}
```

### Config
| Variable | Description |
|----------|-------------|
| `AUTH_URL` | Base URL of kube-federated-auth (e.g., `http://auth-service:8080`) |
| `AUTH_CLUSTER` | Cluster name to validate against |
| `AUTH_TIMEOUT` | Request timeout |

## Target State (TokenReview API)

### Endpoint
```
POST {AUTH_URL}/apis/authentication.k8s.io/v1/tokenreviews
```

### Request
```json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {
    "token": "<jwt-token>"
  }
}
```

### Response (Success)
```json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "status": {
    "authenticated": true,
    "user": {
      "username": "system:serviceaccount:my-namespace:my-sa",
      "uid": "abc-123",
      "groups": [
        "system:serviceaccounts",
        "system:serviceaccounts:my-namespace"
      ]
    }
  }
}
```

### Response (Error)
```json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "status": {
    "authenticated": false,
    "error": "token has expired"
  }
}
```

### Config
| Variable | Description |
|----------|-------------|
| `K8S_API_ENDPOINT` | Base URL of TokenReview service (e.g., `http://auth-service:8080`) |
| `K8S_AUTH_TIMEOUT` | Request timeout |

**Note**:
- API path `/apis/authentication.k8s.io/v1/tokenreviews` is hardcoded
- `AUTH_CLUSTER` removed - the auth service auto-detects the cluster via JWKS

## Code Changes

### 1. Rename Package Concepts

| Current | New |
|---------|-----|
| `auth.Client` | `auth.TokenReviewClient` (or keep as `Client`) |
| `ValidateRequest` | `TokenReviewRequest` |
| `ValidateResponse` | `TokenReviewResponse` |
| `auth_url` config references | Consider renaming to `tokenreview_url` |

### 2. Update Request Structs

```go
// TokenReviewRequest is a Kubernetes TokenReview request
type TokenReviewRequest struct {
    APIVersion string          `json:"apiVersion"`
    Kind       string          `json:"kind"`
    Spec       TokenReviewSpec `json:"spec"`
}

type TokenReviewSpec struct {
    Token     string   `json:"token"`
    Audiences []string `json:"audiences,omitempty"`
}
```

### 3. Update Response Structs

```go
// TokenReviewResponse is a Kubernetes TokenReview response
type TokenReviewResponse struct {
    APIVersion string            `json:"apiVersion"`
    Kind       string            `json:"kind"`
    Status     TokenReviewStatus `json:"status"`
}

type TokenReviewStatus struct {
    Authenticated bool      `json:"authenticated"`
    User          *UserInfo `json:"user,omitempty"`
    Error         string    `json:"error,omitempty"`
}

type UserInfo struct {
    Username string              `json:"username"`
    UID      string              `json:"uid"`
    Groups   []string            `json:"groups,omitempty"`
    Extra    map[string][]string `json:"extra,omitempty"`
}
```

### 4. Update Validate Method

```go
const tokenReviewPath = "/apis/authentication.k8s.io/v1/tokenreviews"

func (c *Client) Validate(ctx context.Context, token string) (*CallerIdentity, error) {
    reqBody := TokenReviewRequest{
        APIVersion: "authentication.k8s.io/v1",
        Kind:       "TokenReview",
        Spec: TokenReviewSpec{
            Token: token,
        },
    }

    // HTTP POST to {baseURL}/apis/authentication.k8s.io/v1/tokenreviews
    req, err := http.NewRequestWithContext(ctx, http.MethodPost,
        c.baseURL+tokenReviewPath, bytes.NewReader(bodyBytes))
    // ...

    if !resp.Status.Authenticated {
        return nil, fmt.Errorf("authentication failed: %s", resp.Status.Error)
    }

    // Parse "system:serviceaccount:namespace:name"
    identity, err := parseServiceAccountUsername(resp.Status.User.Username)
    if err != nil {
        return nil, err
    }
    identity.UID = resp.Status.User.UID

    c.logger.Info("authentication successful",
        "identity", fmt.Sprintf("%s/%s", identity.Namespace, identity.ServiceAccount),
    )
    return identity, nil
}

func parseServiceAccountUsername(username string) (*CallerIdentity, error) {
    // Expected format: "system:serviceaccount:namespace:name"
    parts := strings.Split(username, ":")
    if len(parts) != 4 || parts[0] != "system" || parts[1] != "serviceaccount" {
        return nil, fmt.Errorf("invalid serviceaccount username format: %s", username)
    }
    return &CallerIdentity{
        Namespace:      parts[2],
        ServiceAccount: parts[3],
    }, nil
}
```

### 5. Update Config

```go
type Config struct {
    // ...
    K8sAPIEndpoint string        // Base URL (e.g., http://auth-service:8080)
    K8sAuthTimeout time.Duration
    // AUTH_URL renamed to K8S_API_ENDPOINT
    // AUTH_CLUSTER removed
}

// Endpoint is hardcoded
const tokenReviewPath = "/apis/authentication.k8s.io/v1/tokenreviews"
```

### 6. Update CallerIdentity

Remove the `Cluster` field:

```go
type CallerIdentity struct {
    Namespace      string
    ServiceAccount string
    UID            string
    // Cluster field removed
}
```

### 7. Update Allowlist Format

Simplify from `cluster/namespace/serviceAccount` to `namespace/serviceAccount`:

```yaml
# Before
allowlist:
  - cluster: my-cluster
    namespace: my-namespace
    serviceAccount: my-sa

# After
allowlist:
  - namespace: my-namespace
    serviceAccount: my-sa
```

### 8. Update Logging

Change identity format in logs:

```go
// Before
c.logger.Info("authentication successful",
    "identity", fmt.Sprintf("%s/%s/%s", identity.Cluster, identity.Namespace, identity.ServiceAccount),
)

// After
c.logger.Info("authentication successful",
    "identity", fmt.Sprintf("%s/%s", identity.Namespace, identity.ServiceAccount),
)
```

## Files to Modify

| File | Changes |
|------|---------|
| `internal/auth/client.go` | New request/response structs, update Validate(), remove Cluster |
| `internal/auth/client_test.go` | Update test mocks for TokenReview format |
| `internal/auth/middleware.go` | Remove Cluster from CallerIdentity, update logs |
| `internal/auth/middleware_test.go` | Update test mocks |
| `internal/auth/allowlist.go` | Remove Cluster from allowlist entries |
| `internal/auth/allowlist_test.go` | Update tests for new format |
| `internal/config/config.go` | Rename AUTH_URL→K8S_API_ENDPOINT, remove AUTH_CLUSTER |
| `README.md` | Update authentication docs |
| `ansible/deploy.yaml` | Update env vars |

## Backward Compatibility

This is a **breaking change** for the auth service dependency:
- Requires TokenReview-compatible auth service (kube-federated-auth V2 or equivalent)
- V1 `/validate` endpoint will no longer work

## Testing Plan

1. Unit tests with mocked TokenReview responses
2. Integration test with kube-federated-auth V2 in minikube
3. Verify allowlist authorization still works
4. Verify logging includes identity in expected format

## Design Decisions

1. **Allowlist format**: Simplify to `namespace/serviceAccount` (remove cluster)
2. **Config naming**: Rename `AUTH_URL` to `K8S_API_ENDPOINT` - base URL only, API path `/apis/authentication.k8s.io/v1/tokenreviews` is hardcoded
3. **Logging**: Remove cluster from logs since it's no longer tracked
