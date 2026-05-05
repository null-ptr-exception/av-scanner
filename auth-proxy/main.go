package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"sync"
	"time"
)

const (
	defaultTokenPath  = "/var/run/secrets/kubernetes.io/serviceaccount/token" // nosemgrep: hardcoded-password
	defaultListenAddr = ":8080"
	tokenRefreshInterval = 30 * time.Second
)

type tokenProvider struct {
	path  string
	token string
	mu    sync.RWMutex
}

func newTokenProvider(path string) (*tokenProvider, error) {
	tp := &tokenProvider{path: path}
	if err := tp.refresh(); err != nil {
		return nil, err
	}
	go tp.refreshLoop()
	return tp, nil
}

func (tp *tokenProvider) refresh() error {
	data, err := os.ReadFile(tp.path)
	if err != nil {
		return err
	}
	tp.mu.Lock()
	tp.token = string(data)
	tp.mu.Unlock()
	return nil
}

func (tp *tokenProvider) refreshLoop() {
	ticker := time.NewTicker(tokenRefreshInterval)
	defer ticker.Stop()
	for range ticker.C {
		if err := tp.refresh(); err != nil {
			log.Printf("failed to refresh token: %v", err)
		}
	}
}

func (tp *tokenProvider) Token() string {
	tp.mu.RLock()
	defer tp.mu.RUnlock()
	return tp.token
}

func main() {
	upstreamURL := os.Getenv("UPSTREAM_URL")
	if upstreamURL == "" {
		log.Fatal("UPSTREAM_URL environment variable is required")
	}

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = defaultListenAddr
	}

	tokenPath := os.Getenv("TOKEN_PATH")
	if tokenPath == "" {
		tokenPath = defaultTokenPath
	}

	target, err := url.Parse(upstreamURL)
	if err != nil {
		log.Fatalf("invalid UPSTREAM_URL: %v", err)
	}

	tp, err := newTokenProvider(tokenPath)
	if err != nil {
		log.Fatalf("failed to read service account token: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Header.Set("Authorization", "Bearer "+tp.Token())
		req.Host = target.Host
	}

	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("proxy error: %v", err)
		http.Error(w, "upstream error", http.StatusBadGateway)
	}

	log.Printf("starting kube-auth-proxy on %s -> %s", listenAddr, upstreamURL)
	if err := http.ListenAndServe(listenAddr, proxy); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
