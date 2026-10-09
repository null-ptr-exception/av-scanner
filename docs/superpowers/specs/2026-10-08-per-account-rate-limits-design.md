# Design: Per-Account Rate Limits

## Goal

Limit scan traffic per authenticated account (`namespace/serviceaccount`) to:

1. **Fairness / engine protection** — cap concurrent in-flight scans so one account cannot starve others.
2. **Abuse / runaway-client protection** — cap request rate, rejecting excess with HTTP 429.

Out of scope: volume quotas (scans/day, bytes/hour), fleet-wide (cross-VM) limits, queueing.

## Decisions

| Topic | Decision |
|-------|----------|
| Scope of enforcement | Per instance, in memory. N VMs behind a load balancer give an account up to N× the configured limit. |
| Config granularity | Global default + per-account overrides |
| Config location | Existing allowlist YAML (`AUTH_ALLOWLIST_FILE`), hot-reloaded via the existing fsnotify watcher |
| Over-concurrency behavior | Reject immediately with 429 (no queueing) |
| Over-rate behavior | Reject immediately with 429 |
| Implementation | New `internal/ratelimit` package, middleware after auth, `golang.org/x/time/rate` token bucket |
| Limited endpoints | `POST /api/v1/scan` only |

Rejected alternatives:

- **Istio local rate limit** — cannot key on account identity (token is opaque until TokenReview) and cannot limit concurrency.
- **Hand-rolled fixed-window counter** — allows 2× bursts at window boundaries; more code and tests for less accuracy than `x/time/rate`.

## Configuration

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

Semantics:

- `rateLimits` absent → no limits. Existing deployments are unchanged.
- `0` for a field → unlimited for that dimension.
- Overrides merge field-by-field over `default`; an omitted field inherits the default value.
- An override key not present in `allowlist` → logged as a warning and ignored. Such accounts are rejected with 403 before the limiter runs.
- Validation errors fail the load:
  - negative values
  - `requestsPerMinute > 0` with `burst == 0` (would reject every request)
- Load failure at startup → service exits. Load failure on hot reload → reload is rejected and the previous config stays active (same as the current allowlist behavior).
- Hot reload: existing per-account token buckets get new limit/burst values on their next request. In-flight concurrency counts are preserved, so lowering a limit never interrupts running scans.

Deployment: the Ansible role writes `auth_allowlist_content` to the allowlist file verbatim, so no Ansible or Helm template changes are needed. Update docs and examples only.

## Request Flow

Middleware chain:

```
metrics → auth (TokenReview + allowlist) → ratelimit → handler
```

For `POST /api/v1/scan`:

1. Read the caller identity from the request context (set by auth middleware).
2. Try to acquire a concurrency slot for the account. If at `maxConcurrent` → 429 `reason=concurrency`. No rate token is consumed.
3. Check the rate limiter (`Allow()`). If denied → release the slot, 429 `reason=rate`.
4. Call the next handler. Release the slot via `defer`, so it is released on success, error, client disconnect, or panic.

The multipart body has not been read when a 429 is returned. Set `Connection: close` on 429 responses so clients stop sending large bodies.

State: a mutex-protected `map[account]*accountState` holding the in-flight counter and `*rate.Limiter`, created lazily on first request. The map is bounded by the allowlist, so no eviction is needed. On reload, state for accounts removed from the allowlist is dropped once their in-flight count reaches zero.

When auth is disabled, the limiter is not installed (there is no identity to key on). The allowlist file is not loaded in that mode either.

## 429 Response

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 2
Connection: close
Content-Type: application/json

{"error": "rate limit exceeded for team-a/uploader: concurrent scans (4/4)", "reason": "concurrency"}
```

- `reason`: `concurrency` or `rate`.
- `Retry-After`:
  - `rate`: time until the next token is available, from a token-bucket reservation that is then cancelled. Round up to whole seconds, minimum 1.
  - `concurrency`: fixed `1`, because scan completion time is unknown.
- Add a 429 row to the error table in `docs/api.md`.

## Metrics and Logging

New metrics:

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `av_ratelimit_rejected_total` | counter | `account`, `reason` | Rejected requests |
| `av_ratelimit_inflight_scans` | gauge | `account` | Current in-flight scans |

`account` label cardinality is bounded by the allowlist. Rejected requests also appear in the existing `av_http_requests_total` with `status_code="429"`.

Each rejection logs at `Warn` with `identity`, `reason`, `limit`, `path`, matching the auth-failure log style.

## Testing

Unit (`make test-unit`):

- `internal/ratelimit`:
  - Token bucket behavior, made deterministic with `AllowN(t, n)` and explicit times.
  - Merging overrides with the default; `0` means unlimited.
  - The slot is released on success, handler error, and panic. A rate rejection releases its slot.
  - On reload, limits update and in-flight counts are preserved.
- Middleware (`httptest`):
  - 429 body, `reason` field, `Retry-After` header.
  - The body is not read on rejection.
  - Only `POST /api/v1/scan` is limited.
  - Concurrency: with the handler blocked on a channel, N+1 parallel requests produce exactly one 429.
- Config parsing:
  - `rateLimits` absent means no limits.
  - Validation errors fail at startup. On reload, the change is rejected and the previous config is kept.
  - An override for an account not in the allowlist logs a warning.
- Metrics: the counter and gauge update correctly.

E2E (`make test-e2e`):

- Add a dedicated test ServiceAccount with a low rate override (e.g. `requestsPerMinute: 1, burst: 1`) to the e2e allowlist in `test/e2e/setup_suite.bash`.
- Send requests to one VM IP directly, bypassing the gateway: each VM has its own limits, so load-balanced results would not be deterministic.
- Rate: a dedicated ServiceAccount with `requestsPerMinute: 1, burst: 1`. Two sequential scans → the second gets 429 with `reason: rate` and a `Retry-After` header, and `av_ratelimit_rejected_total` increments.
- Concurrency: a dedicated ServiceAccount with `maxConcurrent: 1`. A slow upload (`curl --limit-rate`) holds the slot, because the slot is acquired before the body is read. A second scan sent while it is in flight → 429 with `reason: concurrency`. The slow request then completes with 200.
- Issue #15 (concurrent requests reported to fail with 401) is not assumed. If the concurrency case gets 401 instead of 429, investigate it as a reproduction of #15.

Helm (`make test-helm`) and Molecule (`make test-molecule`): no template changes; must keep passing.

## Files Touched

- `internal/ratelimit/` (new): limiter, middleware, tests
- `internal/auth/allowlist.go`: parse `rateLimits` and pass it to the limiter on load/reload
- `internal/api/handlers.go`: wire the middleware after auth
- `internal/metrics/`: new metrics
- `go.mod` / `go.sum`: add `golang.org/x/time` v0.12.0 (last release compatible with `go 1.23.0`)
- `internal/api/handlers_test.go`: wiring test
- `test/e2e/setup_suite.bash`, `test/e2e/01_e2e.bats`: e2e case
- `docs/api.md`: 429 response, `rateLimits` config
