package auth

import (
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/fsnotify/fsnotify"
	"gopkg.in/yaml.v3"
)

// AllowlistConfig represents the YAML structure of the allowlist file
type AllowlistConfig struct {
	Allowlist []string `yaml:"allowlist"`
}

// Allowlist manages a thread-safe set of allowed service accounts
type Allowlist struct {
	mu       sync.RWMutex
	entries  map[string]bool
	filePath string
	logger   *slog.Logger
	watcher  *fsnotify.Watcher
	stopCh   chan struct{}
}

// NewAllowlist creates a new Allowlist and loads entries from the given file
func NewAllowlist(filePath string, logger *slog.Logger) (*Allowlist, error) {
	a := &Allowlist{
		entries:  make(map[string]bool),
		filePath: filePath,
		logger:   logger,
		stopCh:   make(chan struct{}),
	}

	if err := a.load(); err != nil {
		return nil, err
	}

	return a, nil
}

// load reads the allowlist file and populates the entries map
func (a *Allowlist) load() error {
	data, err := os.ReadFile(a.filePath)
	if err != nil {
		return fmt.Errorf("failed to read allowlist file: %w", err)
	}

	var config AllowlistConfig
	if err := yaml.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse allowlist file: %w", err)
	}

	entries := make(map[string]bool)
	for _, entry := range config.Allowlist {
		entries[entry] = true
	}

	a.mu.Lock()
	a.entries = entries
	a.mu.Unlock()

	a.logger.Info("Allowlist loaded", "entries", len(entries))
	return nil
}

// IsAllowed checks if the given namespace/serviceAccount is in the allowlist
func (a *Allowlist) IsAllowed(namespace, serviceAccount string) bool {
	key := fmt.Sprintf("%s/%s", namespace, serviceAccount)
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.entries[key]
}

// Watch starts watching the allowlist file for changes and reloads on modification
func (a *Allowlist) Watch() error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("failed to create file watcher: %w", err)
	}
	a.watcher = watcher

	if err := watcher.Add(a.filePath); err != nil {
		watcher.Close()
		return fmt.Errorf("failed to watch allowlist file: %w", err)
	}

	go func() {
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				if event.Op&(fsnotify.Write|fsnotify.Create) != 0 {
					a.logger.Info("Allowlist file changed, reloading", "path", a.filePath)
					if err := a.load(); err != nil {
						a.logger.Error("Failed to reload allowlist", "error", err)
					}
				}
			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				a.logger.Error("File watcher error", "error", err)
			case <-a.stopCh:
				return
			}
		}
	}()

	a.logger.Info("Watching allowlist file for changes", "path", a.filePath)
	return nil
}

// Close stops the file watcher
func (a *Allowlist) Close() error {
	close(a.stopCh)
	if a.watcher != nil {
		return a.watcher.Close()
	}
	return nil
}
