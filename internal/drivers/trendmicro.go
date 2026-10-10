package drivers

import (
	"bytes"
	"context"
	"encoding/json"
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

var (
	// TrendMicro DS Agent log patterns
	// Sample: 2025-11-21 13:53:06.726130: [ds_am/4] | [SCTRL] (0000-0000-0000, /home/ubuntu/xxxx.file) virus found: 2, act_1st=2, act_2nd=255, act_1st_error_code=0 | scanctrl_vmpd_module.cpp:1538:scanctrl_determine_send_dispatch_result | F7E01:1784DB:4451::
	tmVirusFoundRegex = regexp.MustCompile(`\([^,]+,\s*([^)]+)\)\s*virus found:`)
)

type TrendMicroDriver struct {
	config config.DriverConfig
	logger *slog.Logger
	cache  *cache.DetectionCache
	ctx    context.Context
	cancel context.CancelFunc
}

func NewTrendMicroDriver(cfg config.DriverConfig, logger *slog.Logger, detectionCache *cache.DetectionCache) *TrendMicroDriver {
	ctx, cancel := context.WithCancel(context.Background())
	return &TrendMicroDriver{
		config: cfg,
		logger: logger.With("driver", "trendmicro"),
		cache:  detectionCache,
		ctx:    ctx,
		cancel: cancel,
	}
}

// Start begins the background log watcher
func (d *TrendMicroDriver) Start() error {
	if _, err := os.Stat(d.config.RTSLogPath); err != nil {
		d.logger.Warn("RTS log file not accessible, background watcher not started", "path", d.config.RTSLogPath)
		return nil
	}

	go d.watchLog()
	d.logger.Info("Background log watcher started", "path", d.config.RTSLogPath)
	return nil
}

// Stop stops the background log watcher
func (d *TrendMicroDriver) Stop() {
	d.cancel()
}

func (d *TrendMicroDriver) watchLog() {
	t, err := tail.TailFile(d.config.RTSLogPath, tail.Config{
		Follow:    true,
		ReOpen:    true,
		Poll:      true,
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

func (d *TrendMicroDriver) processLogLine(line string) {
	// Check for virus detection: (trace-id, /path/to/file) virus found: N
	if matches := tmVirusFoundRegex.FindStringSubmatch(line); matches != nil {
		filePath := strings.TrimSpace(matches[1])
		absPath, err := filepath.Abs(filePath)
		if err != nil {
			absPath = filePath
		}

		d.cache.Add(absPath, &cache.Detection{
			FilePath:  filePath,
			Status:    "infected",
			Signature: "virus",
			Raw:       line,
		})
		d.logger.Debug("Cached virus detection", "path", absPath)
	}
}

func (d *TrendMicroDriver) Engine() config.EngineType {
	return config.EngineTrendMicro
}

func (d *TrendMicroDriver) Config() config.DriverConfig {
	return d.config
}

func (d *TrendMicroDriver) RTSWatch(filePath string, opts WatchOptions) (*ScanResult, error) {
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

func (d *TrendMicroDriver) ManualScan(filePath string) (*ScanResult, error) {
	startTime := time.Now()
	fileID := filepath.Base(filePath)

	// dsa_scan --target <file> --json
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(d.config.Timeout)*time.Millisecond)
	defer cancel()

	cmd := exec.CommandContext(ctx, d.config.ScanBinaryPath, "--target", filePath, "--json")
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

	output := stdout.String()
	d.logger.Debug("Manual scan completed", "exitCode", exitCode, "output", output)

	status, signature := d.parseManualScanOutput(output, exitCode)

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

func (d *TrendMicroDriver) parseManualScanOutput(output string, exitCode int) (ScanStatus, string) {
	// Try JSON parsing first (dsa_scan --json output format)
	var jsonResult struct {
		TraceID           string  `json:"traceID"`
		NumOfFileScanned  int     `json:"numOfFileScanned"`
		NumOfFileSkipped  int     `json:"numOfFileSkipped"`
		NumOfFileInfected int     `json:"numOfFileInfected"`
		TimeElapse        float64 `json:"timeElapse"`
		ErrorCode         int     `json:"errorCode"`
		InfectedFiles     []struct {
			FileName    string `json:"fileName"`
			MalwareName string `json:"malwareName"`
		} `json:"infectedFiles"`
	}

	if err := json.Unmarshal([]byte(output), &jsonResult); err != nil {
		// Unparseable output: never report clean. Keyword match still fails closed as infected.
		lowerOutput := strings.ToLower(output)
		if strings.Contains(lowerOutput, "infected") ||
			strings.Contains(lowerOutput, "virus") ||
			strings.Contains(lowerOutput, "malware") {
			d.logger.Warn("Unparseable scanner output matched infection keyword, reporting infected",
				"exitCode", exitCode, "output", output)
			return StatusInfected, ""
		}
		d.logger.Warn("Unparseable scanner output", "exitCode", exitCode, "error", err)
		return StatusError, ""
	}

	// Check for infected files first, so a detection is never masked by an error
	if jsonResult.NumOfFileInfected > 0 || len(jsonResult.InfectedFiles) > 0 {
		signature := ""
		if len(jsonResult.InfectedFiles) > 0 {
			signature = jsonResult.InfectedFiles[0].MalwareName
		}
		return StatusInfected, signature
	}

	if jsonResult.ErrorCode != 0 {
		d.logger.Warn("Scanner reported error", "errorCode", jsonResult.ErrorCode, "exitCode", exitCode)
		return StatusError, ""
	}

	// Check if file was skipped (not actually scanned)
	if jsonResult.NumOfFileSkipped > 0 {
		d.logger.Warn("File was skipped by scanner", "skipped", jsonResult.NumOfFileSkipped)
		return StatusError, ""
	}

	// File was scanned and is clean
	if jsonResult.NumOfFileScanned > 0 {
		return StatusClean, ""
	}

	// No files scanned, treat as error
	return StatusError, ""
}

func (d *TrendMicroDriver) CheckHealth() (*EngineHealth, error) {
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

func (d *TrendMicroDriver) GetInfo() EngineInfo {
	return EngineInfo{
		Engine:              d.Engine(),
		Available:           true,
		RTSEnabled:          true,
		ManualScanAvailable: true,
	}
}
