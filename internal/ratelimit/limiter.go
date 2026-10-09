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

	now := l.now()
	st, ok := l.accounts[account]
	if !ok {
		st = &accountState{}
		l.applyRate(account, st, now)
		l.accounts[account] = st
	}

	// In-flight scans are counted even with no limits configured, so limits
	// enabled by a later reload see scans that are already running
	var limits Limits
	if l.cfg != nil {
		limits = l.cfg.For(account)
	}

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
