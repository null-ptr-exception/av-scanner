package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/rophy/av-scanner/internal/api"
	"github.com/rophy/av-scanner/internal/config"
	"github.com/rophy/av-scanner/internal/scanner"
	"github.com/rophy/av-scanner/internal/version"
)

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		fmt.Printf("av-scanner %s\n", version.Version)
		os.Exit(0)
	}
	// Setup logger
	logLevel := slog.LevelInfo
	if os.Getenv("LOG_LEVEL") == "debug" {
		logLevel = slog.LevelDebug
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: logLevel,
	}))
	logger = logger.With("service", "av-scanner")

	// Load configuration
	cfg, err := config.Load()
	if err != nil {
		logger.Error("Failed to load configuration", "error", err)
		os.Exit(1)
	}

	// Ensure upload directory exists
	if err := os.MkdirAll(cfg.UploadDir, 0755); err != nil {
		logger.Error("Failed to create upload directory", "error", err, "path", cfg.UploadDir)
		os.Exit(1)
	}
	logger.Info("Upload directory ready", "path", cfg.UploadDir)

	// Initialize scanner
	s := scanner.New(cfg, logger)

	// Start background log watchers
	if err := s.Start(); err != nil {
		logger.Error("Failed to start scanner", "error", err)
		os.Exit(1)
	}

	// Check health of all engines
	for _, health := range s.CheckHealth() {
		if health.Healthy {
			logger.Info(fmt.Sprintf("%s is healthy", health.Engine))
		} else {
			logger.Warn(fmt.Sprintf("%s is unhealthy", health.Engine), "error", health.Error)
		}
	}

	// Initialize API
	apiHandler, err := api.New(s, cfg, logger)
	if err != nil {
		logger.Error("Failed to initialize API", "error", err)
		os.Exit(1)
	}

	// Create HTTP server
	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Port),
		Handler:      apiHandler.Routes(),
		ReadTimeout:  5 * time.Minute,
		WriteTimeout: 5 * time.Minute,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in goroutine
	go func() {
		logger.Info("AV Scanner service started",
			"port", cfg.Port,
			"activeEngine", cfg.ActiveEngine,
		)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("Server error", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("Shutting down server...")

	// Graceful shutdown with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		logger.Error("Server forced to shutdown", "error", err)
	}

	// Stop scanner background watchers
	s.Stop()

	// Close API resources
	apiHandler.Close()

	logger.Info("Server exited")
}
