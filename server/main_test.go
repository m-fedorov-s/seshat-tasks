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
