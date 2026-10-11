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

	// Captured from agent 20.0.3 with --json --log /dev/stderr (result = stderr,
	// diag = stdout). With the agent stopped, dsa_scan exits 253 and still
	// reports "errorCode":0.
	const (
		realClean = `{
  "traceID":"6bbebfb8-516b-4ac7-9dc0-f292dbceff66",
  "numOfFileScanned":1,
  "numOfFileSkipped":0,
  "numOfFileInfected":0,
  "timeElapse":0.48,
  "errorCode":0,
  "infectedFiles":[]
}
`
		realUnreachable = `{
  "traceID":"c3c338b6-9fcd-4bf8-86cb-aa4f2409939e",
  "numOfFileScanned":0,
  "numOfFileSkipped":0,
  "numOfFileInfected":0,
  "timeElapse":0.01,
  "errorCode":0,
  "infectedFiles":[]
}

`
		realUnreachableDiag = "2026-10-11 12:09:47.000000 [+0000]: [Error/1] | couldn't connect to 127.0.0.1:4118 (-1: Socket reset) | dsa/core/http/HTTPClient.cpp:332:ConnectToHost | AA7:7FF2975A8640:CScriptThread\n" +
			"2026-10-11 12:09:47.666909 [+0000]: [Error/1] | Request failed, trace: c3c338b6-9fcd-4bf8-86cb-aa4f2409939e, batch: 1 | ...pace/build_dsa-core_master/dsa/core/scripts/dsa_scan.lua:660:(null) | AA7:7FF2975A8640:CScriptThread"
	)

	tests := []struct {
		name          string
		result        string
		exitCode      int
		diag          string
		wantStatus    ScanStatus
		wantSignature string
	}{
		{
			name:       "real agent: clean",
			result:     realClean,
			wantStatus: StatusClean,
		},
		{
			name:       "real agent: unreachable (exit 253, errorCode 0) is error",
			result:     realUnreachable,
			exitCode:   253,
			diag:       realUnreachableDiag,
			wantStatus: StatusError,
		},
		{
			// Regression: the old parser read stdout, failed on the log lines and
			// matched "infected" in the field name numOfFileInfected
			name:       "result missing while diag mentions numOfFileInfected is error, not infected",
			result:     "",
			exitCode:   253,
			diag:       realUnreachableDiag + "\n" + realUnreachable,
			wantStatus: StatusError,
		},
		{
			name:          "infected",
			result:        `{"numOfFileScanned":1,"numOfFileInfected":1,"errorCode":0,"infectedFiles":[{"fileName":"/tmp/x","malwareName":"Eicar_test_file"}]}`,
			exitCode:      1,
			wantStatus:    StatusInfected,
			wantSignature: "Eicar_test_file",
		},
		{
			name:          "infected with errorCode is still infected",
			result:        `{"numOfFileScanned":1,"numOfFileInfected":1,"errorCode":5,"infectedFiles":[{"fileName":"/tmp/x","malwareName":"Eicar_test_file"}]}`,
			exitCode:      1,
			wantStatus:    StatusInfected,
			wantSignature: "Eicar_test_file",
		},
		{
			name:       "exit 1 (malware found) without a name is infected",
			result:     `{"numOfFileScanned":1,"numOfFileInfected":0,"errorCode":0,"infectedFiles":[]}`,
			exitCode:   1,
			wantStatus: StatusInfected,
		},
		{
			name:       "exit 3 (malware found, files skipped) is infected",
			result:     `{"numOfFileScanned":1,"numOfFileSkipped":1,"numOfFileInfected":0,"errorCode":0}`,
			exitCode:   3,
			wantStatus: StatusInfected,
		},
		{
			name:       "exit 2 (files skipped) is error",
			result:     `{"numOfFileScanned":0,"numOfFileSkipped":1,"errorCode":0}`,
			exitCode:   2,
			wantStatus: StatusError,
		},
		{
			name:       "exit 248 (busy) with clean-looking JSON is error",
			result:     realClean,
			exitCode:   248,
			wantStatus: StatusError,
		},
		{
			name:       "exit 249 (not permitted) is error",
			result:     realUnreachable,
			exitCode:   249,
			wantStatus: StatusError,
		},
		{
			name:       "non-zero errorCode is error",
			result:     `{"numOfFileScanned":1,"numOfFileInfected":0,"errorCode":5}`,
			wantStatus: StatusError,
		},
		{
			name:       "skipped alongside scanned is error",
			result:     `{"numOfFileScanned":1,"numOfFileSkipped":1,"errorCode":0}`,
			wantStatus: StatusError,
		},
		{
			name:       "clean-looking result missing fields is error",
			result:     `{"numOfFileScanned":1}`,
			wantStatus: StatusError,
		},
		{
			name:       "clean-looking result missing errorCode is error",
			result:     `{"numOfFileScanned":1,"numOfFileSkipped":0,"numOfFileInfected":0}`,
			wantStatus: StatusError,
		},
		{
			name:       "nothing scanned is error",
			result:     `{}`,
			wantStatus: StatusError,
		},
		{
			name:       "empty result is error",
			result:     "",
			wantStatus: StatusError,
		},
		{
			name:       "unparseable result mentioning malware is error",
			result:     "Malware detected: Eicar_test_file",
			wantStatus: StatusError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			status, signature := d.parseManualScanOutput(tt.result, tt.exitCode, tt.diag)
			if status != tt.wantStatus {
				t.Errorf("status = %q, want %q", status, tt.wantStatus)
			}
			if signature != tt.wantSignature {
				t.Errorf("signature = %q, want %q", signature, tt.wantSignature)
			}
		})
	}
}
