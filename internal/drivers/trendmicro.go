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

	// dsa_scan prints its own error lines on stdout, ahead of the JSON result.
	// --log /dev/stderr sends the JSON to stderr instead, so the two never mix
	// (verified on agents 20.0.2 and 20.0.3; /dev/fd/3 crashes dsa_scan).
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(d.config.Timeout)*time.Millisecond)
	defer cancel()

	cmd := exec.CommandContext(ctx, d.config.ScanBinaryPath, "--target", filePath, "--json", "--log", "/dev/stderr")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	// Checked first: a killed process also returns an *exec.ExitError (code -1)
	if ctx.Err() == context.DeadlineExceeded {
		d.logger.Warn("Scanner timed out", "timeoutMs", d.config.Timeout, "diag", strings.TrimSpace(stdout.String()))
		return nil, ctx.Err()
	}
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, err
		}
	}

	result := stderr.String()
	diag := strings.TrimSpace(stdout.String())
	d.logger.Debug("Manual scan completed", "exitCode", exitCode, "result", result, "diag", diag)

	status, signature := d.parseManualScanOutput(result, exitCode, diag)

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
			"stdout":   diag,
			"stderr":   result,
		},
	}, nil
}

// parseManualScanOutput turns dsa_scan's exit code and JSON result into a
// verdict. It never reports clean unless the scan definitively finished clean.
// diag is dsa_scan's own log output, used only for diagnostics.
//
// Exit codes: 0 clean, 1 malware found, 2 files skipped, 3 malware found and
// files skipped; anything else (248 busy, 249 not permitted, 253 agent
// unreachable, ...) is an error. On 253 the JSON still says "errorCode":0, so
// the exit code must be checked, not only the JSON.
func (d *TrendMicroDriver) parseManualScanOutput(result string, exitCode int, diag string) (ScanStatus, string) {
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

	if err := json.Unmarshal([]byte(result), &jsonResult); err != nil {
		d.logger.Warn("Unparseable scanner result",
			"exitCode", exitCode, "error", err, "result", result, "diag", diag)
		return StatusError, ""
	}

	// A detection is never masked by an error
	if jsonResult.NumOfFileInfected > 0 || len(jsonResult.InfectedFiles) > 0 || exitCode == 1 || exitCode == 3 {
		signature := ""
		if len(jsonResult.InfectedFiles) > 0 {
			signature = jsonResult.InfectedFiles[0].MalwareName
		}
		if signature == "" {
			d.logger.Warn("Infected without a malware name in scanner result",
				"exitCode", exitCode, "result", result, "diag", diag)
		}
		return StatusInfected, signature
	}

	if exitCode != 0 || jsonResult.ErrorCode != 0 || jsonResult.NumOfFileSkipped > 0 || jsonResult.NumOfFileScanned == 0 {
		d.logger.Warn("Scanner returned no verdict",
			"exitCode", exitCode, "errorCode", jsonResult.ErrorCode,
			"scanned", jsonResult.NumOfFileScanned, "skipped", jsonResult.NumOfFileSkipped, "diag", diag)
		return StatusError, ""
	}

	return StatusClean, ""
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
