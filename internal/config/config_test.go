package config

import (
	"os"
	"testing"
)

func TestLoad_Defaults(t *testing.T) {
	// Clear relevant env vars to test defaults
	envVars := []string{
		"PORT", "UPLOAD_DIR", "MAX_FILE_SIZE", "AV_ENGINE", "LOG_LEVEL",
		"CLAMAV_RTS_LOG_PATH", "CLAMAV_SCAN_BINARY", "CLAMAV_TIMEOUT",
		"CLAMAV_RTS_CACHE_BASE_DELAY", "CLAMAV_RTS_CACHE_DELAY_PER_MB",
		"TM_RTS_LOG_PATH", "TM_SCAN_BINARY", "TM_TIMEOUT",
		"TM_RTS_CACHE_BASE_DELAY", "TM_RTS_CACHE_DELAY_PER_MB",
	}
	for _, v := range envVars {
		os.Unsetenv(v)
	}

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Check defaults
	if cfg.Port != 3000 {
		t.Errorf("expected Port 3000, got %d", cfg.Port)
	}
	if cfg.UploadDir != "/tmp/av-scanner" {
		t.Errorf("expected UploadDir /tmp/av-scanner, got %s", cfg.UploadDir)
	}
	if cfg.MaxFileSize != 104857600 {
		t.Errorf("expected MaxFileSize 104857600, got %d", cfg.MaxFileSize)
	}
	if cfg.ActiveEngine != EngineClamAV {
		t.Errorf("expected ActiveEngine clamav, got %s", cfg.ActiveEngine)
	}
	if cfg.LogLevel != "info" {
		t.Errorf("expected LogLevel info, got %s", cfg.LogLevel)
	}

	// Check ClamAV driver defaults
	clamav := cfg.Drivers[EngineClamAV]
	if clamav.RTSLogPath != "/var/log/clamav/clamonacc.log" {
		t.Errorf("expected ClamAV RTSLogPath /var/log/clamav/clamonacc.log, got %s", clamav.RTSLogPath)
	}
	if clamav.ScanBinaryPath != "/usr/bin/clamdscan" {
		t.Errorf("expected ClamAV ScanBinaryPath /usr/bin/clamdscan, got %s", clamav.ScanBinaryPath)
	}
	if clamav.Timeout != 15000 {
		t.Errorf("expected ClamAV Timeout 15000, got %d", clamav.Timeout)
	}
	if clamav.RTSCacheBaseDelay != 500 {
		t.Errorf("expected ClamAV RTSCacheBaseDelay 500, got %d", clamav.RTSCacheBaseDelay)
	}
	if clamav.RTSCacheDelayPerMB != 10 {
		t.Errorf("expected ClamAV RTSCacheDelayPerMB 10, got %d", clamav.RTSCacheDelayPerMB)
	}

	// Check TrendMicro driver defaults
	tm := cfg.Drivers[EngineTrendMicro]
	if tm.RTSLogPath != "/var/log/ds_agent/ds_agent.log" {
		t.Errorf("expected TM RTSLogPath /var/log/ds_agent/ds_agent.log, got %s", tm.RTSLogPath)
	}
	if tm.ScanBinaryPath != "/opt/ds_agent/dsa_scan" {
		t.Errorf("expected TM ScanBinaryPath /opt/ds_agent/dsa_scan, got %s", tm.ScanBinaryPath)
	}
}

func TestLoad_CustomValues(t *testing.T) {
	// Set custom env vars
	os.Setenv("PORT", "8080")
	os.Setenv("UPLOAD_DIR", "/custom/uploads")
	os.Setenv("MAX_FILE_SIZE", "52428800")
	os.Setenv("AV_ENGINE", "trendmicro")
	os.Setenv("LOG_LEVEL", "debug")
	os.Setenv("CLAMAV_TIMEOUT", "30000")
	os.Setenv("TM_RTS_CACHE_BASE_DELAY", "1000")

	defer func() {
		os.Unsetenv("PORT")
		os.Unsetenv("UPLOAD_DIR")
		os.Unsetenv("MAX_FILE_SIZE")
		os.Unsetenv("AV_ENGINE")
		os.Unsetenv("LOG_LEVEL")
		os.Unsetenv("CLAMAV_TIMEOUT")
		os.Unsetenv("TM_RTS_CACHE_BASE_DELAY")
	}()

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.Port != 8080 {
		t.Errorf("expected Port 8080, got %d", cfg.Port)
	}
	if cfg.UploadDir != "/custom/uploads" {
		t.Errorf("expected UploadDir /custom/uploads, got %s", cfg.UploadDir)
	}
	if cfg.MaxFileSize != 52428800 {
		t.Errorf("expected MaxFileSize 52428800, got %d", cfg.MaxFileSize)
	}
	if cfg.ActiveEngine != EngineTrendMicro {
		t.Errorf("expected ActiveEngine trendmicro, got %s", cfg.ActiveEngine)
	}
	if cfg.LogLevel != "debug" {
		t.Errorf("expected LogLevel debug, got %s", cfg.LogLevel)
	}
	if cfg.Drivers[EngineClamAV].Timeout != 30000 {
		t.Errorf("expected ClamAV Timeout 30000, got %d", cfg.Drivers[EngineClamAV].Timeout)
	}
	if cfg.Drivers[EngineTrendMicro].RTSCacheBaseDelay != 1000 {
		t.Errorf("expected TM RTSCacheBaseDelay 1000, got %d", cfg.Drivers[EngineTrendMicro].RTSCacheBaseDelay)
	}
}

func TestLoad_InvalidEngine(t *testing.T) {
	os.Setenv("AV_ENGINE", "invalid_engine")
	defer os.Unsetenv("AV_ENGINE")

	_, err := Load()
	if err == nil {
		t.Fatal("expected error for invalid engine")
	}
}

func TestLoad_InvalidPort(t *testing.T) {
	tests := []struct {
		name string
		port string
	}{
		{"zero port", "0"},
		{"negative port", "-1"},
		{"port too high", "65536"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			os.Setenv("PORT", tt.port)
			os.Unsetenv("AV_ENGINE") // ensure valid engine
			defer os.Unsetenv("PORT")

			_, err := Load()
			if err == nil {
				t.Errorf("expected error for %s", tt.name)
			}
		})
	}
}

func TestLoad_InvalidMaxFileSize(t *testing.T) {
	os.Setenv("MAX_FILE_SIZE", "0")
	os.Unsetenv("AV_ENGINE")
	os.Unsetenv("PORT")
	defer os.Unsetenv("MAX_FILE_SIZE")

	_, err := Load()
	if err == nil {
		t.Fatal("expected error for zero max file size")
	}
}

func TestLoad_InvalidIntFallsBackToDefault(t *testing.T) {
	os.Setenv("PORT", "not_a_number")
	os.Unsetenv("AV_ENGINE")
	defer os.Unsetenv("PORT")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should fall back to default
	if cfg.Port != 3000 {
		t.Errorf("expected Port 3000 (default), got %d", cfg.Port)
	}
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name        string
		config      Config
		expectError bool
	}{
		{
			name: "valid config with clamav",
			config: Config{
				Port:         3000,
				ActiveEngine: EngineClamAV,
				MaxFileSize:  100,
			},
			expectError: false,
		},
		{
			name: "valid config with trendmicro",
			config: Config{
				Port:         8080,
				ActiveEngine: EngineTrendMicro,
				MaxFileSize:  100,
			},
			expectError: false,
		},
		{
			name: "valid config with mock",
			config: Config{
				Port:         3000,
				ActiveEngine: EngineMock,
				MaxFileSize:  100,
			},
			expectError: false,
		},
		{
			name: "invalid engine",
			config: Config{
				Port:         3000,
				ActiveEngine: "invalid",
				MaxFileSize:  100,
			},
			expectError: true,
		},
		{
			name: "port too low",
			config: Config{
				Port:         0,
				ActiveEngine: EngineClamAV,
				MaxFileSize:  100,
			},
			expectError: true,
		},
		{
			name: "port too high",
			config: Config{
				Port:         65536,
				ActiveEngine: EngineClamAV,
				MaxFileSize:  100,
			},
			expectError: true,
		},
		{
			name: "invalid max file size",
			config: Config{
				Port:         3000,
				ActiveEngine: EngineClamAV,
				MaxFileSize:  0,
			},
			expectError: true,
		},
		{
			name: "valid edge case port 1",
			config: Config{
				Port:         1,
				ActiveEngine: EngineClamAV,
				MaxFileSize:  1,
			},
			expectError: false,
		},
		{
			name: "valid edge case port 65535",
			config: Config{
				Port:         65535,
				ActiveEngine: EngineClamAV,
				MaxFileSize:  1,
			},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.config.Validate()
			if tt.expectError && err == nil {
				t.Error("expected error but got none")
			}
			if !tt.expectError && err != nil {
				t.Errorf("unexpected error: %v", err)
			}
		})
	}
}

func TestGetEnv(t *testing.T) {
	os.Setenv("TEST_VAR", "custom_value")
	defer os.Unsetenv("TEST_VAR")

	if val := getEnv("TEST_VAR", "default"); val != "custom_value" {
		t.Errorf("expected custom_value, got %s", val)
	}

	if val := getEnv("NONEXISTENT_VAR", "default"); val != "default" {
		t.Errorf("expected default, got %s", val)
	}
}

func TestGetEnvInt(t *testing.T) {
	os.Setenv("TEST_INT", "42")
	os.Setenv("TEST_INVALID_INT", "not_a_number")
	defer func() {
		os.Unsetenv("TEST_INT")
		os.Unsetenv("TEST_INVALID_INT")
	}()

	if val := getEnvInt("TEST_INT", 0); val != 42 {
		t.Errorf("expected 42, got %d", val)
	}

	if val := getEnvInt("TEST_INVALID_INT", 100); val != 100 {
		t.Errorf("expected 100 (default), got %d", val)
	}

	if val := getEnvInt("NONEXISTENT_INT", 99); val != 99 {
		t.Errorf("expected 99 (default), got %d", val)
	}
}

func TestGetEnvInt64(t *testing.T) {
	os.Setenv("TEST_INT64", "9223372036854775807")
	os.Setenv("TEST_INVALID_INT64", "not_a_number")
	defer func() {
		os.Unsetenv("TEST_INT64")
		os.Unsetenv("TEST_INVALID_INT64")
	}()

	if val := getEnvInt64("TEST_INT64", 0); val != 9223372036854775807 {
		t.Errorf("expected max int64, got %d", val)
	}

	if val := getEnvInt64("TEST_INVALID_INT64", 100); val != 100 {
		t.Errorf("expected 100 (default), got %d", val)
	}

	if val := getEnvInt64("NONEXISTENT_INT64", 99); val != 99 {
		t.Errorf("expected 99 (default), got %d", val)
	}
}

func TestEngineTypeConstants(t *testing.T) {
	if EngineClamAV != "clamav" {
		t.Errorf("expected EngineClamAV to be 'clamav', got %s", EngineClamAV)
	}
	if EngineTrendMicro != "trendmicro" {
		t.Errorf("expected EngineTrendMicro to be 'trendmicro', got %s", EngineTrendMicro)
	}
	if EngineMock != "mock" {
		t.Errorf("expected EngineMock to be 'mock', got %s", EngineMock)
	}
}

func TestLoad_AuthConfigDefaults(t *testing.T) {
	// Clear auth env vars
	envVars := []string{"AUTH_ENABLED", "K8S_API_ENDPOINT", "K8S_AUTH_TIMEOUT", "AUTH_ALLOWLIST_FILE"}
	for _, v := range envVars {
		os.Unsetenv(v)
	}
	os.Unsetenv("AV_ENGINE")
	os.Unsetenv("PORT")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.Auth.Enabled {
		t.Error("expected Auth.Enabled to be false by default")
	}
	if cfg.Auth.K8sAPIEndpoint != "" {
		t.Errorf("expected Auth.K8sAPIEndpoint to be empty, got %s", cfg.Auth.K8sAPIEndpoint)
	}
	if cfg.Auth.Timeout != 5000 {
		t.Errorf("expected Auth.Timeout to be 5000, got %d", cfg.Auth.Timeout)
	}
	if cfg.Auth.AllowlistFile != "/etc/av-scanner/allowlist.yaml" {
		t.Errorf("expected Auth.AllowlistFile to be '/etc/av-scanner/allowlist.yaml', got %s", cfg.Auth.AllowlistFile)
	}
}

func TestLoad_AuthConfigEnabled(t *testing.T) {
	os.Setenv("AUTH_ENABLED", "true")
	os.Setenv("K8S_API_ENDPOINT", "http://auth-service:8080")
	os.Setenv("K8S_AUTH_TIMEOUT", "10000")
	os.Setenv("AUTH_ALLOWLIST_FILE", "/custom/allowlist.yaml")
	os.Unsetenv("AV_ENGINE")
	os.Unsetenv("PORT")

	defer func() {
		os.Unsetenv("AUTH_ENABLED")
		os.Unsetenv("K8S_API_ENDPOINT")
		os.Unsetenv("K8S_AUTH_TIMEOUT")
		os.Unsetenv("AUTH_ALLOWLIST_FILE")
	}()

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !cfg.Auth.Enabled {
		t.Error("expected Auth.Enabled to be true")
	}
	if cfg.Auth.K8sAPIEndpoint != "http://auth-service:8080" {
		t.Errorf("expected Auth.K8sAPIEndpoint 'http://auth-service:8080', got %s", cfg.Auth.K8sAPIEndpoint)
	}
	if cfg.Auth.Timeout != 10000 {
		t.Errorf("expected Auth.Timeout 10000, got %d", cfg.Auth.Timeout)
	}
	if cfg.Auth.AllowlistFile != "/custom/allowlist.yaml" {
		t.Errorf("expected Auth.AllowlistFile '/custom/allowlist.yaml', got %s", cfg.Auth.AllowlistFile)
	}
}

func TestValidate_AuthEnabled_MissingK8sAPIEndpoint(t *testing.T) {
	cfg := Config{
		Port:         3000,
		ActiveEngine: EngineClamAV,
		MaxFileSize:  100,
		Auth: AuthConfig{
			Enabled:        true,
			K8sAPIEndpoint: "",
			Timeout:        5000,
		},
	}

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for missing K8S_API_ENDPOINT when auth enabled")
	}
	if err.Error() != "K8S_API_ENDPOINT is required when AUTH_ENABLED=true" {
		t.Errorf("unexpected error message: %s", err.Error())
	}
}

func TestValidate_AuthEnabled_InvalidTimeout(t *testing.T) {
	cfg := Config{
		Port:         3000,
		ActiveEngine: EngineClamAV,
		MaxFileSize:  100,
		Auth: AuthConfig{
			Enabled:        true,
			K8sAPIEndpoint: "http://localhost:8080",
			Timeout:        0,
		},
	}

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected error for invalid auth timeout")
	}
}

func TestValidate_AuthDisabled_NoValidation(t *testing.T) {
	cfg := Config{
		Port:         3000,
		ActiveEngine: EngineClamAV,
		MaxFileSize:  100,
		Auth: AuthConfig{
			Enabled:        false,
			K8sAPIEndpoint: "", // Empty is OK when disabled
			Timeout:        0,  // Zero is OK when disabled
		},
	}

	err := cfg.Validate()
	if err != nil {
		t.Errorf("unexpected error when auth disabled: %v", err)
	}
}

func TestGetEnvBool(t *testing.T) {
	tests := []struct {
		value    string
		expected bool
	}{
		{"true", true},
		{"1", true},
		{"yes", true},
		{"false", false},
		{"0", false},
		{"no", false},
		{"invalid", false},
	}

	for _, tt := range tests {
		os.Setenv("TEST_BOOL", tt.value)
		result := getEnvBool("TEST_BOOL", false)
		if result != tt.expected {
			t.Errorf("getEnvBool(%q) = %v, expected %v", tt.value, result, tt.expected)
		}
		os.Unsetenv("TEST_BOOL")
	}

	// Test default value
	if getEnvBool("NONEXISTENT_BOOL", true) != true {
		t.Error("expected default value true")
	}
	if getEnvBool("NONEXISTENT_BOOL", false) != false {
		t.Error("expected default value false")
	}
}
