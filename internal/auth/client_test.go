package auth

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelError}))
}

func TestClient_Validate_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if r.URL.Path != tokenReviewPath {
			t.Errorf("expected %s, got %s", tokenReviewPath, r.URL.Path)
		}

		var req TokenReviewRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("failed to decode request: %v", err)
		}

		if req.APIVersion != "authentication.k8s.io/v1" {
			t.Errorf("expected apiVersion 'authentication.k8s.io/v1', got '%s'", req.APIVersion)
		}
		if req.Kind != "TokenReview" {
			t.Errorf("expected kind 'TokenReview', got '%s'", req.Kind)
		}
		if req.Spec.Token != "test-token" {
			t.Errorf("expected token 'test-token', got '%s'", req.Spec.Token)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: true,
				User: &UserInfo{
					Username: "system:serviceaccount:test-ns:test-sa",
					UID:      "test-uid",
					Groups:   []string{"system:serviceaccounts", "system:serviceaccounts:test-ns"},
				},
			},
		})
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), "")
	identity, err := client.Validate(context.Background(), "test-token")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if identity.Namespace != "test-ns" {
		t.Errorf("expected namespace 'test-ns', got '%s'", identity.Namespace)
	}
	if identity.ServiceAccount != "test-sa" {
		t.Errorf("expected serviceAccount 'test-sa', got '%s'", identity.ServiceAccount)
	}
	if identity.UID != "test-uid" {
		t.Errorf("expected uid 'test-uid', got '%s'", identity.UID)
	}
}

func TestClient_Validate_Unauthenticated(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: false,
				Error:         "token has expired",
			},
		})
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), "")
	_, err := client.Validate(context.Background(), "expired-token")

	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "authentication failed: token has expired" {
		t.Errorf("expected 'authentication failed' error, got '%s'", err.Error())
	}
}

func TestClient_Validate_InvalidSignature(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: false,
				Error:         "invalid token signature",
			},
		})
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), "")
	_, err := client.Validate(context.Background(), "invalid-token")

	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "authentication failed: invalid token signature" {
		t.Errorf("expected 'authentication failed' error, got '%s'", err.Error())
	}
}

func TestClient_Validate_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("internal server error"))
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), "")
	_, err := client.Validate(context.Background(), "test-token")

	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "auth service error: status 500" {
		t.Errorf("expected 'auth service error' error, got '%s'", err.Error())
	}
}

func TestClient_Validate_NetworkError(t *testing.T) {
	client := NewClient("http://localhost:99999", 1*time.Second, testLogger(), "")
	_, err := client.Validate(context.Background(), "test-token")

	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestClient_Validate_InvalidUsernameFormat(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(TokenReviewResponse{
			APIVersion: "authentication.k8s.io/v1",
			Kind:       "TokenReview",
			Status: TokenReviewStatus{
				Authenticated: true,
				User: &UserInfo{
					Username: "invalid-username-format",
					UID:      "test-uid",
				},
			},
		})
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), "")
	_, err := client.Validate(context.Background(), "test-token")

	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "invalid serviceaccount username format: invalid-username-format" {
		t.Errorf("expected 'invalid serviceaccount username format' error, got '%s'", err.Error())
	}
}

func TestParseServiceAccountUsername(t *testing.T) {
	tests := []struct {
		name        string
		username    string
		wantNS      string
		wantSA      string
		wantErr     bool
		errContains string
	}{
		{
			name:     "valid username",
			username: "system:serviceaccount:my-namespace:my-sa",
			wantNS:   "my-namespace",
			wantSA:   "my-sa",
			wantErr:  false,
		},
		{
			name:     "valid with dashes",
			username: "system:serviceaccount:kube-system:default",
			wantNS:   "kube-system",
			wantSA:   "default",
			wantErr:  false,
		},
		{
			name:        "invalid prefix",
			username:    "user:serviceaccount:ns:sa",
			wantErr:     true,
			errContains: "invalid serviceaccount username format",
		},
		{
			name:        "invalid type",
			username:    "system:user:ns:sa",
			wantErr:     true,
			errContains: "invalid serviceaccount username format",
		},
		{
			name:        "too few parts",
			username:    "system:serviceaccount:ns",
			wantErr:     true,
			errContains: "invalid serviceaccount username format",
		},
		{
			name:        "too many parts",
			username:    "system:serviceaccount:ns:sa:extra",
			wantErr:     true,
			errContains: "invalid serviceaccount username format",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			identity, err := parseServiceAccountUsername(tt.username)
			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error, got nil")
				} else if tt.errContains != "" && err.Error() != tt.errContains+": "+tt.username {
					t.Errorf("error = %v, want contains %v", err.Error(), tt.errContains)
				}
				return
			}
			if err != nil {
				t.Errorf("unexpected error: %v", err)
				return
			}
			if identity.Namespace != tt.wantNS {
				t.Errorf("namespace = %v, want %v", identity.Namespace, tt.wantNS)
			}
			if identity.ServiceAccount != tt.wantSA {
				t.Errorf("serviceAccount = %v, want %v", identity.ServiceAccount, tt.wantSA)
			}
		})
	}
}

func TestClient_Validate_WithServiceAccountToken(t *testing.T) {
	tokenFile := t.TempDir() + "/token"
	if err := os.WriteFile(tokenFile, []byte("my-sa-token\n"), 0600); err != nil {
		t.Fatalf("failed to write token file: %v", err)
	}

	var receivedAuthHeader string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedAuthHeader = r.Header.Get("Authorization")
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
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), tokenFile)
	_, err := client.Validate(context.Background(), "client-token")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if receivedAuthHeader != "Bearer my-sa-token" {
		t.Errorf("expected Authorization 'Bearer my-sa-token', got '%s'", receivedAuthHeader)
	}
}

func TestClient_Validate_WithMissingTokenFile(t *testing.T) {
	client := NewClient("http://localhost", 5*time.Second, testLogger(), "/nonexistent/token")
	_, err := client.Validate(context.Background(), "client-token")

	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "failed to read service account token") {
		t.Errorf("expected token read error, got: %s", err.Error())
	}
}

func TestClient_Validate_WithoutServiceAccountToken(t *testing.T) {
	var receivedAuthHeader string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedAuthHeader = r.Header.Get("Authorization")
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
	}))
	defer server.Close()

	client := NewClient(server.URL, 5*time.Second, testLogger(), "")
	_, err := client.Validate(context.Background(), "client-token")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if receivedAuthHeader != "" {
		t.Errorf("expected no Authorization header, got '%s'", receivedAuthHeader)
	}
}
