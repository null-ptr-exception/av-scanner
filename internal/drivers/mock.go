package drivers

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/rophy/av-scanner/internal/config"
)

const EICARSignature = "EICAR-Test-File"

// EICARPattern returns the EICAR test string.
// The pattern is stored with 'O' replaced by 'x' to avoid AV detection of source files.
// https://en.wikipedia.org/wiki/EICAR_test_file
func EICARPattern() string {
	// 'O' at position 2 replaced with 'x'
	broken := "X5x!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
	return strings.Replace(broken, "x", "O", 1)
}

// MockDriver implements Driver interface for testing purposes.
// It detects files containing the EICAR test pattern.
type MockDriver struct {
	cfg config.DriverConfig
}

func NewMockDriver(cfg config.DriverConfig) *MockDriver {
	return &MockDriver{
		cfg: cfg,
	}
}

func (d *MockDriver) Engine() config.EngineType {
	return config.EngineMock
}

func (d *MockDriver) Config() config.DriverConfig {
	return d.cfg
}

func (d *MockDriver) Start() error {
	return nil
}

func (d *MockDriver) Stop() {
}

// RTSWatch reports an EICAR file as a real-time detection. Anything else is
// ErrNoRTSDetection, as with the real drivers: no detection is never clean.
func (d *MockDriver) RTSWatch(filePath string, opts WatchOptions) (*ScanResult, error) {
	result, err := d.scan(filePath, PhaseRTS)
	if err != nil {
		return nil, err
	}
	if result.Status != StatusInfected {
		return nil, ErrNoRTSDetection
	}
	return result, nil
}

func (d *MockDriver) ManualScan(filePath string) (*ScanResult, error) {
	return d.scan(filePath, PhaseManual)
}

func (d *MockDriver) scan(filePath string, phase ScanPhase) (*ScanResult, error) {
	startTime := time.Now()
	fileID := filepath.Base(filePath)

	content, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}

	result := &ScanResult{
		Status:    StatusClean,
		Engine:    config.EngineMock,
		Phase:     phase,
		FilePath:  filePath,
		FileID:    fileID,
		Timestamp: time.Now(),
		Duration:  time.Since(startTime).Milliseconds(),
	}

	if strings.Contains(string(content), EICARPattern()) {
		result.Status = StatusInfected
		result.Signature = EICARSignature
	}

	return result, nil
}

func (d *MockDriver) CheckHealth() (*EngineHealth, error) {
	return &EngineHealth{
		Engine:    config.EngineMock,
		Healthy:   true,
		Version:   "1.0.0-mock",
		LastCheck: time.Now(),
	}, nil
}

func (d *MockDriver) GetInfo() EngineInfo {
	return EngineInfo{
		Engine:              config.EngineMock,
		Available:           true,
		RTSEnabled:          false,
		ManualScanAvailable: true,
	}
}
