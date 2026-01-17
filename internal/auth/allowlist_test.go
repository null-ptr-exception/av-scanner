package auth

import (
	"os"
	"path/filepath"
	"testing"
	"time"
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
