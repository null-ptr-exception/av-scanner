package cache

import (
	"sync"
	"testing"
	"time"
)

func TestNewDetectionCache(t *testing.T) {
	t.Run("uses default TTL when zero", func(t *testing.T) {
		c := NewDetectionCache(0)
		defer c.Stop()

		if c.ttl != DefaultTTL {
			t.Errorf("expected TTL %v, got %v", DefaultTTL, c.ttl)
		}
	})

	t.Run("uses custom TTL", func(t *testing.T) {
		customTTL := 5 * time.Second
		c := NewDetectionCache(customTTL)
		defer c.Stop()

		if c.ttl != customTTL {
			t.Errorf("expected TTL %v, got %v", customTTL, c.ttl)
		}
	})
}

func TestDetectionCache_Add(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	detection := &Detection{
		FilePath:  "/tmp/test.txt",
		Status:    "infected",
		Signature: "EICAR-Test",
		Raw:       "test raw data",
	}

	c.Add("/tmp/test.txt", detection)

	// Verify it was added
	cached, found := c.Peek("/tmp/test.txt")
	if !found {
		t.Fatal("expected detection to be found")
	}
	if cached.Signature != "EICAR-Test" {
		t.Errorf("expected signature EICAR-Test, got %s", cached.Signature)
	}
	if cached.Timestamp.IsZero() {
		t.Error("expected timestamp to be set")
	}
}

func TestDetectionCache_Get(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	detection := &Detection{
		FilePath:  "/tmp/test.txt",
		Status:    "infected",
		Signature: "EICAR-Test",
	}
	c.Add("/tmp/test.txt", detection)

	t.Run("retrieves and removes detection", func(t *testing.T) {
		cached, found := c.Get("/tmp/test.txt")
		if !found {
			t.Fatal("expected detection to be found")
		}
		if cached.Signature != "EICAR-Test" {
			t.Errorf("expected signature EICAR-Test, got %s", cached.Signature)
		}

		// Should be removed now
		_, found = c.Get("/tmp/test.txt")
		if found {
			t.Error("expected detection to be removed after Get")
		}
	})

	t.Run("returns false for non-existent key", func(t *testing.T) {
		_, found := c.Get("/nonexistent")
		if found {
			t.Error("expected false for non-existent key")
		}
	})
}

func TestDetectionCache_Peek(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	detection := &Detection{
		FilePath:  "/tmp/test.txt",
		Status:    "clean",
		Signature: "",
	}
	c.Add("/tmp/test.txt", detection)

	t.Run("retrieves without removing", func(t *testing.T) {
		cached, found := c.Peek("/tmp/test.txt")
		if !found {
			t.Fatal("expected detection to be found")
		}
		if cached.Status != "clean" {
			t.Errorf("expected status clean, got %s", cached.Status)
		}

		// Should still be there
		_, found = c.Peek("/tmp/test.txt")
		if !found {
			t.Error("expected detection to still exist after Peek")
		}
	})

	t.Run("returns false for non-existent key", func(t *testing.T) {
		_, found := c.Peek("/nonexistent")
		if found {
			t.Error("expected false for non-existent key")
		}
	})
}

func TestDetectionCache_Cleanup(t *testing.T) {
	// Use a short TTL for testing
	c := NewDetectionCache(50 * time.Millisecond)
	defer c.Stop()

	detection := &Detection{
		FilePath:  "/tmp/test.txt",
		Status:    "infected",
		Signature: "Test-Virus",
	}
	c.Add("/tmp/test.txt", detection)

	// Verify it exists
	_, found := c.Peek("/tmp/test.txt")
	if !found {
		t.Fatal("expected detection to be found initially")
	}

	// Wait for TTL to expire
	time.Sleep(60 * time.Millisecond)

	// Manually trigger cleanup (since cleanup interval is 30s)
	c.cleanup()

	// Should be cleaned up
	_, found = c.Peek("/tmp/test.txt")
	if found {
		t.Error("expected detection to be cleaned up after TTL")
	}
}

func TestDetectionCache_ConcurrentAccess(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	var wg sync.WaitGroup
	numGoroutines := 100

	// Concurrent writes
	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			detection := &Detection{
				FilePath:  "/tmp/test.txt",
				Status:    "infected",
				Signature: "Test",
			}
			c.Add("/tmp/test.txt", detection)
		}(i)
	}

	// Concurrent reads
	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.Peek("/tmp/test.txt")
		}()
	}

	wg.Wait()
	// If we reach here without race detector errors, the test passes
}

func TestDetectionCache_Stop(t *testing.T) {
	c := NewDetectionCache(time.Minute)

	// Should not panic on stop
	c.Stop()

	// Double stop should not panic (channel already closed)
	// Note: This will panic, so we don't test double-stop
}

func TestDetectionCache_OverwriteExisting(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	detection1 := &Detection{
		FilePath:  "/tmp/test.txt",
		Status:    "clean",
		Signature: "",
	}
	c.Add("/tmp/test.txt", detection1)

	detection2 := &Detection{
		FilePath:  "/tmp/test.txt",
		Status:    "infected",
		Signature: "New-Virus",
	}
	c.Add("/tmp/test.txt", detection2)

	cached, found := c.Peek("/tmp/test.txt")
	if !found {
		t.Fatal("expected detection to be found")
	}
	if cached.Status != "infected" || cached.Signature != "New-Virus" {
		t.Errorf("expected overwritten detection, got status=%s signature=%s", cached.Status, cached.Signature)
	}
}

func TestDetectionCache_WaitReturnsLateDetection(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	go func() {
		time.Sleep(50 * time.Millisecond)
		c.Add("/tmp/other", &Detection{Status: "infected"})
		time.Sleep(50 * time.Millisecond)
		c.Add("/tmp/late", &Detection{Status: "infected", Signature: "sig"})
	}()

	d, found := c.Wait("/tmp/late", time.Second)
	if !found || d.Signature != "sig" {
		t.Fatalf("expected late detection, got %v %v", d, found)
	}
	if _, found := c.Peek("/tmp/late"); found {
		t.Error("expected Wait to remove the detection")
	}
}

func TestDetectionCache_WaitTimesOut(t *testing.T) {
	c := NewDetectionCache(time.Minute)
	defer c.Stop()

	start := time.Now()
	if _, found := c.Wait("/tmp/none", 100*time.Millisecond); found {
		t.Fatal("expected no detection")
	}
	if elapsed := time.Since(start); elapsed < 90*time.Millisecond {
		t.Errorf("returned too early: %v", elapsed)
	}
}
