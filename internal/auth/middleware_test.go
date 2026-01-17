package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func setupTestMiddleware(t *testing.T, authServerHandler http.HandlerFunc) (*Middleware, *httptest.Server, func()) {
	// Create mock auth server
	authServer := httptest.NewServer(authServerHandler)

	// Create allowlist file
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "allowlist.yaml")
	content := `allowlist:
  - test-ns/test-sa
  - allowed-ns/allowed-sa
`
	if err := os.WriteFile(tmpFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write allowlist: %v", err)
	}

	// Create allowlist
	allowlist, err := NewAllowlist(tmpFile, testLogger())
	if err != nil {
		t.Fatalf("failed to create allowlist: %v", err)
	}

	// Create client
	client := NewClient(authServer.URL, 5*time.Second, testLogger())

	// Create middleware
	middleware := NewMiddleware(client, allowlist, testLogger(), []string{
		"/api/v1/live",
		"/api/v1/ready",
	})

	cleanup := func() {
		authServer.Close()
	}

	return middleware, authServer, cleanup
}

func TestMiddleware_SkipPaths(t *testing.T) {
	middleware, _, cleanup := setupTestMiddleware(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("auth server should not be called for skip paths")
	})
	defer cleanup()

	handler := middleware.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	}))

	skipPaths := []string{"/api/v1/live", "/api/v1/ready"}
	for _, path := range skipPaths {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()

		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Errorf("expected 200 for %s, got %d", path, rec.Code)
		}
	}
}

func TestMiddleware_MissingAuthHeader(t *testing.T) {
	middleware, _, cleanup := setupTestMiddleware(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("auth server should not be called without auth header")
	})
	defer cleanup()

	handler := middleware.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called without auth")
	}))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/scan", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}

	var resp map[string]string
	json.NewDecoder(rec.Body).Decode(&resp)
	if resp["error"] != "missing Authorization header" {
		t.Errorf("unexpected error message: %s", resp["error"])
	}
}

func TestMiddleware_InvalidAuthHeaderFormat(t *testing.T) {
	middleware, _, cleanup := setupTestMiddleware(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("auth server should not be called with invalid header format")
	})
	defer cleanup()

	handler := middleware.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called without valid auth")
	}))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/scan", nil)
	req.Header.Set("Authorization", "Basic abc123") // Not Bearer
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}

	var resp map[string]string
	json.NewDecoder(rec.Body).Decode(&resp)
	if resp["error"] != "invalid Authorization header format, expected 'Bearer <token>'" {
		t.Errorf("unexpected error message: %s", resp["error"])
	}
}

func TestMiddleware_ValidTokenAndInAllowlist(t *testing.T) {
	middleware, _, cleanup := setupTestMiddleware(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: true,
				User: &UserInfo{
					Username: "system:serviceaccount:test-ns:test-sa",
					UID:      "test-uid",
				},
			},
		})
	})
	defer cleanup()

	handlerCalled := false
	handler := middleware.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlerCalled = true

		// Verify identity is in context
		identity := GetCallerIdentity(r.Context())
		if identity == nil {
			t.Error("expected identity in context")
			return
		}
		if identity.Namespace != "test-ns" {
			t.Errorf("expected namespace 'test-ns', got '%s'", identity.Namespace)
		}
		if identity.ServiceAccount != "test-sa" {
			t.Errorf("expected serviceAccount 'test-sa', got '%s'", identity.ServiceAccount)
		}

		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/scan", nil)
	req.Header.Set("Authorization", "Bearer valid-token")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
	if !handlerCalled {
		t.Error("handler was not called")
	}
}

func TestMiddleware_ValidTokenButNotInAllowlist(t *testing.T) {
	middleware, _, cleanup := setupTestMiddleware(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: true,
				User: &UserInfo{
					Username: "system:serviceaccount:unauthorized-ns:unauthorized-sa",
					UID:      "test-uid",
				},
			},
		})
	})
	defer cleanup()

	handler := middleware.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called for unauthorized service account")
	}))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/scan", nil)
	req.Header.Set("Authorization", "Bearer valid-token")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Errorf("expected 403, got %d", rec.Code)
	}

	var resp map[string]string
	json.NewDecoder(rec.Body).Decode(&resp)
	if resp["error"] != "forbidden: unauthorized-ns/unauthorized-sa not in allowlist" {
		t.Errorf("unexpected error message: %s", resp["error"])
	}
}

func TestMiddleware_InvalidToken(t *testing.T) {
	middleware, _, cleanup := setupTestMiddleware(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: false,
				Error:         "invalid token",
			},
		})
	})
	defer cleanup()

	handler := middleware.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called for invalid token")
	}))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/scan", nil)
	req.Header.Set("Authorization", "Bearer invalid-token")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestGetCallerIdentity_NoIdentity(t *testing.T) {
	ctx := context.Background()
	identity := GetCallerIdentity(ctx)
	if identity != nil {
		t.Error("expected nil identity for empty context")
	}
}
