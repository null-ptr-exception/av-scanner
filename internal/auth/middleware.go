package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
)

type contextKey string

const CallerIdentityKey contextKey = "callerIdentity"

// Middleware handles authentication and authorization for HTTP requests
type Middleware struct {
	client    *Client
	allowlist *Allowlist
	logger    *slog.Logger
	skipPaths map[string]bool
}

// NewMiddleware creates a new auth middleware
func NewMiddleware(client *Client, allowlist *Allowlist, logger *slog.Logger, skipPaths []string) *Middleware {
	skip := make(map[string]bool)
	for _, path := range skipPaths {
		skip[path] = true
	}
	return &Middleware{
		client:    client,
		allowlist: allowlist,
		logger:    logger,
		skipPaths: skip,
	}
}

// Handler wraps an http.Handler with authentication and authorization
func (m *Middleware) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip authentication for specified paths
		if m.skipPaths[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}

		// Extract token from Authorization header
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			m.jsonError(w, "missing Authorization header", http.StatusUnauthorized)
			return
		}

		token := strings.TrimPrefix(authHeader, "Bearer ")
		if token == authHeader {
			m.jsonError(w, "invalid Authorization header format, expected 'Bearer <token>'", http.StatusUnauthorized)
			return
		}

		// Validate token
		identity, err := m.client.Validate(r.Context(), token)
		if err != nil {
			m.logger.Warn("Authentication failed",
				"error", err,
				"path", r.URL.Path,
				"method", r.Method,
			)
			m.jsonError(w, "authentication failed: "+err.Error(), http.StatusUnauthorized)
			return
		}

		// Check allowlist authorization
		if !m.allowlist.IsAllowed(identity.Namespace, identity.ServiceAccount) {
			m.logger.Warn("Authorization failed: not in allowlist",
				"identity", fmt.Sprintf("%s/%s", identity.Namespace, identity.ServiceAccount),
				"path", r.URL.Path,
				"method", r.Method,
			)
			m.jsonError(w, fmt.Sprintf("forbidden: %s/%s not in allowlist",
				identity.Namespace, identity.ServiceAccount), http.StatusForbidden)
			return
		}

		// Log successful authentication
		m.logger.Info("Request authenticated",
			"identity", fmt.Sprintf("%s/%s", identity.Namespace, identity.ServiceAccount),
			"path", r.URL.Path,
			"method", r.Method,
		)

		// Add identity to context
		ctx := context.WithValue(r.Context(), CallerIdentityKey, identity)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (m *Middleware) jsonError(w http.ResponseWriter, message string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}

// GetCallerIdentity retrieves the caller identity from context
func GetCallerIdentity(ctx context.Context) *CallerIdentity {
	if identity, ok := ctx.Value(CallerIdentityKey).(*CallerIdentity); ok {
		return identity
	}
	return nil
}
