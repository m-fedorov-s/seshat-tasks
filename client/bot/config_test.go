package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseUTCOffset(t *testing.T) {
	cases := []struct {
		in      string
		want    int
		wantErr bool
	}{
		{"+00:00", 0, false},
		{"+03:00", 180, false},
		{"-05:30", -330, false},
		{"+14:00", 840, false},
		{"-14:00", -840, false},
		{"+14:01", 0, true},  // out of range
		{"+15:00", 0, true},  // out of range
		{"03:00", 0, true},   // no sign
		{"+3:00", 0, true},   // not zero-padded
		{"+03:60", 0, true},  // minutes out of range
		{"", 0, true},        // empty
		{"+03:00 ", 0, true}, // trailing space, strict parse
		{"++3:00", 0, true},  // Atoi would strip the second sign
		{"+-3:00", 0, true},
	}
	for _, c := range cases {
		got, err := parseUTCOffset(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("parseUTCOffset(%q): want error, got %d", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseUTCOffset(%q): unexpected error %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseUTCOffset(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "bot.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadConfigValid(t *testing.T) {
	p := writeConfig(t, `{
		"bot_token": "123:ABC",
		"server_url": "http://127.0.0.1:8080",
		"utc_offset": "+03:00",
		"users": {"42": "sekrit"}
	}`)
	cfg, err := LoadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.OffsetMinutes() != 180 {
		t.Errorf("OffsetMinutes = %d, want 180", cfg.OffsetMinutes())
	}
	tok, ok := cfg.TokenFor(42)
	if !ok || tok != "sekrit" {
		t.Errorf("TokenFor(42) = %q,%v; want sekrit,true", tok, ok)
	}
	if _, ok := cfg.TokenFor(43); ok {
		t.Error("TokenFor(43) should not resolve")
	}
}

func TestLoadConfigDefaultsOffset(t *testing.T) {
	p := writeConfig(t, `{"bot_token":"t","server_url":"http://x","users":{"1":"s"}}`)
	cfg, err := LoadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.OffsetMinutes() != 0 {
		t.Errorf("absent utc_offset should default to 0, got %d", cfg.OffsetMinutes())
	}
}

func TestLoadConfigRefusals(t *testing.T) {
	cases := map[string]string{
		"empty bot_token":  `{"bot_token":"","server_url":"http://x","users":{"1":"s"}}`,
		"empty server_url": `{"bot_token":"t","server_url":"","users":{"1":"s"}}`,
		"empty users":      `{"bot_token":"t","server_url":"http://x","users":{}}`,
		"absent users":     `{"bot_token":"t","server_url":"http://x"}`,
		"bad offset":       `{"bot_token":"t","server_url":"http://x","utc_offset":"nope","users":{"1":"s"}}`,
		"non-numeric id":   `{"bot_token":"t","server_url":"http://x","users":{"abc":"s"}}`,
		"empty token":      `{"bot_token":"t","server_url":"http://x","users":{"1":""}}`,
		"malformed json":   `{`,
	}
	for name, body := range cases {
		if _, err := LoadConfig(writeConfig(t, body)); err == nil {
			t.Errorf("%s: expected refusal, got nil error", name)
		}
	}
}
