package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
)

// Config is the bot's on-disk configuration. JSON rather than the server's YAML,
// matching the Zig client — this is a client.
type Config struct {
	BotToken  string `json:"bot_token"`
	ServerURL string `json:"server_url"`
	// UTCOffset is "+HH:MM"/"-HH:MM", range ±14:00. Same semantics as the Zig
	// client: applied at exactly two boundaries, rendering a date and computing
	// a due date. Absent means "+00:00".
	UTCOffset string `json:"utc_offset"`
	// Users maps a Telegram user id (as a JSON object key, hence string) to that
	// user's seshat token. A map from day one even though every value is the same
	// shared secret today, so Stage 2 (multi-user) is a config edit, not a code
	// change.
	Users map[string]string `json:"users"`

	offsetMinutes int
	users         map[int64]string
}

func (c *Config) OffsetMinutes() int { return c.offsetMinutes }

func (c *Config) TokenFor(userID int64) (string, bool) {
	tok, ok := c.users[userID]
	return tok, ok
}

// parseUTCOffset parses "+HH:MM"/"-HH:MM" strictly into minutes east of UTC.
// Strict: exactly 6 bytes, explicit sign, zero-padded. A lenient parse here would
// silently misplace every rendered date by hours.
func parseUTCOffset(s string) (int, error) {
	if len(s) != 6 || (s[0] != '+' && s[0] != '-') || s[3] != ':' {
		return 0, fmt.Errorf("utc_offset %q: want +HH:MM or -HH:MM", s)
	}
	// strconv.Atoi would happily strip a second sign, so "++3:00" must be caught
	// here rather than parsing as +03:00.
	for _, i := range []int{1, 2, 4, 5} {
		if s[i] < '0' || s[i] > '9' {
			return 0, fmt.Errorf("utc_offset %q: non-digit", s)
		}
	}
	hh, err := strconv.Atoi(s[1:3])
	if err != nil {
		return 0, fmt.Errorf("utc_offset %q: bad hours", s)
	}
	mm, err := strconv.Atoi(s[4:6])
	if err != nil {
		return 0, fmt.Errorf("utc_offset %q: bad minutes", s)
	}
	if mm > 59 {
		return 0, fmt.Errorf("utc_offset %q: minutes out of range", s)
	}
	total := hh*60 + mm
	if s[0] == '-' {
		total = -total
	}
	if total < -840 || total > 840 {
		return 0, fmt.Errorf("utc_offset %q: out of ±14:00", s)
	}
	return total, nil
}

// DefaultConfigPath is used when SESHAT_BOT_CONFIG is unset.
func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "bot.json"
	}
	return filepath.Join(home, ".config", "seshat", "bot.json")
}

// tooPermissive reports whether a file mode grants any access to group or other.
func tooPermissive(mode os.FileMode) bool { return mode.Perm()&0o077 != 0 }

// warnIfPermissive warns (does not refuse) on a group/world-readable config. It
// holds two classes of secret: the bot token and every seshat token. Refusing to
// start over a permission bit is hostile for a single-operator deployment; the
// same split the server makes in main.go.
func warnIfPermissive(path string) {
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	if tooPermissive(info.Mode()) {
		log.Printf("WARNING: config %s has mode %#o and contains the bot token and seshat tokens; run: chmod 600 %s",
			path, info.Mode().Perm(), path)
	}
}

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	warnIfPermissive(path)

	// Refuse, do not warn: each of these would otherwise leave the bot running in
	// a state where it either cannot work or authenticates nobody usefully.
	if c.BotToken == "" {
		return nil, fmt.Errorf("config %s: empty bot_token", path)
	}
	if c.ServerURL == "" {
		return nil, fmt.Errorf("config %s: empty server_url", path)
	}
	if len(c.Users) == 0 {
		return nil, fmt.Errorf("config %s: empty users map; the bot would answer nobody", path)
	}
	if c.UTCOffset == "" {
		c.UTCOffset = "+00:00"
	}
	off, err := parseUTCOffset(c.UTCOffset)
	if err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	c.offsetMinutes = off

	c.users = make(map[int64]string, len(c.Users))
	for k, v := range c.Users {
		id, err := strconv.ParseInt(k, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("config %s: users key %q is not a Telegram user id", path, k)
		}
		if v == "" {
			return nil, fmt.Errorf("config %s: empty token for user %s", path, k)
		}
		c.users[id] = v
	}
	return &c, nil
}
