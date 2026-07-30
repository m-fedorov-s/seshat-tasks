package main

import (
	"os"
	"testing"
)

func TestTooPermissive(t *testing.T) {
	cases := []struct {
		mode os.FileMode
		want bool
	}{
		{0o600, false}, // owner rw only — correct
		{0o400, false}, // owner r only — correct
		{0o640, true},  // group readable
		{0o604, true},  // world readable
		{0o644, true},  // the common accidental default
		{0o666, true},
		{0o700, false}, // owner-only, execute bit is irrelevant here
	}
	for _, c := range cases {
		if got := tooPermissive(c.mode); got != c.want {
			t.Errorf("tooPermissive(%#o) = %v, want %v", c.mode, got, c.want)
		}
	}
}

func TestValidateConfig(t *testing.T) {
	cases := []struct {
		name      string
		cfg       Config
		wantErr   bool
		wantLimit int
	}{
		{"empty secret rejected", Config{Secret: "", RateLimit: 0}, true, 0},
		// Consciously deferred, not a bug: only the exact empty string is rejected.
		// Pin the current behavior rather than change it.
		{"whitespace-only secret currently accepted", Config{Secret: "   ", RateLimit: 0}, false, defaultRateLimit},
		{"valid config accepted", Config{Secret: "s3cr3t", RateLimit: 0}, false, defaultRateLimit},
		{"rate limit zero defaults", Config{Secret: "s3cr3t", RateLimit: 0}, false, defaultRateLimit},
		{"positive rate limit passes through", Config{Secret: "s3cr3t", RateLimit: 25}, false, 25},
		{"negative rate limit rejected", Config{Secret: "s3cr3t", RateLimit: -1}, true, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := validateConfig(c.cfg)
			if c.wantErr {
				if err == nil {
					t.Fatalf("validateConfig(%+v) err = nil, want error", c.cfg)
				}
				return
			}
			if err != nil {
				t.Fatalf("validateConfig(%+v) unexpected err: %v", c.cfg, err)
			}
			if got != c.wantLimit {
				t.Fatalf("validateConfig(%+v) = %d, want %d", c.cfg, got, c.wantLimit)
			}
		})
	}
}

func TestResolveRateLimit(t *testing.T) {
	cases := []struct {
		name       string
		configured int
		want       int
		wantErr    bool
	}{
		{"zero defaults", 0, defaultRateLimit, false},
		{"positive passes through", 25, 25, false},
		{"negative errors", -1, 0, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := resolveRateLimit(c.configured)
			if c.wantErr {
				if err == nil {
					t.Errorf("resolveRateLimit(%d) err = nil, want error", c.configured)
				}
				return
			}
			if err != nil {
				t.Errorf("resolveRateLimit(%d) unexpected err: %v", c.configured, err)
			}
			if got != c.want {
				t.Errorf("resolveRateLimit(%d) = %d, want %d", c.configured, got, c.want)
			}
		})
	}
}
