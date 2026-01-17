package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/rophy/av-scanner/internal/auth"
	"github.com/rophy/av-scanner/internal/config"
	"github.com/rophy/av-scanner/internal/metrics"
	"github.com/rophy/av-scanner/internal/scanner"
	"github.com/rophy/av-scanner/internal/version"
)

type API struct {
	scanner        *scanner.Scanner
	config         *config.Config
	logger         *slog.Logger
	authMiddleware *auth.Middleware
	allowlist      *auth.Allowlist
}

func New(s *scanner.Scanner, cfg *config.Config, logger *slog.Logger) (*API, error) {
	api := &API{
		scanner: s,
		config:  cfg,
		logger:  logger,
	}

	// Initialize auth middleware if enabled
	if cfg.Auth.Enabled {
		// Create auth client
		authClient := auth.NewClient(
			cfg.Auth.K8sAPIEndpoint,
			time.Duration(cfg.Auth.Timeout)*time.Millisecond,
			logger,
		)

		// Load allowlist
		allowlist, err := auth.NewAllowlist(cfg.Auth.AllowlistFile, logger)
		if err != nil {
			return nil, err
		}

		// Start watching for allowlist changes
		if err := allowlist.Watch(); err != nil {
			return nil, err
		}

		api.allowlist = allowlist
		api.authMiddleware = auth.NewMiddleware(authClient, allowlist, logger, []string{
			"/api/v1/live",
			"/api/v1/ready",
			"/metrics",
		})

		logger.Info("Authentication enabled",
			"k8sAPIEndpoint", cfg.Auth.K8sAPIEndpoint,
			"allowlistFile", cfg.Auth.AllowlistFile,
		)
	}

	return api, nil
}

func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()

	// API v1 routes
	mux.HandleFunc("POST /api/v1/scan", a.handleScan)
	mux.HandleFunc("GET /api/v1/health", a.handleHealth)
	mux.HandleFunc("GET /api/v1/engines", a.handleEngines)
	mux.HandleFunc("GET /api/v1/ready", a.handleReady)
	mux.HandleFunc("GET /api/v1/live", a.handleLive)
	mux.HandleFunc("GET /api/v1/version", a.handleVersion)

	// Prometheus metrics endpoint
	mux.Handle("GET /metrics", metrics.Handler())

	// Build middleware chain
	var handler http.Handler = mux

	// Apply auth middleware if enabled (innermost - runs first)
	if a.authMiddleware != nil {
		handler = a.authMiddleware.Handler(handler)
	}

	// Apply logging middleware
	handler = a.withLogging(handler)

	// Apply metrics middleware (outermost - runs last)
	handler = metrics.Middleware(handler)

	return handler
}

// Close cleans up API resources
func (a *API) Close() error {
	if a.allowlist != nil {
		return a.allowlist.Close()
	}
	return nil
}

func (a *API) handleScan(w http.ResponseWriter, r *http.Request) {
	// Parse multipart form (max file size)
	if err := r.ParseMultipartForm(a.config.MaxFileSize); err != nil {
		a.jsonError(w, "File too large or invalid form", http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		a.jsonError(w, "No file provided. Please upload a file using the 'file' field", http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Generate file ID and path
	fileID := a.scanner.GenerateFileID()
	filePath := a.scanner.GetUploadPath(fileID, header.Filename)

	// Save uploaded file
	dst, err := os.Create(filePath)
	if err != nil {
		a.logger.Error("Failed to create file", "error", err)
		a.jsonError(w, "Failed to save uploaded file", http.StatusInternalServerError)
		return
	}

	written, err := io.Copy(dst, file)
	dst.Close()
	if err != nil {
		os.Remove(filePath)
		a.logger.Error("Failed to write file", "error", err)
		a.jsonError(w, "Failed to save uploaded file", http.StatusInternalServerError)
		return
	}

	a.logger.Info("Received scan request",
		"fileId", fileID,
		"originalName", header.Filename,
		"size", written,
		"mimeType", header.Header.Get("Content-Type"),
	)

	// Perform scan
	result, err := a.scanner.Scan(filePath, fileID, header.Filename, written)
	if err != nil {
		a.logger.Error("Scan failed", "error", err, "fileId", fileID)
		metrics.RecordScan(string(a.config.ActiveEngine), "error")
		a.jsonError(w, "Scan failed: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Return response
	response := map[string]interface{}{
		"fileId":   result.FileID,
		"fileName": header.Filename,
		"status":   result.Status,
		"engine":   result.Engine,
		"duration": result.TotalDuration,
	}

	if result.Signature != "" {
		response["signature"] = result.Signature
	}

	a.jsonResponse(w, response, http.StatusOK)
}

func (a *API) handleHealth(w http.ResponseWriter, r *http.Request) {
	healthResults := a.scanner.CheckHealth()
	activeEngine := a.scanner.ActiveEngine()

	activeHealthy := false
	for _, h := range healthResults {
		if h.Engine == activeEngine {
			activeHealthy = h.Healthy
			break
		}
	}

	engines := make([]map[string]interface{}, 0, len(healthResults))
	for _, h := range healthResults {
		engine := map[string]interface{}{
			"engine":    h.Engine,
			"healthy":   h.Healthy,
			"lastCheck": h.LastCheck,
		}
		if h.Version != "" {
			engine["version"] = h.Version
		}
		if h.Error != "" {
			engine["error"] = h.Error
		}
		engines = append(engines, engine)
	}

	status := http.StatusOK
	statusText := "healthy"
	if !activeHealthy {
		status = http.StatusServiceUnavailable
		statusText = "unhealthy"
	}

	a.jsonResponse(w, map[string]interface{}{
		"status":       statusText,
		"activeEngine": activeEngine,
		"engines":      engines,
	}, status)
}

func (a *API) handleEngines(w http.ResponseWriter, r *http.Request) {
	engines := a.scanner.GetEngineInfo()
	activeEngine := a.scanner.ActiveEngine()

	engineList := make([]map[string]interface{}, 0, len(engines))
	for _, e := range engines {
		engineList = append(engineList, map[string]interface{}{
			"engine":              e.Engine,
			"available":           e.Available,
			"rtsEnabled":          e.RTSEnabled,
			"manualScanAvailable": e.ManualScanAvailable,
			"active":              e.Engine == activeEngine,
		})
	}

	a.jsonResponse(w, map[string]interface{}{
		"activeEngine": activeEngine,
		"engines":      engineList,
	}, http.StatusOK)
}

func (a *API) handleReady(w http.ResponseWriter, r *http.Request) {
	health, err := a.scanner.GetActiveEngineHealth()
	if err != nil || !health.Healthy {
		errMsg := "Unknown error"
		if err != nil {
			errMsg = err.Error()
		} else if health.Error != "" {
			errMsg = health.Error
		}
		a.jsonResponse(w, map[string]interface{}{
			"ready": false,
			"error": errMsg,
		}, http.StatusServiceUnavailable)
		return
	}

	a.jsonResponse(w, map[string]interface{}{"ready": true}, http.StatusOK)
}

func (a *API) handleLive(w http.ResponseWriter, r *http.Request) {
	a.jsonResponse(w, map[string]interface{}{"alive": true}, http.StatusOK)
}

func (a *API) handleVersion(w http.ResponseWriter, r *http.Request) {
	a.jsonResponse(w, map[string]interface{}{
		"version":   version.Version,
		"commit":    version.Commit,
		"buildTime": version.BuildTime,
	}, http.StatusOK)
}

func (a *API) jsonResponse(w http.ResponseWriter, data interface{}, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func (a *API) jsonError(w http.ResponseWriter, message string, status int) {
	a.jsonResponse(w, map[string]string{"error": message}, status)
}

func (a *API) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		wrapped := &responseWriter{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(wrapped, r)

		a.logger.Info("Request completed",
			"method", r.Method,
			"path", filepath.Clean(r.URL.Path),
			"status", wrapped.status,
			"duration", time.Since(start).Milliseconds(),
		)
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
