package ratelimit

import (
	"errors"
	"fmt"
)

// Limits are the effective limits for one account. 0 means unlimited.
type Limits struct {
	MaxConcurrent     int `yaml:"maxConcurrent"`
	RequestsPerMinute int `yaml:"requestsPerMinute"`
	Burst             int `yaml:"burst"`
}

// Override replaces individual default fields for one account.
// A nil field inherits the default.
type Override struct {
	MaxConcurrent     *int `yaml:"maxConcurrent"`
	RequestsPerMinute *int `yaml:"requestsPerMinute"`
	Burst             *int `yaml:"burst"`
}

// Config is the rateLimits section of the allowlist file
type Config struct {
	Default   Limits              `yaml:"default"`
	Overrides map[string]Override `yaml:"overrides"`
}

// For returns the effective limits for an account ("namespace/serviceaccount")
func (c *Config) For(account string) Limits {
	l := c.Default
	o, ok := c.Overrides[account]
	if !ok {
		return l
	}
	if o.MaxConcurrent != nil {
		l.MaxConcurrent = *o.MaxConcurrent
	}
	if o.RequestsPerMinute != nil {
		l.RequestsPerMinute = *o.RequestsPerMinute
	}
	if o.Burst != nil {
		l.Burst = *o.Burst
	}
	return l
}

// Validate checks the default and every override's effective limits
func (c *Config) Validate() error {
	if err := c.Default.validate(); err != nil {
		return fmt.Errorf("rateLimits.default: %w", err)
	}
	for account := range c.Overrides {
		if err := c.For(account).validate(); err != nil {
			return fmt.Errorf("rateLimits.overrides[%s]: %w", account, err)
		}
	}
	return nil
}

func (l Limits) validate() error {
	if l.MaxConcurrent < 0 || l.RequestsPerMinute < 0 || l.Burst < 0 {
		return errors.New("negative values are not allowed")
	}
	if l.RequestsPerMinute > 0 && l.Burst == 0 {
		return errors.New("burst must be > 0 when requestsPerMinute is set")
	}
	return nil
}
