package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rophy/av-scanner/internal/config"
	"github.com/rophy/av-scanner/internal/drivers"
	"github.com/rophy/av-scanner/internal/scanner"
)

func newTestAPI(t *testing.T) (*API, string) {
	t.Helper()

	tmpDir, err := os.MkdirTemp("", "av-scanner-api-test-*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}

	cfg := &config.Config{
		Port:         3000,
		UploadDir:    tmpDir,
		MaxFileSize:  10 * 1024 * 1024,
		ActiveEngine: config.EngineMock,
		LogLevel:     "error",
		Drivers: map[config.EngineType]config.DriverConfig{
			config.EngineClamAV:     {Engine: config.EngineClamAV},
			config.EngineTrendMicro: {Engine: config.EngineTrendMicro},
		},
		Auth: config.AuthConfig{
			Enabled: false, // Auth disabled in tests by default
		},
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := scanner.New(cfg, logger)
	api, err := New(s, cfg, logger)
	if err != nil {
		t.Fatalf("failed to create API: %v", err)
	}

	return api, tmpDir
}

func createMultipartFile(t *testing.T, fieldName, fileName string, content []byte) (*bytes.Buffer, string) {
	t.Helper()

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)

	part, err := writer.CreateFormFile(fieldName, fileName)
	if err != nil {
		t.Fatalf("failed to create form file: %v", err)
	}

	if _, err := part.Write(content); err != nil {
		t.Fatalf("failed to write content: %v", err)
	}

	if err := writer.Close(); err != nil {
		t.Fatalf("failed to close writer: %v", err)
	}

	return body, writer.FormDataContentType()
}

func TestAPI_HandleScan_CleanFile(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	body, contentType := createMultipartFile(t, "file", "clean.txt", []byte("This is a clean file"))

	req := httptest.NewRequest(http.MethodPost, "/api/v1/scan", body)
	req.Header.Set("Content-Type", contentType)

	rr := httptest.NewRecorder()
	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp["status"] != "clean" {
		t.Errorf("expected status clean, got %v", resp["status"])
	}
	if resp["engine"] != "mock" {
		t.Errorf("expected engine mock, got %v", resp["engine"])
	}
	if resp["fileName"] != "clean.txt" {
		t.Errorf("expected fileName clean.txt, got %v", resp["fileName"])
	}
}

func TestAPI_HandleScan_InfectedFile(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	body, contentType := createMultipartFile(t, "file", "infected.txt", []byte(drivers.EICARPattern()))

	req := httptest.NewRequest(http.MethodPost, "/api/v1/scan", body)
	req.Header.Set("Content-Type", contentType)

	rr := httptest.NewRecorder()
	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp["status"] != "infected" {
		t.Errorf("expected status infected, got %v", resp["status"])
	}
	if resp["signature"] != drivers.EICARSignature {
		t.Errorf("expected signature %s, got %v", drivers.EICARSignature, resp["signature"])
	}
}

func TestAPI_HandleScan_NoFile(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/scan", nil)

	rr := httptest.NewRecorder()
	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected status 400, got %d", rr.Code)
	}
}

func TestAPI_HandleScan_WrongFieldName(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	body, contentType := createMultipartFile(t, "wrongfield", "test.txt", []byte("content"))

	req := httptest.NewRequest(http.MethodPost, "/api/v1/scan", body)
	req.Header.Set("Content-Type", contentType)

	rr := httptest.NewRecorder()
	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected status 400, got %d", rr.Code)
	}

	var resp map[string]interface{}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp["error"] == nil {
		t.Error("expected error message in response")
	}
}

func TestAPI_HandleHealth(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	rr := httptest.NewRecorder()

	api.Routes().ServeHTTP(rr, req)

	// Status may be 503 because clamav/trendmicro aren't available, but mock is active
	// Since active engine is mock and it's healthy, should be 200
	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp["status"] != "healthy" {
		t.Errorf("expected status healthy, got %v", resp["status"])
	}
	if resp["activeEngine"] != "mock" {
		t.Errorf("expected activeEngine mock, got %v", resp["activeEngine"])
	}
	if resp["engines"] == nil {
		t.Error("expected engines in response")
	}
}

func TestAPI_HandleEngines(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/engines", nil)
	rr := httptest.NewRecorder()

	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rr.Code)
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp["activeEngine"] != "mock" {
		t.Errorf("expected activeEngine mock, got %v", resp["activeEngine"])
	}

	engines, ok := resp["engines"].([]interface{})
	if !ok || len(engines) != 1 {
		t.Errorf("expected 1 engine (active only), got %v", resp["engines"])
	}
}

func TestAPI_HandleReady(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/ready", nil)
	rr := httptest.NewRecorder()

	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp["ready"] != true {
		t.Errorf("expected ready true, got %v", resp["ready"])
	}
}

func TestAPI_HandleLive(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/live", nil)
	rr := httptest.NewRecorder()

	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rr.Code)
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp["alive"] != true {
		t.Errorf("expected alive true, got %v", resp["alive"])
	}
}

func TestAPI_MethodNotAllowed(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	// GET to /scan should fail (expects POST)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/scan", nil)
	rr := httptest.NewRecorder()

	api.Routes().ServeHTTP(rr, req)

	// Go 1.22+ returns 405 for method mismatch
	if rr.Code != http.StatusMethodNotAllowed && rr.Code != http.StatusNotFound {
		t.Errorf("expected status 405 or 404, got %d", rr.Code)
	}
}

func TestAPI_NotFound(t *testing.T) {
	api, tmpDir := newTestAPI(t)
	defer os.RemoveAll(tmpDir)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/nonexistent", nil)
	rr := httptest.NewRecorder()

	api.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("expected status 404, got %d", rr.Code)
	}
}

// newAuthTestAPI returns the API router with auth enabled against a mock
// TokenReview server that authenticates every token as ns/sa.
func newAuthTestAPI(t *testing.T, allowlist string) http.Handler {
	t.Helper()

	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"apiVersion":"authentication.k8s.io/v1","kind":"TokenReview","status":{"authenticated":true,"user":{"username":"system:serviceaccount:ns:sa","uid":"uid-1"}}}`))
	}))
	t.Cleanup(authServer.Close)

	tmpDir := t.TempDir()
	allowlistFile := filepath.Join(tmpDir, "allowlist.yaml")
	if err := os.WriteFile(allowlistFile, []byte(allowlist), 0644); err != nil {
		t.Fatalf("failed to write allowlist: %v", err)
	}

	cfg := &config.Config{
		Port:         3000,
		UploadDir:    tmpDir,
		MaxFileSize:  10 * 1024 * 1024,
		ActiveEngine: config.EngineMock,
		LogLevel:     "error",
		Drivers: map[config.EngineType]config.DriverConfig{
			config.EngineClamAV:     {Engine: config.EngineClamAV},
			config.EngineTrendMicro: {Engine: config.EngineTrendMicro},
		},
		Auth: config.AuthConfig{
			Enabled:        true,
			K8sAPIEndpoint: authServer.URL,
			Timeout:        5000,
			AllowlistFile:  allowlistFile,
		},
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := scanner.New(cfg, logger)
	api, err := New(s, cfg, logger)
	if err != nil {
		t.Fatalf("failed to create API: %v", err)
	}
	t.Cleanup(func() { api.Close() })

	return api.Routes()
}

func TestAPI_ScanIsRateLimitedPerAccount(t *testing.T) {
	h := newAuthTestAPI(t, `allowlist:
  - ns/sa
rateLimits:
  default:
    requestsPerMinute: 1
    burst: 1
`)

	scan := func() *httptest.ResponseRecorder {
		body, contentType := createMultipartFile(t, "file", "clean.txt", []byte("This is a clean file"))
		req := httptest.NewRequest(http.MethodPost, "/api/v1/scan", body)
		req.Header.Set("Content-Type", contentType)
		req.Header.Set("Authorization", "Bearer test-token")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		return rr
	}

	if rr := scan(); rr.Code != http.StatusOK {
		t.Fatalf("first scan: status %d: %s", rr.Code, rr.Body.String())
	}

	rr := scan()
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("second scan: status %d, want 429: %s", rr.Code, rr.Body.String())
	}
	var resp map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}
	if resp["reason"] != "rate" {
		t.Errorf("reason = %q, want rate", resp["reason"])
	}

	// Non-scan endpoints are not limited
	for i := 0; i < 3; i++ {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
		req.Header.Set("Authorization", "Bearer test-token")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("health %d: status %d, want 200", i, rr.Code)
		}
	}

	// Rejection is visible in metrics
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	mr := httptest.NewRecorder()
	h.ServeHTTP(mr, req)
	want := `av_ratelimit_rejected_total{account="ns/sa",reason="rate"}`
	if !strings.Contains(mr.Body.String(), want) {
		t.Errorf("metrics missing %s", want)
	}
}
