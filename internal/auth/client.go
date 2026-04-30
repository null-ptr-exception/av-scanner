package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"net/http"
	"strings"
	"time"
)

// tokenReviewPath is the Kubernetes TokenReview API path
const tokenReviewPath = "/apis/authentication.k8s.io/v1/tokenreviews"

// TokenReviewRequest is a Kubernetes TokenReview request
type TokenReviewRequest struct {
	APIVersion string          `json:"apiVersion"`
	Kind       string          `json:"kind"`
	Spec       TokenReviewSpec `json:"spec"`
}

// TokenReviewSpec contains the token to be reviewed
type TokenReviewSpec struct {
	Token     string   `json:"token"`
	Audiences []string `json:"audiences,omitempty"`
}

// TokenReviewResponse is a Kubernetes TokenReview response
type TokenReviewResponse struct {
	APIVersion string            `json:"apiVersion"`
	Kind       string            `json:"kind"`
	Status     TokenReviewStatus `json:"status"`
}

// TokenReviewStatus contains the result of the token review
type TokenReviewStatus struct {
	Authenticated bool      `json:"authenticated"`
	User          *UserInfo `json:"user,omitempty"`
	Error         string    `json:"error,omitempty"`
}

// UserInfo contains information about the authenticated user
type UserInfo struct {
	Username string              `json:"username"`
	UID      string              `json:"uid"`
	Groups   []string            `json:"groups,omitempty"`
	Extra    map[string][]string `json:"extra,omitempty"`
}

// CallerIdentity represents the authenticated caller information
type CallerIdentity struct {
	Namespace      string
	ServiceAccount string
	UID            string
}

// Client handles authentication via Kubernetes TokenReview API
type Client struct {
	baseURL    string
	tokenPath  string
	httpClient *http.Client
	logger     *slog.Logger
}

// NewClient creates a new auth client.
// tokenPath is optional — when set, the client reads a SA token from that file
// and sends it as Authorization header when calling the auth service.
func NewClient(baseURL string, timeout time.Duration, logger *slog.Logger, tokenPath string) *Client {
	return &Client{
		baseURL:   baseURL,
		tokenPath: tokenPath,
		httpClient: &http.Client{
			Timeout: timeout,
		},
		logger: logger,
	}
}

// Validate validates a token via Kubernetes TokenReview API
func (c *Client) Validate(ctx context.Context, token string) (*CallerIdentity, error) {
	reqBody := TokenReviewRequest{
		APIVersion: "authentication.k8s.io/v1",
		Kind:       "TokenReview",
		Spec: TokenReviewSpec{
			Token: token,
		},
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+tokenReviewPath, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	if c.tokenPath != "" {
		saToken, err := os.ReadFile(c.tokenPath)
		if err != nil {
			return nil, fmt.Errorf("failed to read service account token from %s: %w", c.tokenPath, err)
		}
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(saToken)))
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to call auth service: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		c.logger.Error("auth service error",
			"status", resp.StatusCode,
			"body", string(body),
		)
		return nil, fmt.Errorf("auth service error: status %d", resp.StatusCode)
	}

	var reviewResp TokenReviewResponse
	if err := json.NewDecoder(resp.Body).Decode(&reviewResp); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	if !reviewResp.Status.Authenticated {
		return nil, fmt.Errorf("authentication failed: %s", reviewResp.Status.Error)
	}

	if reviewResp.Status.User == nil {
		return nil, fmt.Errorf("invalid response: missing user info")
	}

	identity, err := parseServiceAccountUsername(reviewResp.Status.User.Username)
	if err != nil {
		return nil, err
	}
	identity.UID = reviewResp.Status.User.UID

	c.logger.Info("authentication successful",
		"identity", fmt.Sprintf("%s/%s", identity.Namespace, identity.ServiceAccount),
	)
	return identity, nil
}

// parseServiceAccountUsername parses "system:serviceaccount:namespace:name" format
func parseServiceAccountUsername(username string) (*CallerIdentity, error) {
	parts := strings.Split(username, ":")
	if len(parts) != 4 || parts[0] != "system" || parts[1] != "serviceaccount" {
		return nil, fmt.Errorf("invalid serviceaccount username format: %s", username)
	}
	return &CallerIdentity{
		Namespace:      parts[2],
		ServiceAccount: parts[3],
	}, nil
}
