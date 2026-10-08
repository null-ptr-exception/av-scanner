# Per-Account Rate Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce per-account (`namespace/serviceaccount`) concurrency and request-rate limits on `POST /api/v1/scan`, configured in the allowlist YAML, rejecting excess with HTTP 429.

**Architecture:** A new `internal/ratelimit` package holds the config types, an in-memory `Limiter` (per-account in-flight counter and `x/time/rate` token bucket), and an HTTP middleware. The auth allowlist parses an optional `rateLimits` section and pushes it to the limiter on load and on every hot reload. `internal/api` wraps only the scan route with the limiter, inside the auth middleware, so the caller identity is already in the request context.

**Tech Stack:** Go 1.23, `golang.org/x/time/rate` v0.12.0, `gopkg.in/yaml.v3`, Prometheus `client_golang`, BATS for e2e.

**Spec:** `docs/superpowers/specs/2026-10-08-per-account-rate-limits-design.md`

## Global Constraints

- `go.mod` declares `go 1.23.0`. Use `golang.org/x/time` **v0.12.0** exactly (v0.13.0+ requires Go 1.24).
- No `rateLimits` section → no limits (backward compatible).
- `0` for any limit field → unlimited for that dimension.
- Only `POST /api/v1/scan` is limited.
- 429 body shape: `{"error": "...", "reason": "concurrency"|"rate"}`; headers `Retry-After` (whole seconds, min 1), `Connection: close`, `Content-Type: application/json`.
- Metric names: `av_ratelimit_rejected_total{account,reason}`, `av_ratelimit_inflight_scans{account}`.
- Commit format: `<type>: <short description>`, types feat/fix/refactor/chore/docs/build/test. No AI attribution anywhere.
- Shell/BATS: never suppress stderr (`2>/dev/null`, `&>/dev/null`).
- Never store the EICAR string verbatim (see CLAUDE.md).
- kubectl context: `av-scanner`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `internal/ratelimit/config.go` (new) | `Limits`, `Override`, `Config` types; merge (`For`) and `Validate` |
| `internal/ratelimit/limiter.go` (new) | `Limiter`: per-account state, `Acquire`, `Update`, release |
| `internal/ratelimit/middleware.go` (new) | `Limiter.Handler`: HTTP wrapper and 429 writer |
| `internal/metrics/metrics.go` | Two new metrics and their setters |
| `internal/auth/allowlist.go` | Parse/validate `rateLimits`, push to limiter on load/reload |
| `internal/api/handlers.go` | Create the limiter, wrap the scan route |
| `test/e2e/setup_suite.bash`, `test/e2e/01_e2e.bats` | E2E rate and concurrency cases |
| `docs/api.md`, `docs/deployment.md` | User docs |

Dependency direction: `auth → ratelimit → metrics`. `ratelimit` must NOT import `auth` (that would be a cycle). The middleware gets the account through an `identity func(*http.Request) string` parameter.

---

### Task 1: Rate-limit config types

**Files:**
- Create: `internal/ratelimit/config.go`
- Test: `internal/ratelimit/config_test.go`

**Interfaces:**
- Produces:
  - `type Limits struct { MaxConcurrent, RequestsPerMinute, Burst int }` (yaml: `maxConcurrent`, `requestsPerMinute`, `burst`)
  - `type Override struct { MaxConcurrent, RequestsPerMinute, Burst *int }` (same yaml keys)
  - `type Config struct { Default Limits; Overrides map[string]Override }` (yaml: `default`, `overrides`)
  - `func (c *Config) For(account string) Limits`
  - `func (c *Config) Validate() error`

- [ ] **Step 1: Write the failing tests**

`internal/ratelimit/config_test.go`:

```go
package ratelimit

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func intPtr(v int) *int { return &v }

func TestConfig_ForMergesOverrideFieldByField(t *testing.T) {
	cfg := &Config{
		Default: Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10},
		Overrides: map[string]Override{
			"ns/heavy":     {MaxConcurrent: intPtr(16)},
			"ns/unlimited": {MaxConcurrent: intPtr(0), RequestsPerMinute: intPtr(0)},
		},
	}

	tests := []struct {
		account string
		want    Limits
	}{
		{"ns/other", Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10}},
		{"ns/heavy", Limits{MaxConcurrent: 16, RequestsPerMinute: 60, Burst: 10}},
		{"ns/unlimited", Limits{MaxConcurrent: 0, RequestsPerMinute: 0, Burst: 10}},
	}

	for _, tt := range tests {
		if got := cfg.For(tt.account); got != tt.want {
			t.Errorf("For(%q) = %+v, want %+v", tt.account, got, tt.want)
		}
	}
}

func TestConfig_ParseYAML(t *testing.T) {
	data := `
default:
  maxConcurrent: 4
  requestsPerMinute: 60
  burst: 10
overrides:
  team-b/batch-job:
    maxConcurrent: 16
`
	var cfg Config
	if err := yaml.Unmarshal([]byte(data), &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	want := Limits{MaxConcurrent: 16, RequestsPerMinute: 60, Burst: 10}
	if got := cfg.For("team-b/batch-job"); got != want {
		t.Errorf("For(team-b/batch-job) = %+v, want %+v", got, want)
	}
}

func TestConfig_Validate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr string
	}{
		{"empty config is valid", Config{}, ""},
		{"full default", Config{Default: Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10}}, ""},
		{"concurrency only", Config{Default: Limits{MaxConcurrent: 2}}, ""},
		{"negative maxConcurrent", Config{Default: Limits{MaxConcurrent: -1}}, "rateLimits.default: negative values are not allowed"},
		{"rate without burst", Config{Default: Limits{RequestsPerMinute: 60}}, "rateLimits.default: burst must be > 0 when requestsPerMinute is set"},
		{
			"override rate without burst",
			Config{Overrides: map[string]Override{"ns/sa": {RequestsPerMinute: intPtr(10)}}},
			"rateLimits.overrides[ns/sa]: burst must be > 0",
		},
		{
			"override negative burst",
			Config{
				Default:   Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10},
				Overrides: map[string]Override{"ns/sa": {Burst: intPtr(-5)}},
			},
			"rateLimits.overrides[ns/sa]: negative values are not allowed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("error = %v, want containing %q", err, tt.wantErr)
			}
		})
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/ratelimit/ -run TestConfig -v`
Expected: FAIL (build error: `undefined: Config`, `undefined: Limits`, `undefined: Override`)

- [ ] **Step 3: Write the implementation**

`internal/ratelimit/config.go`:

```go
package ratelimit

import (
	"errors"
	"fmt"
)

// Limits are the effective limits for one account. 0 means unlimited.
type Limits struct {
	MaxConcurrent     int `yaml:"maxConcurrent"`
	RequestsPerMinute int `yaml:"requestsPerMinute"`
	Burst             int `yaml:"burst"`
}

// Override replaces individual default fields for one account.
// A nil field inherits the default.
type Override struct {
	MaxConcurrent     *int `yaml:"maxConcurrent"`
	RequestsPerMinute *int `yaml:"requestsPerMinute"`
	Burst             *int `yaml:"burst"`
}

// Config is the rateLimits section of the allowlist file
type Config struct {
	Default   Limits              `yaml:"default"`
	Overrides map[string]Override `yaml:"overrides"`
}

// For returns the effective limits for an account ("namespace/serviceaccount")
func (c *Config) For(account string) Limits {
	l := c.Default
	o, ok := c.Overrides[account]
	if !ok {
		return l
	}
	if o.MaxConcurrent != nil {
		l.MaxConcurrent = *o.MaxConcurrent
	}
	if o.RequestsPerMinute != nil {
		l.RequestsPerMinute = *o.RequestsPerMinute
	}
	if o.Burst != nil {
		l.Burst = *o.Burst
	}
	return l
}

// Validate checks the default and every override's effective limits
func (c *Config) Validate() error {
	if err := c.Default.validate(); err != nil {
		return fmt.Errorf("rateLimits.default: %w", err)
	}
	for account := range c.Overrides {
		if err := c.For(account).validate(); err != nil {
			return fmt.Errorf("rateLimits.overrides[%s]: %w", account, err)
		}
	}
	return nil
}

func (l Limits) validate() error {
	if l.MaxConcurrent < 0 || l.RequestsPerMinute < 0 || l.Burst < 0 {
		return errors.New("negative values are not allowed")
	}
	if l.RequestsPerMinute > 0 && l.Burst == 0 {
		return errors.New("burst must be > 0 when requestsPerMinute is set")
	}
	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/ratelimit/ -run TestConfig -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add internal/ratelimit/config.go internal/ratelimit/config_test.go
git commit -m "feat: add rate limit config types and validation"
```

---

### Task 2: Limiter core and metrics

**Files:**
- Modify: `go.mod`, `go.sum`
- Modify: `internal/metrics/metrics.go`
- Create: `internal/metrics/metrics_test.go`
- Create: `internal/ratelimit/limiter.go`
- Test: `internal/ratelimit/limiter_test.go`

**Interfaces:**
- Consumes: `Config`, `Limits` (Task 1)
- Produces:
  - `metrics.RecordRateLimitRejected(account, reason string)`
  - `metrics.SetRateLimitInflight(account string, n int)`
  - `const ReasonConcurrency = "concurrency"`, `const ReasonRate = "rate"`
  - `type Rejection struct { Reason string; Limit int; RetryAfter time.Duration }`
  - `type Limiter struct { ...; now func() time.Time }` (the `now` field is overridable in same-package tests)
  - `func New() *Limiter`
  - `func (l *Limiter) Update(cfg *Config, allowed map[string]bool)`: `cfg == nil` disables limits. `allowed` is the current allowlist set.
  - `func (l *Limiter) Acquire(account string) (release func(), rej *Rejection)`: on success `rej == nil` and `release` must be called once (extra calls are no-ops). On rejection `release == nil`.

- [ ] **Step 1: Add the dependency**

Run: `go get golang.org/x/time@v0.12.0`
Expected: `go.mod` gains `golang.org/x/time v0.12.0`, and the `go` directive stays `go 1.23.0`. Verify with `grep -n '^go \|x/time' go.mod`.

- [ ] **Step 2: Write the failing metrics test**

`internal/metrics/metrics_test.go`:

```go
package metrics

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestRateLimitMetrics(t *testing.T) {
	RecordRateLimitRejected("metrics-test/sa", "rate")
	RecordRateLimitRejected("metrics-test/sa", "rate")
	if got := testutil.ToFloat64(rateLimitRejectedTotal.WithLabelValues("metrics-test/sa", "rate")); got != 2 {
		t.Errorf("rejected_total = %v, want 2", got)
	}

	SetRateLimitInflight("metrics-test/sa", 3)
	if got := testutil.ToFloat64(rateLimitInflightScans.WithLabelValues("metrics-test/sa")); got != 3 {
		t.Errorf("inflight_scans = %v, want 3", got)
	}
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `go test ./internal/metrics/ -v`
Expected: FAIL (build error: `undefined: RecordRateLimitRejected`)

- [ ] **Step 4: Add the metrics**

In `internal/metrics/metrics.go`, add to the `var (...)` block after `scansTotal`:

```go
	rateLimitRejectedTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "av_ratelimit_rejected_total",
			Help: "Total requests rejected by per-account rate limits",
		},
		[]string{"account", "reason"},
	)

	rateLimitInflightScans = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "av_ratelimit_inflight_scans",
			Help: "In-flight scans per account",
		},
		[]string{"account"},
	)
```

Add to `init()`:

```go
	prometheus.MustRegister(rateLimitRejectedTotal)
	prometheus.MustRegister(rateLimitInflightScans)
```

Add after `RecordScan`:

```go
// RecordRateLimitRejected records a request rejected by per-account rate limits
func RecordRateLimitRejected(account, reason string) {
	rateLimitRejectedTotal.WithLabelValues(account, reason).Inc()
}

// SetRateLimitInflight sets the number of in-flight scans for an account
func SetRateLimitInflight(account string, n int) {
	rateLimitInflightScans.WithLabelValues(account).Set(float64(n))
}
```

Run: `go mod tidy && go test ./internal/metrics/ -v`
Expected: PASS

- [ ] **Step 5: Write the failing limiter tests**

`internal/ratelimit/limiter_test.go`:

```go
package ratelimit

import (
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) Now() time.Time          { return c.t }
func (c *fakeClock) Advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestLimiter(cfg *Config, accounts ...string) (*Limiter, *fakeClock) {
	clock := &fakeClock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	l := New()
	l.now = clock.Now
	l.Update(cfg, allowedSet(accounts...))
	return l, clock
}

func allowedSet(accounts ...string) map[string]bool {
	m := make(map[string]bool)
	for _, a := range accounts {
		m[a] = true
	}
	return m
}

func mustAcquire(t *testing.T, l *Limiter, account string) func() {
	t.Helper()
	release, rej := l.Acquire(account)
	if rej != nil {
		t.Fatalf("Acquire(%q) rejected: %+v", account, rej)
	}
	return release
}

func mustReject(t *testing.T, l *Limiter, account, reason string) *Rejection {
	t.Helper()
	release, rej := l.Acquire(account)
	if rej == nil {
		release()
		t.Fatalf("Acquire(%q) allowed, want %s rejection", account, reason)
	}
	if rej.Reason != reason {
		t.Fatalf("Acquire(%q) reason = %q, want %q", account, rej.Reason, reason)
	}
	return rej
}

func TestLimiter_NilConfigAllowsEverything(t *testing.T) {
	l, _ := newTestLimiter(nil, "ns/sa")
	for i := 0; i < 100; i++ {
		mustAcquire(t, l, "ns/sa")
	}
}

func TestLimiter_Concurrency(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 2}}, "ns/sa")

	r1 := mustAcquire(t, l, "ns/sa")
	mustAcquire(t, l, "ns/sa")

	rej := mustReject(t, l, "ns/sa", ReasonConcurrency)
	if rej.Limit != 2 || rej.RetryAfter != time.Second {
		t.Errorf("rejection = %+v, want Limit=2 RetryAfter=1s", rej)
	}

	r1()
	mustAcquire(t, l, "ns/sa")
}

func TestLimiter_ConcurrencyIsPerAccount(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 1}}, "ns/a", "ns/b")

	mustAcquire(t, l, "ns/a")
	mustReject(t, l, "ns/a", ReasonConcurrency)
	mustAcquire(t, l, "ns/b")
}

func TestLimiter_ReleaseIsIdempotent(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 1}}, "ns/sa")

	r := mustAcquire(t, l, "ns/sa")
	r()
	r() // must not drive the counter negative

	mustAcquire(t, l, "ns/sa")
	mustReject(t, l, "ns/sa", ReasonConcurrency)
}

func TestLimiter_OverrideApplies(t *testing.T) {
	cfg := &Config{
		Default:   Limits{MaxConcurrent: 1},
		Overrides: map[string]Override{"ns/heavy": {MaxConcurrent: intPtr(3)}},
	}
	l, _ := newTestLimiter(cfg, "ns/heavy")

	for i := 0; i < 3; i++ {
		mustAcquire(t, l, "ns/heavy")
	}
	mustReject(t, l, "ns/heavy", ReasonConcurrency)
}

func TestLimiter_Rate(t *testing.T) {
	l, clock := newTestLimiter(&Config{Default: Limits{RequestsPerMinute: 60, Burst: 2}}, "ns/sa")

	mustAcquire(t, l, "ns/sa")()
	mustAcquire(t, l, "ns/sa")()

	rej := mustReject(t, l, "ns/sa", ReasonRate)
	if rej.Limit != 60 {
		t.Errorf("Limit = %d, want 60", rej.Limit)
	}
	if rej.RetryAfter != time.Second {
		t.Errorf("RetryAfter = %v, want 1s (60/min = 1 token/s)", rej.RetryAfter)
	}

	clock.Advance(time.Second)
	mustAcquire(t, l, "ns/sa")()
}

func TestLimiter_RateRejectionDoesNotConsumeTokens(t *testing.T) {
	l, clock := newTestLimiter(&Config{Default: Limits{RequestsPerMinute: 60, Burst: 1}}, "ns/sa")

	mustAcquire(t, l, "ns/sa")()
	for i := 0; i < 5; i++ {
		mustReject(t, l, "ns/sa", ReasonRate)
	}

	clock.Advance(time.Second)
	mustAcquire(t, l, "ns/sa")()
}

func TestLimiter_ConcurrencyRejectionDoesNotConsumeTokens(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 1, RequestsPerMinute: 60, Burst: 2}}, "ns/sa")

	release := mustAcquire(t, l, "ns/sa") // uses token 1 of 2
	for i := 0; i < 5; i++ {
		mustReject(t, l, "ns/sa", ReasonConcurrency)
	}
	release()

	mustAcquire(t, l, "ns/sa") // token 2 must still be there
}

func TestLimiter_UpdateKeepsInflight(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 3}}, "ns/sa")

	r1 := mustAcquire(t, l, "ns/sa")
	r2 := mustAcquire(t, l, "ns/sa")

	l.Update(&Config{Default: Limits{MaxConcurrent: 1}}, allowedSet("ns/sa"))
	rej := mustReject(t, l, "ns/sa", ReasonConcurrency)
	if rej.Limit != 1 {
		t.Errorf("Limit = %d, want 1", rej.Limit)
	}

	r1()
	mustReject(t, l, "ns/sa", ReasonConcurrency) // still 1 in flight
	r2()
	mustAcquire(t, l, "ns/sa")
}

func TestLimiter_UpdateChangesRate(t *testing.T) {
	limited := &Config{Default: Limits{RequestsPerMinute: 60, Burst: 1}}
	l, clock := newTestLimiter(limited, "ns/sa")

	mustAcquire(t, l, "ns/sa")()
	mustReject(t, l, "ns/sa", ReasonRate)

	// Faster rate: 600/min = 1 token per 100ms
	l.Update(&Config{Default: Limits{RequestsPerMinute: 600, Burst: 1}}, allowedSet("ns/sa"))
	clock.Advance(100 * time.Millisecond)
	mustAcquire(t, l, "ns/sa")()

	// Unlimited rate
	l.Update(&Config{}, allowedSet("ns/sa"))
	for i := 0; i < 10; i++ {
		mustAcquire(t, l, "ns/sa")()
	}

	// Limited again: fresh bucket
	l.Update(limited, allowedSet("ns/sa"))
	mustAcquire(t, l, "ns/sa")()
	mustReject(t, l, "ns/sa", ReasonRate)
}

func TestLimiter_UpdateDropsRemovedIdleAccounts(t *testing.T) {
	cfg := &Config{Default: Limits{RequestsPerMinute: 60, Burst: 1}}
	l, _ := newTestLimiter(cfg, "ns/sa")

	mustAcquire(t, l, "ns/sa")() // bucket now empty

	l.Update(cfg, allowedSet())        // removed while idle -> state dropped
	l.Update(cfg, allowedSet("ns/sa")) // re-added

	mustAcquire(t, l, "ns/sa")() // fresh bucket
}

func TestLimiter_RemovedAccountDroppedAfterLastRelease(t *testing.T) {
	cfg := &Config{Default: Limits{RequestsPerMinute: 60, Burst: 1}}
	l, _ := newTestLimiter(cfg, "ns/sa")

	release := mustAcquire(t, l, "ns/sa") // bucket now empty, 1 in flight

	l.Update(cfg, allowedSet()) // removed while busy -> state kept
	release()                   // last release -> state dropped

	l.Update(cfg, allowedSet("ns/sa"))
	mustAcquire(t, l, "ns/sa")() // fresh bucket
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `go test ./internal/ratelimit/ -run TestLimiter -v`
Expected: FAIL (build error: `undefined: New`, `undefined: Rejection`)

- [ ] **Step 7: Write the implementation**

`internal/ratelimit/limiter.go`:

```go
package ratelimit

import (
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/rophy/av-scanner/internal/metrics"
)

// Rejection reasons
const (
	ReasonConcurrency = "concurrency"
	ReasonRate        = "rate"
)

// Rejection describes why a request was rejected
type Rejection struct {
	Reason     string
	Limit      int
	RetryAfter time.Duration
}

type accountState struct {
	inflight int
	rate     *rate.Limiter // nil when requestsPerMinute is 0
}

// Limiter enforces per-account concurrency and request-rate limits in memory
type Limiter struct {
	mu       sync.Mutex
	cfg      *Config // nil = no limits
	allowed  map[string]bool
	accounts map[string]*accountState
	now      func() time.Time
}

// New creates a Limiter with no limits until Update is called
func New() *Limiter {
	return &Limiter{
		accounts: make(map[string]*accountState),
		now:      time.Now,
	}
}

// Update replaces the limits. cfg nil disables limiting. allowed is the
// current allowlist; idle state for accounts no longer in it is dropped.
// In-flight counts are preserved.
func (l *Limiter) Update(cfg *Config, allowed map[string]bool) {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.cfg = cfg
	l.allowed = allowed
	now := l.now()
	for account, st := range l.accounts {
		if !allowed[account] && st.inflight == 0 {
			delete(l.accounts, account)
			continue
		}
		l.applyRate(account, st, now)
	}
}

// Acquire reserves a scan slot for account. On success the caller must call
// release when the request finishes; extra calls are no-ops.
func (l *Limiter) Acquire(account string) (release func(), rej *Rejection) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.cfg == nil {
		return func() {}, nil
	}

	now := l.now()
	st, ok := l.accounts[account]
	if !ok {
		st = &accountState{}
		l.applyRate(account, st, now)
		l.accounts[account] = st
	}
	limits := l.cfg.For(account)

	if limits.MaxConcurrent > 0 && st.inflight >= limits.MaxConcurrent {
		metrics.RecordRateLimitRejected(account, ReasonConcurrency)
		return nil, &Rejection{Reason: ReasonConcurrency, Limit: limits.MaxConcurrent, RetryAfter: time.Second}
	}

	if st.rate != nil {
		r := st.rate.ReserveN(now, 1)
		if delay := r.DelayFrom(now); !r.OK() || delay > 0 {
			r.CancelAt(now)
			metrics.RecordRateLimitRejected(account, ReasonRate)
			return nil, &Rejection{Reason: ReasonRate, Limit: limits.RequestsPerMinute, RetryAfter: delay}
		}
	}

	st.inflight++
	metrics.SetRateLimitInflight(account, st.inflight)

	var once sync.Once
	return func() { once.Do(func() { l.release(account, st) }) }, nil
}

func (l *Limiter) release(account string, st *accountState) {
	l.mu.Lock()
	defer l.mu.Unlock()

	st.inflight--
	metrics.SetRateLimitInflight(account, st.inflight)
	if st.inflight == 0 && l.allowed != nil && !l.allowed[account] && l.accounts[account] == st {
		delete(l.accounts, account)
	}
}

// applyRate creates, updates, or removes the account's token bucket to match
// the current config. Caller must hold l.mu.
func (l *Limiter) applyRate(account string, st *accountState, now time.Time) {
	var limits Limits
	if l.cfg != nil {
		limits = l.cfg.For(account)
	}
	if limits.RequestsPerMinute == 0 {
		st.rate = nil
		return
	}
	r := rate.Limit(float64(limits.RequestsPerMinute) / 60)
	if st.rate == nil {
		st.rate = rate.NewLimiter(r, limits.Burst)
		return
	}
	st.rate.SetLimitAt(now, r)
	st.rate.SetBurstAt(now, limits.Burst)
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `go test ./internal/ratelimit/ ./internal/metrics/ -race -v`
Expected: PASS, no race reports

- [ ] **Step 9: Commit**

```bash
git add go.mod go.sum internal/metrics/ internal/ratelimit/limiter.go internal/ratelimit/limiter_test.go
git commit -m "feat: add per-account limiter with concurrency and rate limits"
```

---

### Task 3: HTTP middleware

**Files:**
- Create: `internal/ratelimit/middleware.go`
- Test: `internal/ratelimit/middleware_test.go`

**Interfaces:**
- Consumes: `Limiter.Acquire`, `Rejection`, `ReasonConcurrency`, `ReasonRate` (Task 2); `newTestLimiter`, `mustAcquire` test helpers (Task 2, same package)
- Produces: `func (l *Limiter) Handler(identity func(*http.Request) string, logger *slog.Logger, next http.Handler) http.Handler`. An empty identity passes through without limiting.

- [ ] **Step 1: Write the failing tests**

`internal/ratelimit/middleware_test.go`:

```go
package ratelimit

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func fixedIdentity(account string) func(*http.Request) string {
	return func(*http.Request) string { return account }
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
}

func scanRequest() *http.Request {
	return httptest.NewRequest(http.MethodPost, "/api/v1/scan", nil)
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]string {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", rec.Body.String(), err)
	}
	return body
}

func TestHandler_RateRejection(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{RequestsPerMinute: 1, Burst: 1}}, "ns/sa")
	h := l.Handler(fixedIdentity("ns/sa"), testLogger(), okHandler())

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, scanRequest())
	if rec.Code != http.StatusOK {
		t.Fatalf("first request: status %d, want 200", rec.Code)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, scanRequest())
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request: status %d, want 429", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "60" {
		t.Errorf("Retry-After = %q, want 60", got)
	}
	if got := rec.Header().Get("Connection"); got != "close" {
		t.Errorf("Connection = %q, want close", got)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	body := decodeBody(t, rec)
	if body["reason"] != ReasonRate {
		t.Errorf("reason = %q, want rate", body["reason"])
	}
	if want := "rate limit exceeded for ns/sa: requests per minute (1)"; body["error"] != want {
		t.Errorf("error = %q, want %q", body["error"], want)
	}
}

func TestHandler_ConcurrencyRejection(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 2}}, "ns/sa")

	entered := make(chan struct{})
	unblock := make(chan struct{})
	h := l.Handler(fixedIdentity("ns/sa"), testLogger(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		<-unblock
		w.WriteHeader(http.StatusOK)
	}))

	var wg sync.WaitGroup
	codes := make([]int, 2)
	for i := range codes {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, scanRequest())
			codes[i] = rec.Code
		}(i)
	}
	<-entered
	<-entered // both slots held

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, scanRequest())
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third request: status %d, want 429", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "1" {
		t.Errorf("Retry-After = %q, want 1", got)
	}
	body := decodeBody(t, rec)
	if body["reason"] != ReasonConcurrency {
		t.Errorf("reason = %q, want concurrency", body["reason"])
	}
	if want := "rate limit exceeded for ns/sa: concurrent scans (2/2)"; body["error"] != want {
		t.Errorf("error = %q, want %q", body["error"], want)
	}

	close(unblock)
	wg.Wait()
	for i, c := range codes {
		if c != http.StatusOK {
			t.Errorf("blocked request %d: status %d, want 200", i, c)
		}
	}

	// Both slots released
	mustAcquire(t, l, "ns/sa")
	mustAcquire(t, l, "ns/sa")
}

type failingReader struct{ t *testing.T }

func (f failingReader) Read([]byte) (int, error) {
	f.t.Error("request body was read on a rejected request")
	return 0, io.EOF
}

func TestHandler_RejectionDoesNotReadBody(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{RequestsPerMinute: 1, Burst: 1}}, "ns/sa")
	mustAcquire(t, l, "ns/sa")() // exhaust the bucket

	h := l.Handler(fixedIdentity("ns/sa"), testLogger(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("next handler called on a rejected request")
	}))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/scan", failingReader{t}))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status %d, want 429", rec.Code)
	}
}

func TestHandler_ReleasesSlotOnPanic(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{MaxConcurrent: 1}}, "ns/sa")
	h := l.Handler(fixedIdentity("ns/sa"), testLogger(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("boom")
	}))

	func() {
		defer func() { recover() }()
		h.ServeHTTP(httptest.NewRecorder(), scanRequest())
	}()

	mustAcquire(t, l, "ns/sa")
}

func TestHandler_EmptyIdentityPassesThrough(t *testing.T) {
	l, _ := newTestLimiter(&Config{Default: Limits{RequestsPerMinute: 1, Burst: 1}}, "ns/sa")
	h := l.Handler(fixedIdentity(""), testLogger(), okHandler())

	for i := 0; i < 3; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, scanRequest())
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: status %d, want 200", i, rec.Code)
		}
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/ratelimit/ -run TestHandler -v`
Expected: FAIL (build error: `l.Handler undefined`)

- [ ] **Step 3: Write the implementation**

`internal/ratelimit/middleware.go`:

```go
package ratelimit

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"strconv"
)

// Handler enforces limits for the account returned by identity before
// calling next. Requests with an empty identity pass through unchanged.
// Rejected requests get 429 without the body being read.
func (l *Limiter) Handler(identity func(*http.Request) string, logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		account := identity(r)
		if account == "" {
			next.ServeHTTP(w, r)
			return
		}

		release, rej := l.Acquire(account)
		if rej != nil {
			logger.Warn("Rate limit exceeded",
				"identity", account,
				"reason", rej.Reason,
				"limit", rej.Limit,
				"path", r.URL.Path,
				"method", r.Method,
			)
			writeRejection(w, account, rej)
			return
		}
		defer release()

		next.ServeHTTP(w, r)
	})
}

func writeRejection(w http.ResponseWriter, account string, rej *Rejection) {
	retryAfter := int(math.Ceil(rej.RetryAfter.Seconds()))
	if retryAfter < 1 {
		retryAfter = 1
	}

	var message string
	switch rej.Reason {
	case ReasonConcurrency:
		message = fmt.Sprintf("rate limit exceeded for %s: concurrent scans (%d/%d)", account, rej.Limit, rej.Limit)
	default:
		message = fmt.Sprintf("rate limit exceeded for %s: requests per minute (%d)", account, rej.Limit)
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	w.Header().Set("Connection", "close")
	w.WriteHeader(http.StatusTooManyRequests)
	json.NewEncoder(w).Encode(map[string]string{"error": message, "reason": rej.Reason})
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/ratelimit/ -race -v`
Expected: PASS (all Config, Limiter, Handler tests), no race reports

- [ ] **Step 5: Commit**

```bash
git add internal/ratelimit/middleware.go internal/ratelimit/middleware_test.go
git commit -m "feat: add rate limit HTTP middleware with 429 responses"
```

---

### Task 4: Allowlist integration and API wiring

**Files:**
- Modify: `internal/auth/allowlist.go` (struct, `NewAllowlist`, `load`)
- Test: `internal/auth/allowlist_test.go` (append)
- Modify: `internal/api/handlers.go` (struct, `New`, `Routes`)
- Test: `internal/api/handlers_test.go` (append)

**Interfaces:**
- Consumes: `ratelimit.Config`, `ratelimit.New`, `(*Limiter).Update`, `(*Limiter).Acquire`, `(*Limiter).Handler`, `ratelimit.ReasonConcurrency` (Tasks 1–3); existing `auth.GetCallerIdentity`
- Produces:
  - `AllowlistConfig.RateLimits *ratelimit.Config` (yaml `rateLimits`)
  - `func NewAllowlistWithLimiter(filePath string, logger *slog.Logger, limiter *ratelimit.Limiter) (*Allowlist, error)`. `NewAllowlist(filePath, logger)` keeps its signature and calls this with `nil`.

- [ ] **Step 1: Write the failing allowlist tests**

Append to `internal/auth/allowlist_test.go`. Add `"bytes"`, `"log/slog"`, `"strings"` and `"github.com/rophy/av-scanner/internal/ratelimit"` to its imports.

```go
func writeAllowlistFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "allowlist.yaml")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write allowlist: %v", err)
	}
	return path
}

func TestAllowlist_RateLimitsAppliedToLimiter(t *testing.T) {
	path := writeAllowlistFile(t, `allowlist:
  - ns/sa
rateLimits:
  default:
    maxConcurrent: 1
`)
	limiter := ratelimit.New()
	if _, err := NewAllowlistWithLimiter(path, testLogger(), limiter); err != nil {
		t.Fatalf("NewAllowlistWithLimiter: %v", err)
	}

	release, rej := limiter.Acquire("ns/sa")
	if rej != nil {
		t.Fatalf("first Acquire rejected: %+v", rej)
	}
	defer release()

	if _, rej := limiter.Acquire("ns/sa"); rej == nil || rej.Reason != ratelimit.ReasonConcurrency {
		t.Fatalf("second Acquire = %+v, want concurrency rejection", rej)
	}
}

func TestAllowlist_NoRateLimitsMeansUnlimited(t *testing.T) {
	path := writeAllowlistFile(t, `allowlist:
  - ns/sa
`)
	limiter := ratelimit.New()
	if _, err := NewAllowlistWithLimiter(path, testLogger(), limiter); err != nil {
		t.Fatalf("NewAllowlistWithLimiter: %v", err)
	}

	for i := 0; i < 10; i++ {
		if _, rej := limiter.Acquire("ns/sa"); rej != nil {
			t.Fatalf("Acquire %d rejected: %+v", i, rej)
		}
	}
}

func TestAllowlist_InvalidRateLimitsFailsAtStartup(t *testing.T) {
	path := writeAllowlistFile(t, `allowlist:
  - ns/sa
rateLimits:
  default:
    requestsPerMinute: 60
`)
	_, err := NewAllowlistWithLimiter(path, testLogger(), ratelimit.New())
	if err == nil || !strings.Contains(err.Error(), "burst must be > 0") {
		t.Fatalf("err = %v, want burst validation error", err)
	}
}

func TestAllowlist_InvalidRateLimitsReloadKeepsPrevious(t *testing.T) {
	path := writeAllowlistFile(t, `allowlist:
  - ns/sa
rateLimits:
  default:
    maxConcurrent: 1
`)
	limiter := ratelimit.New()
	a, err := NewAllowlistWithLimiter(path, testLogger(), limiter)
	if err != nil {
		t.Fatalf("NewAllowlistWithLimiter: %v", err)
	}

	invalid := `allowlist:
  - ns/sa
  - ns/new
rateLimits:
  default:
    maxConcurrent: -1
`
	if err := os.WriteFile(path, []byte(invalid), 0644); err != nil {
		t.Fatalf("failed to write allowlist: %v", err)
	}
	if err := a.load(); err == nil {
		t.Fatal("load() succeeded on invalid rateLimits, want error")
	}

	if a.IsAllowed("ns", "new") {
		t.Error("allowlist changed on rejected reload")
	}
	release, rej := limiter.Acquire("ns/sa")
	if rej != nil {
		t.Fatalf("first Acquire rejected: %+v", rej)
	}
	defer release()
	if _, rej := limiter.Acquire("ns/sa"); rej == nil {
		t.Fatal("previous maxConcurrent=1 no longer enforced after rejected reload")
	}
}

func TestAllowlist_OverrideForUnknownAccountWarns(t *testing.T) {
	path := writeAllowlistFile(t, `allowlist:
  - ns/sa
rateLimits:
  overrides:
    ns/ghost:
      maxConcurrent: 5
`)
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))

	if _, err := NewAllowlistWithLimiter(path, logger, ratelimit.New()); err != nil {
		t.Fatalf("NewAllowlistWithLimiter: %v", err)
	}
	out := buf.String()
	if !strings.Contains(out, "not in allowlist") || !strings.Contains(out, "ns/ghost") {
		t.Errorf("expected warning about ns/ghost, got log: %s", out)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/auth/ -run TestAllowlist -v`
Expected: FAIL (build error: `undefined: NewAllowlistWithLimiter`)

- [ ] **Step 3: Implement the allowlist changes**

In `internal/auth/allowlist.go`:

Add the import `"github.com/rophy/av-scanner/internal/ratelimit"`.

Replace `AllowlistConfig`:

```go
// AllowlistConfig represents the YAML structure of the allowlist file
type AllowlistConfig struct {
	Allowlist  []string          `yaml:"allowlist"`
	RateLimits *ratelimit.Config `yaml:"rateLimits"`
}
```

Add a field to `Allowlist` (after `stopCh`):

```go
	limiter  *ratelimit.Limiter // optional; receives rateLimits on every load
```

Replace `NewAllowlist` with:

```go
// NewAllowlist creates a new Allowlist and loads entries from the given file
func NewAllowlist(filePath string, logger *slog.Logger) (*Allowlist, error) {
	return NewAllowlistWithLimiter(filePath, logger, nil)
}

// NewAllowlistWithLimiter creates a new Allowlist that also pushes the file's
// rateLimits section to limiter on load and on every reload
func NewAllowlistWithLimiter(filePath string, logger *slog.Logger, limiter *ratelimit.Limiter) (*Allowlist, error) {
	a := &Allowlist{
		entries:  make(map[string]bool),
		filePath: filePath,
		logger:   logger,
		stopCh:   make(chan struct{}),
		limiter:  limiter,
	}

	if err := a.load(); err != nil {
		return nil, err
	}

	return a, nil
}
```

In `load()`, after the `entries` map is built and **before** `a.mu.Lock()`, add validation. Then after `a.mu.Unlock()`, push to the limiter. The tail of `load()` becomes:

```go
	entries := make(map[string]bool)
	for _, entry := range config.Allowlist {
		entries[entry] = true
	}

	if config.RateLimits != nil {
		if err := config.RateLimits.Validate(); err != nil {
			return fmt.Errorf("invalid allowlist file: %w", err)
		}
		for account := range config.RateLimits.Overrides {
			if !entries[account] {
				a.logger.Warn("Rate limit override for account not in allowlist, ignoring", "account", account)
			}
		}
	}

	a.mu.Lock()
	a.entries = entries
	a.mu.Unlock()

	if a.limiter != nil {
		a.limiter.Update(config.RateLimits, entries)
	}

	a.logger.Info("Allowlist loaded", "entries", len(entries), "rateLimits", config.RateLimits != nil)
	return nil
}
```

- [ ] **Step 4: Run the allowlist tests**

Run: `go test ./internal/auth/ -v`
Expected: PASS (new and existing tests)

- [ ] **Step 5: Write the failing API wiring test**

Append to `internal/api/handlers_test.go`. Add `"path/filepath"` and `"strings"` to its imports.

```go
// newAuthTestAPI returns the API router with auth enabled against a mock
// TokenReview server that authenticates every token as ns/sa.
func newAuthTestAPI(t *testing.T, allowlist string) http.Handler {
	t.Helper()

	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"apiVersion":"authentication.k8s.io/v1","kind":"TokenReview","status":{"authenticated":true,"user":{"username":"system:serviceaccount:ns:sa","uid":"uid-1"}}}`))
	}))
	t.Cleanup(authServer.Close)

	tmpDir := t.TempDir()
	allowlistFile := filepath.Join(tmpDir, "allowlist.yaml")
	if err := os.WriteFile(allowlistFile, []byte(allowlist), 0644); err != nil {
		t.Fatalf("failed to write allowlist: %v", err)
	}

	cfg := &config.Config{
		Port:         3000,
		UploadDir:    tmpDir,
		MaxFileSize:  10 * 1024 * 1024,
		ActiveEngine: config.EngineMock,
		LogLevel:     "error",
		Drivers: map[config.EngineType]config.DriverConfig{
			config.EngineClamAV:     {Engine: config.EngineClamAV},
			config.EngineTrendMicro: {Engine: config.EngineTrendMicro},
		},
		Auth: config.AuthConfig{
			Enabled:        true,
			K8sAPIEndpoint: authServer.URL,
			Timeout:        5000,
			AllowlistFile:  allowlistFile,
		},
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := scanner.New(cfg, logger)
	api, err := New(s, cfg, logger)
	if err != nil {
		t.Fatalf("failed to create API: %v", err)
	}
	t.Cleanup(func() { api.Close() })

	return api.Routes()
}

func TestAPI_ScanIsRateLimitedPerAccount(t *testing.T) {
	h := newAuthTestAPI(t, `allowlist:
  - ns/sa
rateLimits:
  default:
    requestsPerMinute: 1
    burst: 1
`)

	scan := func() *httptest.ResponseRecorder {
		body, contentType := createMultipartFile(t, "file", "clean.txt", []byte("This is a clean file"))
		req := httptest.NewRequest(http.MethodPost, "/api/v1/scan", body)
		req.Header.Set("Content-Type", contentType)
		req.Header.Set("Authorization", "Bearer test-token")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		return rr
	}

	if rr := scan(); rr.Code != http.StatusOK {
		t.Fatalf("first scan: status %d: %s", rr.Code, rr.Body.String())
	}

	rr := scan()
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("second scan: status %d, want 429: %s", rr.Code, rr.Body.String())
	}
	var resp map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}
	if resp["reason"] != "rate" {
		t.Errorf("reason = %q, want rate", resp["reason"])
	}

	// Non-scan endpoints are not limited
	for i := 0; i < 3; i++ {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
		req.Header.Set("Authorization", "Bearer test-token")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("health %d: status %d, want 200", i, rr.Code)
		}
	}

	// Rejection is visible in metrics
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	mr := httptest.NewRecorder()
	h.ServeHTTP(mr, req)
	want := `av_ratelimit_rejected_total{account="ns/sa",reason="rate"}`
	if !strings.Contains(mr.Body.String(), want) {
		t.Errorf("metrics missing %s", want)
	}
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `go test ./internal/api/ -run TestAPI_ScanIsRateLimitedPerAccount -v`
Expected: FAIL (`second scan: status 200, want 429`). The test compiles, but nothing is wired yet.

- [ ] **Step 7: Wire the limiter into the API**

In `internal/api/handlers.go`:

Add the import `"github.com/rophy/av-scanner/internal/ratelimit"`.

Add a field to `API`:

```go
	limiter        *ratelimit.Limiter
```

In `New`, replace the allowlist creation block:

```go
		// Load allowlist (and its optional rateLimits section)
		limiter := ratelimit.New()
		allowlist, err := auth.NewAllowlistWithLimiter(cfg.Auth.AllowlistFile, logger, limiter)
		if err != nil {
			return nil, err
		}
```

and next to `api.allowlist = allowlist` add:

```go
		api.limiter = limiter
```

In `Routes`, replace `mux.HandleFunc("POST /api/v1/scan", a.handleScan)` with:

```go
	// Scan is the only rate-limited route; it runs inside auth, so the
	// caller identity is already in the request context
	var scan http.Handler = http.HandlerFunc(a.handleScan)
	if a.limiter != nil {
		scan = a.limiter.Handler(callerAccount, a.logger, scan)
	}
	mux.Handle("POST /api/v1/scan", scan)
```

Add after `Close`:

```go
// callerAccount returns "namespace/serviceaccount" for the authenticated caller
func callerAccount(r *http.Request) string {
	id := auth.GetCallerIdentity(r.Context())
	if id == nil {
		return ""
	}
	return id.Namespace + "/" + id.ServiceAccount
}
```

- [ ] **Step 8: Run all unit tests**

Run: `make test-unit` and `go test ./... -race`
Expected: PASS for all packages

- [ ] **Step 9: Commit**

```bash
git add internal/auth/allowlist.go internal/auth/allowlist_test.go internal/api/handlers.go internal/api/handlers_test.go
git commit -m "feat: load rate limits from allowlist and limit scan endpoint"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/api.md` (Authentication section)
- Modify: `docs/deployment.md` (Authentication variables table)

**Interfaces:**
- Consumes: config semantics from Tasks 1–4
- Produces: user-facing docs

- [ ] **Step 1: Document rate limits in `docs/api.md`**

After the `### Allowlist` subsection (ending "The file is watched and reloaded automatically on change."), insert:

````markdown
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
- Changes are hot-reloaded. An invalid file is rejected and the previous config stays active.

Rejected requests get `429` with a `Retry-After` header (seconds):

```json
{"error": "rate limit exceeded for team-a/uploader: concurrent scans (4/4)", "reason": "concurrency"}
```

`reason` is `concurrency` or `rate`. Metrics: `av_ratelimit_rejected_total{account,reason}`, `av_ratelimit_inflight_scans{account}`.
````

Add to the `### Error responses` table:

```markdown
| 429 | Per-account rate limit exceeded (`reason`: `concurrency` or `rate`) |
```

- [ ] **Step 2: Document the Ansible variable in `docs/deployment.md`**

In the `#### Authentication` table, add after the `auth_allowlist_file` row:

```markdown
| `auth_allowlist_content` | (none) | Allowlist file content: `allowlist` and optional `rateLimits` (see [API docs](api.md#rate-limits)) |
```

- [ ] **Step 3: Commit**

```bash
git add docs/api.md docs/deployment.md
git commit -m "docs: document per-account rate limits"
```

---

### Task 6: E2E tests and full regression

**Files:**
- Modify: `test/e2e/setup_suite.bash` (generated allowlist)
- Modify: `test/e2e/01_e2e.bats` (SAs in `setup_file`, new tests)

**Interfaces:**
- Consumes: deployed behavior from Tasks 1–4; existing helpers `get_sa_token`, `assert_json_field`, `_kubectl`, and the `E2E_VM1_IP` env var
- Produces: e2e coverage

- [ ] **Step 1: Add the limited accounts to the e2e allowlist**

In `test/e2e/setup_suite.bash`, replace the `auth_allowlist_content` block inside the `VALEOF` heredoc with:

```yaml
      auth_allowlist_content: |
        allowlist:
          - test-client/scanner-client
          - test-client/rate-client
          - test-client/concurrency-client
          - av-scanner/av-scanner
        rateLimits:
          overrides:
            test-client/rate-client:
              requestsPerMinute: 1
              burst: 1
            test-client/concurrency-client:
              maxConcurrent: 1
```

There is no `default`, so all other accounts stay unlimited and the existing tests are unaffected.

- [ ] **Step 2: Create the ServiceAccounts**

In `test/e2e/01_e2e.bats` `setup_file`, after the `scanner-client` creation line, add:

```bash
    _kubectl -n test-client create serviceaccount rate-client --dry-run=client -o yaml | _kubectl apply -f -
    _kubectl -n test-client create serviceaccount concurrency-client --dry-run=client -o yaml | _kubectl apply -f -
```

- [ ] **Step 3: Add the e2e tests**

In `test/e2e/01_e2e.bats`, insert before the `# API test playbook` section:

```bash
# ============================================
# Rate limit tests (direct to VM1 — limits are per instance)
# ============================================

@test "rate limit: second scan within the window gets 429" {
    local token
    token=$(get_sa_token "test-client" "rate-client")
    local url="http://${E2E_VM1_IP}:3000/api/v1/scan"

    local first
    first=$(echo "clean" | curl -4 -s -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" \
        -F "file=@-;filename=first.txt" "$url")
    [[ "$first" == "200" ]] || { echo "ERROR: first scan expected 200, got $first"; false; }

    local headers="${BATS_TEST_TMPDIR}/headers"
    local body
    body=$(echo "clean" | curl -4 -s -D "$headers" -X POST \
        -H "Authorization: Bearer ${token}" \
        -F "file=@-;filename=second.txt" "$url")

    grep -q "^HTTP/1.1 429" "$headers" || {
        echo "ERROR: expected 429"; cat "$headers"; echo "$body"; false
    }
    grep -qi "^Retry-After: [1-9]" "$headers" || {
        echo "ERROR: missing Retry-After"; cat "$headers"; false
    }
    assert_json_field "$body" '.reason' 'rate'

    curl -4 -s "http://${E2E_VM1_IP}:3000/metrics" \
        | grep -q 'av_ratelimit_rejected_total{account="test-client/rate-client",reason="rate"}' || {
        echo "ERROR: av_ratelimit_rejected_total not recorded"; false
    }
}

@test "rate limit: concurrent scan over maxConcurrent gets 429" {
    local token
    token=$(get_sa_token "test-client" "concurrency-client")
    local url="http://${E2E_VM1_IP}:3000/api/v1/scan"

    # 1MB uploaded at 100KB/s holds the slot for ~10s: the slot is acquired
    # before the body is read. "Expect:" disables 100-continue.
    local slow_file="${BATS_TEST_TMPDIR}/slow.bin"
    head -c 1048576 /dev/zero > "$slow_file"
    curl -4 -s -o "${BATS_TEST_TMPDIR}/slow.body" -w '%{http_code}' \
        --limit-rate 100K -H "Expect:" -X POST \
        -H "Authorization: Bearer ${token}" \
        -F "file=@${slow_file};filename=slow.bin" "$url" \
        > "${BATS_TEST_TMPDIR}/slow.code" &
    local slow_pid=$!

    sleep 2

    local body code
    body=$(echo "clean" | curl -4 -s -w '\n%{http_code}' -X POST \
        -H "Authorization: Bearer ${token}" \
        -F "file=@-;filename=fast.txt" "$url")
    code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')

    wait "$slow_pid"
    local slow_code
    slow_code=$(cat "${BATS_TEST_TMPDIR}/slow.code")

    # A 401 here would be a reproduction of issue #15
    [[ "$code" == "429" ]] || { echo "ERROR: concurrent scan expected 429, got $code: $body"; false; }
    assert_json_field "$body" '.reason' 'concurrency'
    [[ "$slow_code" == "200" ]] || {
        echo "ERROR: slow scan expected 200, got $slow_code: $(cat "${BATS_TEST_TMPDIR}/slow.body")"; false
    }
}
```

- [ ] **Step 4: Run the full regression suite**

Prerequisite: `make env` has succeeded (VMs, minikube profile `av-scanner`, Istio, kfa).

Run: `make test-unit test-helm test-molecule test-e2e`
Expected: all pass. If the concurrency e2e test gets 401 instead of 429, stop and investigate it as issue #15 (do not weaken the test).

- [ ] **Step 5: Commit**

```bash
git add test/e2e/setup_suite.bash test/e2e/01_e2e.bats
git commit -m "test: add e2e coverage for per-account rate limits"
```
