package auth

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rophy/av-scanner/internal/ratelimit"
)

func TestAllowlist_LoadAndCheck(t *testing.T) {
	// Create temp file
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "allowlist.yaml")

	content := `allowlist:
  - ns1/sa1
  - ns2/sa2
  - kube-system/default
`
	if err := os.WriteFile(tmpFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	allowlist, err := NewAllowlist(tmpFile, testLogger())
	if err != nil {
		t.Fatalf("failed to create allowlist: %v", err)
	}

	tests := []struct {
		namespace      string
		serviceAccount string
		expected       bool
	}{
		{"ns1", "sa1", true},
		{"ns2", "sa2", true},
		{"kube-system", "default", true},
		{"ns1", "sa2", false},
		{"ns3", "sa1", false},
	}

	for _, tt := range tests {
		result := allowlist.IsAllowed(tt.namespace, tt.serviceAccount)
		if result != tt.expected {
			t.Errorf("IsAllowed(%s, %s) = %v, expected %v",
				tt.namespace, tt.serviceAccount, result, tt.expected)
		}
	}
}

func TestAllowlist_EmptyFile(t *testing.T) {
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "allowlist.yaml")

	content := `allowlist: []`
	if err := os.WriteFile(tmpFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	allowlist, err := NewAllowlist(tmpFile, testLogger())
	if err != nil {
		t.Fatalf("failed to create allowlist: %v", err)
	}

	if allowlist.IsAllowed("ns1", "sa1") {
		t.Error("expected false for empty allowlist")
	}
}

func TestAllowlist_FileNotFound(t *testing.T) {
	_, err := NewAllowlist("/nonexistent/allowlist.yaml", testLogger())
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
}

func TestAllowlist_InvalidYAML(t *testing.T) {
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "allowlist.yaml")

	content := `this is not valid yaml: [`
	if err := os.WriteFile(tmpFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	_, err := NewAllowlist(tmpFile, testLogger())
	if err == nil {
		t.Fatal("expected error for invalid YAML")
	}
}

func TestAllowlist_Reload(t *testing.T) {
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "allowlist.yaml")

	// Initial content
	content := `allowlist:
  - ns1/sa1
`
	if err := os.WriteFile(tmpFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	allowlist, err := NewAllowlist(tmpFile, testLogger())
	if err != nil {
		t.Fatalf("failed to create allowlist: %v", err)
	}

	// Start watching
	if err := allowlist.Watch(); err != nil {
		t.Fatalf("failed to start watching: %v", err)
	}
	defer allowlist.Close()

	// Verify initial state
	if !allowlist.IsAllowed("ns1", "sa1") {
		t.Error("expected ns1/sa1 to be allowed initially")
	}
	if allowlist.IsAllowed("ns2", "sa2") {
		t.Error("expected ns2/sa2 to NOT be allowed initially")
	}

	// Update file
	newContent := `allowlist:
  - ns1/sa1
  - ns2/sa2
`
	if err := os.WriteFile(tmpFile, []byte(newContent), 0644); err != nil {
		t.Fatalf("failed to update temp file: %v", err)
	}

	// Wait for reload
	time.Sleep(100 * time.Millisecond)

	// Verify new state
	if !allowlist.IsAllowed("ns1", "sa1") {
		t.Error("expected ns1/sa1 to be allowed after reload")
	}
	if !allowlist.IsAllowed("ns2", "sa2") {
		t.Error("expected ns2/sa2 to be allowed after reload")
	}
}

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
