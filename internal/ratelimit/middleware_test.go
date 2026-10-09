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
