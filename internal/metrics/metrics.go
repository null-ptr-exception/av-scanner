package metrics

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "av_http_requests_total",
			Help: "Total HTTP requests",
		},
		[]string{"method", "endpoint", "status_code"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "av_http_request_duration_seconds",
			Help:    "HTTP request duration in seconds",
			Buckets: []float64{0.1, 0.5, 1, 2, 5, 10, 30},
		},
		[]string{"method", "endpoint"},
	)

	scansTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "av_scans_total",
			Help: "Total scans by engine and result",
		},
		[]string{"engine", "result"},
	)

	rateLimitRejectedTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "av_ratelimit_rejected_total",
			Help: "Total requests rejected by per-account rate limits",
		},
		[]string{"account", "reason"},
	)

	rateLimitInflightScans = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "av_ratelimit_inflight_scans",
			Help: "In-flight scans per account",
		},
		[]string{"account"},
	)
)

func init() {
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
	prometheus.MustRegister(scansTotal)
	prometheus.MustRegister(rateLimitRejectedTotal)
	prometheus.MustRegister(rateLimitInflightScans)
}

// Handler returns the Prometheus metrics HTTP handler
func Handler() http.Handler {
	return promhttp.Handler()
}

// RecordScan records a scan result
func RecordScan(engine, result string) {
	scansTotal.WithLabelValues(engine, result).Inc()
}

// RecordRateLimitRejected records a request rejected by per-account rate limits
func RecordRateLimitRejected(account, reason string) {
	rateLimitRejectedTotal.WithLabelValues(account, reason).Inc()
}

// SetRateLimitInflight sets the number of in-flight scans for an account
func SetRateLimitInflight(account string, n int) {
	rateLimitInflightScans.WithLabelValues(account).Set(float64(n))
}

// Middleware wraps an http.Handler and records request metrics
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip metrics endpoint itself
		if r.URL.Path == "/metrics" {
			next.ServeHTTP(w, r)
			return
		}

		start := time.Now()
		wrapped := &responseWriter{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(wrapped, r)

		duration := time.Since(start).Seconds()
		endpoint := r.URL.Path

		httpRequestsTotal.WithLabelValues(r.Method, endpoint, strconv.Itoa(wrapped.status)).Inc()
		httpRequestDuration.WithLabelValues(r.Method, endpoint).Observe(duration)
	})
}

type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}
