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

func TestLimiter_NilConfigStillTracksInflight(t *testing.T) {
	l, _ := newTestLimiter(nil, "ns/sa")

	release := mustAcquire(t, l, "ns/sa") // running before limits exist

	l.Update(&Config{Default: Limits{MaxConcurrent: 1}}, allowedSet("ns/sa"))
	mustReject(t, l, "ns/sa", ReasonConcurrency)

	release()
	mustAcquire(t, l, "ns/sa")
}
