package metrics

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestRateLimitMetrics(t *testing.T) {
	RecordRateLimitRejected("metrics-test/sa", "rate")
	RecordRateLimitRejected("metrics-test/sa", "rate")
	if got := testutil.ToFloat64(rateLimitRejectedTotal.WithLabelValues("metrics-test/sa", "rate")); got != 2 {
		t.Errorf("rejected_total = %v, want 2", got)
	}

	SetRateLimitInflight("metrics-test/sa", 3)
	if got := testutil.ToFloat64(rateLimitInflightScans.WithLabelValues("metrics-test/sa")); got != 3 {
		t.Errorf("inflight_scans = %v, want 3", got)
	}
}
