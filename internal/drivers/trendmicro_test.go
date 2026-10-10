package drivers

import (
	"io"
	"log/slog"
	"testing"

	"github.com/rophy/av-scanner/internal/config"
)

func TestTmVirusFoundRegex(t *testing.T) {
	tests := []struct {
		name      string
		line      string
		wantPath  string
		wantMatch bool
	}{
		{
			name:      "virus found log line",
			line:      `2025-11-21 13:53:06.726130: [ds_am/4] | [SCTRL] (0000-0000-0000, /home/ubuntu/xxxx.file) virus found: 2, act_1st=2, act_2nd=255, act_1st_error_code=0 | scanctrl_vmpd_module.cpp:1538:scanctrl_determine_send_dispatch_result | F7E01:1784DB:4451::`,
			wantPath:  "/home/ubuntu/xxxx.file",
			wantMatch: true,
		},
		{
			name:      "path with spaces",
			line:      `2025-11-21 13:53:06.726130: [ds_am/4] | [SCTRL] (0000-0000-0000, /tmp/av-scanner/test file.txt) virus found: 1`,
			wantPath:  "/tmp/av-scanner/test file.txt",
			wantMatch: true,
		},
		{
			name:      "no virus",
			line:      `2025-11-21 13:53:06.726130: [ds_am/4] | [SCTRL] scan completed successfully`,
			wantPath:  "",
			wantMatch: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			matches := tmVirusFoundRegex.FindStringSubmatch(tt.line)
			if tt.wantMatch {
				if matches == nil {
					t.Errorf("expected match but got none")
					return
				}
				if len(matches) < 2 {
					t.Errorf("expected capture group, got %v", matches)
					return
				}
				if matches[1] != tt.wantPath {
					t.Errorf("got path %q, want %q", matches[1], tt.wantPath)
				}
			} else {
				if matches != nil {
					t.Errorf("expected no match but got %v", matches)
				}
			}
		})
	}
}

func TestParseManualScanOutput(t *testing.T) {
	d := NewTrendMicroDriver(config.DriverConfig{}, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)

	tests := []struct {
		name          string
		output        string
		exitCode      int
		wantStatus    ScanStatus
		wantSignature string
	}{
		{
			name:       "scanned clean",
			output:     `{"traceID":"t","numOfFileScanned":1,"numOfFileSkipped":0,"numOfFileInfected":0,"errorCode":0,"infectedFiles":[]}`,
			wantStatus: StatusClean,
		},
		{
			name:          "infected",
			output:        `{"numOfFileScanned":1,"numOfFileInfected":1,"errorCode":0,"infectedFiles":[{"fileName":"/tmp/x","malwareName":"Eicar_test_file"}]}`,
			wantStatus:    StatusInfected,
			wantSignature: "Eicar_test_file",
		},
		{
			name:          "infected with errorCode is still infected",
			output:        `{"numOfFileScanned":1,"numOfFileInfected":1,"errorCode":5,"infectedFiles":[{"fileName":"/tmp/x","malwareName":"Eicar_test_file"}]}`,
			wantStatus:    StatusInfected,
			wantSignature: "Eicar_test_file",
		},
		{
			name:       "non-zero errorCode is error",
			output:     `{"numOfFileScanned":1,"numOfFileInfected":0,"errorCode":5}`,
			wantStatus: StatusError,
		},
		{
			name:       "skipped is error",
			output:     `{"numOfFileScanned":0,"numOfFileSkipped":1,"errorCode":0}`,
			wantStatus: StatusError,
		},
		{
			name:       "skipped alongside scanned is error",
			output:     `{"numOfFileScanned":1,"numOfFileSkipped":1,"errorCode":0}`,
			wantStatus: StatusError,
		},
		{
			name:       "nothing scanned is error",
			output:     `{}`,
			wantStatus: StatusError,
		},
		{
			name:       "unparseable output with exit 0 is error",
			output:     "Scan finished",
			wantStatus: StatusError,
		},
		{
			name:       "empty output with exit 0 is error",
			output:     "",
			wantStatus: StatusError,
		},
		{
			name:       "unparseable output with non-zero exit is error",
			output:     "dsa_scan: connection refused",
			exitCode:   1,
			wantStatus: StatusError,
		},
		{
			name:       "unparseable output mentioning malware is infected",
			output:     "Malware detected: Eicar_test_file",
			wantStatus: StatusInfected,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			status, signature := d.parseManualScanOutput(tt.output, tt.exitCode)
			if status != tt.wantStatus {
				t.Errorf("status = %q, want %q", status, tt.wantStatus)
			}
			if signature != tt.wantSignature {
				t.Errorf("signature = %q, want %q", signature, tt.wantSignature)
			}
		})
	}
}
