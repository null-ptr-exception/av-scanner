package drivers

import (
	"time"

	"github.com/rophy/av-scanner/internal/config"
)

type ScanStatus string

const (
	StatusClean    ScanStatus = "clean"
	StatusInfected ScanStatus = "infected"
	StatusError    ScanStatus = "error"
)

type ScanPhase string

const (
	PhaseRTS    ScanPhase = "rts"
	PhaseManual ScanPhase = "manual"
)

type ScanResult struct {
	Status    ScanStatus        `json:"status"`
	Engine    config.EngineType `json:"engine"`
	Signature string            `json:"signature,omitempty"`
	Phase     ScanPhase         `json:"phase"`
	FilePath  string            `json:"-"`
	FileID    string            `json:"fileId"`
	Timestamp time.Time         `json:"timestamp"`
	Duration  int64             `json:"duration"` // milliseconds
	Raw       interface{}       `json:"-"`
}

type EngineHealth struct {
	Engine    config.EngineType `json:"engine"`
	Healthy   bool              `json:"healthy"`
	Version   string            `json:"version,omitempty"`
	LastCheck time.Time         `json:"lastCheck"`
	Error     string            `json:"error,omitempty"`
}

type EngineInfo struct {
	Engine              config.EngineType `json:"engine"`
	Available           bool              `json:"available"`
	RTSEnabled          bool              `json:"rtsEnabled"`
	ManualScanAvailable bool              `json:"manualScanAvailable"`
}

type WatchOptions struct {
	Timeout time.Duration
}

type LogEntry struct {
	Timestamp time.Time
	FilePath  string
	Status    ScanStatus
	Signature string
	Raw       string
}

type Driver interface {
	Engine() config.EngineType
	Config() config.DriverConfig
	Start() error
	Stop()
	// RTSWatch waits up to opts.Timeout for a real-time detection of filePath.
	// It returns an infected result, or ErrNoRTSDetection; never clean.
	RTSWatch(filePath string, opts WatchOptions) (*ScanResult, error)
	ManualScan(filePath string) (*ScanResult, error)
	CheckHealth() (*EngineHealth, error)
	GetInfo() EngineInfo
}
