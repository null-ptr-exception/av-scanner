package drivers

import (
	"errors"
	"path/filepath"
	"time"

	"github.com/rophy/av-scanner/internal/cache"
	"github.com/rophy/av-scanner/internal/config"
)

// ErrNoRTSDetection means no real-time detection arrived before the timeout.
// It is never a clean verdict.
var ErrNoRTSDetection = errors.New("no real-time detection")

// WatchRTS waits for the engine's real-time scanner to report filePath, as
// added to the detection cache by the driver's log watcher. It returns as soon
// as the detection arrives, or ErrNoRTSDetection after opts.Timeout.
func WatchRTS(c *cache.DetectionCache, engine config.EngineType, filePath string, opts WatchOptions) (*ScanResult, error) {
	startTime := time.Now()
	absPath, err := filepath.Abs(filePath)
	if err != nil {
		absPath = filePath
	}

	cached, found := c.Wait(absPath, opts.Timeout)
	if !found {
		return nil, ErrNoRTSDetection
	}
	if cached.Status != "infected" {
		// The log watchers only add detections; anything else is not a verdict
		return nil, ErrNoRTSDetection
	}
	return &ScanResult{
		Status:    StatusInfected,
		Engine:    engine,
		Signature: cached.Signature,
		Phase:     PhaseRTS,
		FilePath:  filePath,
		FileID:    filepath.Base(filePath),
		Timestamp: time.Now(),
		Duration:  time.Since(startTime).Milliseconds(),
		Raw:       map[string]string{"logEntry": cached.Raw},
	}, nil
}
