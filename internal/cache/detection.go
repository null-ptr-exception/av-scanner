package cache

import (
	"sync"
	"time"
)

const (
	DefaultTTL             = 60 * time.Second
	DefaultCleanupInterval = 30 * time.Second
)

// Detection represents a cached malware detection
type Detection struct {
	FilePath  string
	Status    string // "infected" or "clean"
	Signature string
	Raw       string
	Timestamp time.Time
}

// DetectionCache is a thread-safe cache for malware detections
type DetectionCache struct {
	detections map[string]*Detection // keyed by absolute file path
	mu         sync.RWMutex
	ttl        time.Duration
	stopCh     chan struct{}
	added      chan struct{} // closed and replaced on every Add, to wake waiters
}

func NewDetectionCache(ttl time.Duration) *DetectionCache {
	if ttl == 0 {
		ttl = DefaultTTL
	}
	c := &DetectionCache{
		detections: make(map[string]*Detection),
		ttl:        ttl,
		stopCh:     make(chan struct{}),
		added:      make(chan struct{}),
	}
	go c.cleanupLoop()
	return c
}

// Add stores a detection in the cache
func (c *DetectionCache) Add(absPath string, detection *Detection) {
	c.mu.Lock()
	detection.Timestamp = time.Now()
	c.detections[absPath] = detection
	close(c.added)
	c.added = make(chan struct{})
	c.mu.Unlock()
}

// Wait returns and removes the detection for absPath, waiting up to timeout
// for one to be added. It returns false if none arrives in time.
func (c *DetectionCache) Wait(absPath string, timeout time.Duration) (*Detection, bool) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		c.mu.Lock()
		if cached, found := c.detections[absPath]; found {
			delete(c.detections, absPath)
			c.mu.Unlock()
			return cached, true
		}
		added := c.added
		c.mu.Unlock()

		select {
		case <-added:
		case <-timer.C:
			return nil, false
		}
	}
}

// Get retrieves and removes a detection from the cache
func (c *DetectionCache) Get(absPath string) (*Detection, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	cached, found := c.detections[absPath]
	if found {
		delete(c.detections, absPath)
	}
	return cached, found
}

// Peek retrieves a detection without removing it
func (c *DetectionCache) Peek(absPath string) (*Detection, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	cached, found := c.detections[absPath]
	return cached, found
}

// Stop stops the cleanup goroutine
func (c *DetectionCache) Stop() {
	close(c.stopCh)
}

func (c *DetectionCache) cleanupLoop() {
	ticker := time.NewTicker(DefaultCleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-c.stopCh:
			return
		case <-ticker.C:
			c.cleanup()
		}
	}
}

func (c *DetectionCache) cleanup() {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	for path, detection := range c.detections {
		if now.Sub(detection.Timestamp) > c.ttl {
			delete(c.detections, path)
		}
	}
}
