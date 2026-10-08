package ratelimit

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"strconv"
)

// Handler enforces limits for the account returned by identity before
// calling next. Requests with an empty identity pass through unchanged.
// Rejected requests get 429 without the body being read.
func (l *Limiter) Handler(identity func(*http.Request) string, logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		account := identity(r)
		if account == "" {
			next.ServeHTTP(w, r)
			return
		}

		release, rej := l.Acquire(account)
		if rej != nil {
			logger.Warn("Rate limit exceeded",
				"identity", account,
				"reason", rej.Reason,
				"limit", rej.Limit,
				"path", r.URL.Path,
				"method", r.Method,
			)
			writeRejection(w, account, rej)
			return
		}
		defer release()

		next.ServeHTTP(w, r)
	})
}

func writeRejection(w http.ResponseWriter, account string, rej *Rejection) {
	retryAfter := int(math.Ceil(rej.RetryAfter.Seconds()))
	if retryAfter < 1 {
		retryAfter = 1
	}

	var message string
	switch rej.Reason {
	case ReasonConcurrency:
		message = fmt.Sprintf("rate limit exceeded for %s: concurrent scans (%d/%d)", account, rej.Limit, rej.Limit)
	default:
		message = fmt.Sprintf("rate limit exceeded for %s: requests per minute (%d)", account, rej.Limit)
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	w.Header().Set("Connection", "close")
	w.WriteHeader(http.StatusTooManyRequests)
	json.NewEncoder(w).Encode(map[string]string{"error": message, "reason": rej.Reason})
}
