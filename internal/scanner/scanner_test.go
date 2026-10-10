package scanner

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/rophy/av-scanner/internal/cache"
	"github.com/rophy/av-scanner/internal/config"
	"github.com/rophy/av-scanner/internal/drivers"
)

func newTestScanner(t *testing.T) (*Scanner, string) {
	t.Helper()

	tmpDir, err := os.MkdirTemp("", "av-scanner-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}

	cfg := &config.Config{
		Port:         3000,
		UploadDir:    tmpDir,
		MaxFileSize:  10 * 1024 * 1024,
		ActiveEngine: config.EngineMock,
		LogLevel:     "debug",
		Drivers: map[config.EngineType]config.DriverConfig{
			config.EngineClamAV:     {Engine: config.EngineClamAV},
			config.EngineTrendMicro: {Engine: config.EngineTrendMicro},
		},
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelError}))
	s := New(cfg, logger)

	return s, tmpDir
}

func TestScanner_ScanCleanFile(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	// Create a clean file
	filePath := filepath.Join(tmpDir, "clean.txt")
	if err := os.WriteFile(filePath, []byte("This is a clean file"), 0644); err != nil {
		t.Fatalf("failed to create test file: %v", err)
	}

	result, err := s.Scan(filePath, "test-id-1", "clean.txt", 21)
	if err != nil {
		t.Fatalf("scan failed: %v", err)
	}

	if result.Status != drivers.StatusClean {
		t.Errorf("expected status clean, got %s", result.Status)
	}
	if result.Engine != config.EngineMock {
		t.Errorf("expected engine mock, got %s", result.Engine)
	}
	if result.Signature != "" {
		t.Errorf("expected no signature for clean file, got %s", result.Signature)
	}
}

func TestScanner_ScanInfectedFile(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	// Create an infected file with EICAR pattern
	filePath := filepath.Join(tmpDir, "infected.txt")
	if err := os.WriteFile(filePath, []byte(drivers.EICARPattern()), 0644); err != nil {
		t.Fatalf("failed to create test file: %v", err)
	}

	result, err := s.Scan(filePath, "test-id-2", "infected.txt", 68)
	if err != nil {
		t.Fatalf("scan failed: %v", err)
	}

	if result.Status != drivers.StatusInfected {
		t.Errorf("expected status infected, got %s", result.Status)
	}
	if result.Engine != config.EngineMock {
		t.Errorf("expected engine mock, got %s", result.Engine)
	}
	if result.Signature != drivers.EICARSignature {
		t.Errorf("expected signature %s, got %s", drivers.EICARSignature, result.Signature)
	}
}

func TestScanner_ScanDeletesFile(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	filePath := filepath.Join(tmpDir, "todelete.txt")
	if err := os.WriteFile(filePath, []byte("delete me"), 0644); err != nil {
		t.Fatalf("failed to create test file: %v", err)
	}

	_, err := s.Scan(filePath, "test-id-3", "todelete.txt", 9)
	if err != nil {
		t.Fatalf("scan failed: %v", err)
	}

	// File should be deleted after scan
	if _, err := os.Stat(filePath); !os.IsNotExist(err) {
		t.Error("expected file to be deleted after scan")
	}
}

func TestScanner_CheckHealth(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	health := s.CheckHealth()

	// Should have health only for active driver (mock)
	if len(health) != 1 {
		t.Errorf("expected 1 health result, got %d", len(health))
	}

	if health[0].Engine != config.EngineMock {
		t.Errorf("expected mock engine, got %s", health[0].Engine)
	}
	if !health[0].Healthy {
		t.Error("expected mock engine to be healthy")
	}
}

func TestScanner_GetActiveEngineHealth(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	health, err := s.GetActiveEngineHealth()
	if err != nil {
		t.Fatalf("failed to get active engine health: %v", err)
	}

	if health.Engine != config.EngineMock {
		t.Errorf("expected active engine mock, got %s", health.Engine)
	}
	if !health.Healthy {
		t.Error("expected active engine to be healthy")
	}
}

func TestScanner_GetEngineInfo(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	info := s.GetEngineInfo()

	// Should have info only for active driver (mock)
	if len(info) != 1 {
		t.Errorf("expected 1 engine info, got %d", len(info))
	}

	if info[0].Engine != config.EngineMock {
		t.Errorf("expected mock engine, got %s", info[0].Engine)
	}
	if !info[0].Available {
		t.Error("expected mock engine to be available")
	}
	if !info[0].ManualScanAvailable {
		t.Error("expected mock engine manual scan to be available")
	}
}

func TestScanner_ActiveEngine(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	if s.ActiveEngine() != config.EngineMock {
		t.Errorf("expected active engine mock, got %s", s.ActiveEngine())
	}
}

func TestScanner_GenerateFileID(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	id1 := s.GenerateFileID()
	id2 := s.GenerateFileID()

	if id1 == "" {
		t.Error("expected non-empty file ID")
	}
	if id1 == id2 {
		t.Error("expected unique file IDs")
	}
}

func TestScanner_GetUploadPath(t *testing.T) {
	s, tmpDir := newTestScanner(t)
	defer os.RemoveAll(tmpDir)
	defer s.Stop()

	path := s.GetUploadPath("abc123", "test.pdf")
	expected := filepath.Join(tmpDir, "abc123.pdf")

	if path != expected {
		t.Errorf("expected path %s, got %s", expected, path)
	}
}

// errorDriver is a driver whose manual scan never reaches a verdict.
type errorDriver struct {
	*drivers.MockDriver
}

func (d *errorDriver) Config() config.DriverConfig {
	return config.DriverConfig{Engine: config.EngineMock, RTSCacheBaseDelay: 50}
}

func (d *errorDriver) ManualScan(filePath string) (*drivers.ScanResult, error) {
	return &drivers.ScanResult{Status: drivers.StatusError, Engine: config.EngineMock}, nil
}

func newErrorDriverScanner(t *testing.T) (*Scanner, string) {
	t.Helper()
	s, tmpDir := newTestScanner(t)
	s.drivers[config.EngineMock] = &errorDriver{drivers.NewMockDriver(config.DriverConfig{Engine: config.EngineMock})}
	return s, tmpDir
}

func TestScanner_EngineErrorIsNeverClean(t *testing.T) {
	s, tmpDir := newErrorDriverScanner(t)
	defer os.RemoveAll(tmpDir)

	filePath := filepath.Join(tmpDir, "test.txt")
	if err := os.WriteFile(filePath, []byte("Hello, World!"), 0644); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	result, err := s.Scan(filePath, "test-id", "test.txt", 13)
	if err == nil {
		t.Fatalf("expected scan error, got status %s", result.Status)
	}
}

func TestScanner_EngineErrorUsesRTSDetection(t *testing.T) {
	s, tmpDir := newErrorDriverScanner(t)
	defer os.RemoveAll(tmpDir)

	filePath := filepath.Join(tmpDir, "test.txt")
	if err := os.WriteFile(filePath, []byte("Hello, World!"), 0644); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}
	absPath, _ := filepath.Abs(filePath)
	s.detectionCache.Add(absPath, &cache.Detection{FilePath: filePath, Status: "infected", Signature: "rts-sig"})

	result, err := s.Scan(filePath, "test-id", "test.txt", 13)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Status != drivers.StatusInfected {
		t.Errorf("expected status infected, got %s", result.Status)
	}
	if result.Signature != "rts-sig" {
		t.Errorf("expected signature rts-sig, got %s", result.Signature)
	}
}
