package drivers

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/nxadm/tail"
	"github.com/rophy/av-scanner/internal/cache"
	"github.com/rophy/av-scanner/internal/config"
)

// Matches: /path/to/file: Signature FOUND
var clamavFoundRegex = regexp.MustCompile(`(.+):\s+(.+)\s+FOUND$`)

type ClamAVDriver struct {
	config config.DriverConfig
	logger *slog.Logger
	cache  *cache.DetectionCache
	ctx    context.Context
	cancel context.CancelFunc
}

func NewClamAVDriver(cfg config.DriverConfig, logger *slog.Logger, detectionCache *cache.DetectionCache) *ClamAVDriver {
	ctx, cancel := context.WithCancel(context.Background())
	return &ClamAVDriver{
		config: cfg,
		logger: logger.With("driver", "clamav"),
		cache:  detectionCache,
		ctx:    ctx,
		cancel: cancel,
	}
}

// Start begins the background log watcher
func (d *ClamAVDriver) Start() error {
	if _, err := os.Stat(d.config.RTSLogPath); err != nil {
		d.logger.Warn("RTS log file not accessible, background watcher not started", "path", d.config.RTSLogPath)
		return nil
	}

	go d.watchLog()
	d.logger.Info("Background log watcher started", "path", d.config.RTSLogPath)
	return nil
}

// Stop stops the background log watcher
func (d *ClamAVDriver) Stop() {
	d.cancel()
}

func (d *ClamAVDriver) watchLog() {
	t, err := tail.TailFile(d.config.RTSLogPath, tail.Config{
		Follow:    true,
		ReOpen:    true,
		MustExist: true,
		Location:  &tail.SeekInfo{Offset: 0, Whence: os.SEEK_END},
	})
	if err != nil {
		d.logger.Error("Failed to start log tailer", "error", err)
		return
	}
	defer t.Cleanup()

	for {
		select {
		case <-d.ctx.Done():
			t.Stop()
			return
		case line := <-t.Lines:
			if line == nil || line.Err != nil {
				continue
			}
			d.processLogLine(line.Text)
		}
	}
}

func (d *ClamAVDriver) processLogLine(line string) {
	if matches := clamavFoundRegex.FindStringSubmatch(line); matches != nil {
		absPath, err := filepath.Abs(matches[1])
		if err != nil {
			absPath = matches[1]
		}

		d.cache.Add(absPath, &cache.Detection{
			FilePath:  matches[1],
			Status:    "infected",
			Signature: matches[2],
			Raw:       line,
		})
		d.logger.Debug("Cached detection", "path", absPath, "signature", matches[2])
	}
}

func (d *ClamAVDriver) Engine() config.EngineType {
	return config.EngineClamAV
}

func (d *ClamAVDriver) Config() config.DriverConfig {
	return d.config
}

func (d *ClamAVDriver) RTSWatch(filePath string, opts WatchOptions) (*ScanResult, error) {
	startTime := time.Now()
	fileID := filepath.Base(filePath)

	absPath, err := filepath.Abs(filePath)
	if err != nil {
		absPath = filePath
	}

	timeout := time.After(opts.Timeout)
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			d.logger.Warn("RTS watch timeout", "filePath", filePath)
			return &ScanResult{
				Status:    StatusClean,
				Engine:    d.Engine(),
				Phase:     PhaseRTS,
				FilePath:  filePath,
				FileID:    fileID,
				Timestamp: time.Now(),
				Duration:  time.Since(startTime).Milliseconds(),
				Raw:       map[string]bool{"timeout": true},
			}, nil

		case <-ticker.C:
			if cached, found := d.cache.Get(absPath); found {
				status := StatusClean
				if cached.Status == "infected" {
					status = StatusInfected
				}

				return &ScanResult{
					Status:    status,
					Engine:    d.Engine(),
					Signature: cached.Signature,
					Phase:     PhaseRTS,
					FilePath:  filePath,
					FileID:    fileID,
					Timestamp: time.Now(),
					Duration:  time.Since(startTime).Milliseconds(),
					Raw:       map[string]string{"logEntry": cached.Raw},
				}, nil
			}
		}
	}
}

func (d *ClamAVDriver) ManualScan(filePath string) (*ScanResult, error) {
	startTime := time.Now()
	fileID := filepath.Base(filePath)

	// clamdscan --fdpass --stdout --no-summary <file>
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(d.config.Timeout)*time.Millisecond)
	defer cancel()

	cmd := exec.CommandContext(ctx, d.config.ScanBinaryPath, "--fdpass", "--stdout", "--no-summary", filePath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else if ctx.Err() == context.DeadlineExceeded {
			return nil, ctx.Err()
		} else {
			return nil, err
		}
	}

	output := strings.TrimSpace(stdout.String())
	d.logger.Debug("Manual scan completed", "exitCode", exitCode, "output", output)

	// Parse output for signature
	var status ScanStatus
	var signature string

	if matches := clamavFoundRegex.FindStringSubmatch(output); matches != nil {
		status = StatusInfected
		signature = matches[2]
	} else {
		// Exit codes: 0 = clean, 1 = virus found, 2+ = error
		switch exitCode {
		case 0:
			status = StatusClean
		case 1:
			status = StatusInfected
			d.logger.Warn("Infected without a signature in scanner output",
				"exitCode", exitCode, "output", output, "stderr", strings.TrimSpace(stderr.String()))
		default:
			status = StatusError
			d.logger.Warn("Scanner error",
				"exitCode", exitCode, "output", output, "stderr", strings.TrimSpace(stderr.String()))
		}
	}

	return &ScanResult{
		Status:    status,
		Engine:    d.Engine(),
		Signature: signature,
		Phase:     PhaseManual,
		FilePath:  filePath,
		FileID:    fileID,
		Timestamp: time.Now(),
		Duration:  time.Since(startTime).Milliseconds(),
		Raw: map[string]interface{}{
			"exitCode": exitCode,
			"stdout":   output,
			"stderr":   stderr.String(),
		},
	}, nil
}

func (d *ClamAVDriver) CheckHealth() (*EngineHealth, error) {
	health := &EngineHealth{
		Engine:    d.Engine(),
		LastCheck: time.Now(),
	}

	if _, err := os.Stat(d.config.RTSLogPath); err != nil {
		health.Healthy = false
		health.Error = "RTS log not accessible: " + d.config.RTSLogPath
		return health, nil
	}

	health.Healthy = true
	return health, nil
}

func (d *ClamAVDriver) GetInfo() EngineInfo {
	return EngineInfo{
		Engine:              d.Engine(),
		Available:           true,
		RTSEnabled:          true,
		ManualScanAvailable: true,
	}
}
