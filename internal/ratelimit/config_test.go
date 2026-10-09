package ratelimit

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func intPtr(v int) *int { return &v }

func TestConfig_ForMergesOverrideFieldByField(t *testing.T) {
	cfg := &Config{
		Default: Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10},
		Overrides: map[string]Override{
			"ns/heavy":     {MaxConcurrent: intPtr(16)},
			"ns/unlimited": {MaxConcurrent: intPtr(0), RequestsPerMinute: intPtr(0)},
		},
	}

	tests := []struct {
		account string
		want    Limits
	}{
		{"ns/other", Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10}},
		{"ns/heavy", Limits{MaxConcurrent: 16, RequestsPerMinute: 60, Burst: 10}},
		{"ns/unlimited", Limits{MaxConcurrent: 0, RequestsPerMinute: 0, Burst: 10}},
	}

	for _, tt := range tests {
		if got := cfg.For(tt.account); got != tt.want {
			t.Errorf("For(%q) = %+v, want %+v", tt.account, got, tt.want)
		}
	}
}

func TestConfig_ParseYAML(t *testing.T) {
	data := `
default:
  maxConcurrent: 4
  requestsPerMinute: 60
  burst: 10
overrides:
  team-b/batch-job:
    maxConcurrent: 16
`
	var cfg Config
	if err := yaml.Unmarshal([]byte(data), &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	want := Limits{MaxConcurrent: 16, RequestsPerMinute: 60, Burst: 10}
	if got := cfg.For("team-b/batch-job"); got != want {
		t.Errorf("For(team-b/batch-job) = %+v, want %+v", got, want)
	}
}

func TestConfig_Validate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr string
	}{
		{"empty config is valid", Config{}, ""},
		{"full default", Config{Default: Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10}}, ""},
		{"concurrency only", Config{Default: Limits{MaxConcurrent: 2}}, ""},
		{"negative maxConcurrent", Config{Default: Limits{MaxConcurrent: -1}}, "rateLimits.default: negative values are not allowed"},
		{"rate without burst", Config{Default: Limits{RequestsPerMinute: 60}}, "rateLimits.default: burst must be > 0 when requestsPerMinute is set"},
		{
			"override rate without burst",
			Config{Overrides: map[string]Override{"ns/sa": {RequestsPerMinute: intPtr(10)}}},
			"rateLimits.overrides[ns/sa]: burst must be > 0",
		},
		{
			"override negative burst",
			Config{
				Default:   Limits{MaxConcurrent: 4, RequestsPerMinute: 60, Burst: 10},
				Overrides: map[string]Override{"ns/sa": {Burst: intPtr(-5)}},
			},
			"rateLimits.overrides[ns/sa]: negative values are not allowed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("error = %v, want containing %q", err, tt.wantErr)
			}
		})
	}
}
