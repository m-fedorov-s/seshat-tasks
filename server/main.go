package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"time"

	bolt "go.etcd.io/bbolt"
	"gopkg.in/yaml.v3"
)

type Config struct {
	Secret string `yaml:"secret"`
	// Bind is the listen address. Defaults to loopback: the process sits behind a
	// TLS-terminating reverse proxy, and listening on all interfaces would let the
	// proxy be bypassed by hitting the port directly. A field rather than a constant
	// because deployment environments differ.
	Bind     string `yaml:"bind"`
	Port     uint   `yaml:"port"`
	DataFile string `yaml:"data_file"`
	// RateLimit is the requests-per-second ceiling. 0 means use defaultRateLimit.
	// Burst is derived as twice this value (see NewServer).
	RateLimit int `yaml:"rate_limit"`
}

const defaultBind = "127.0.0.1"

// tooPermissive reports whether a file mode grants any access to group or other.
// The config holds the shared secret in plaintext.
func tooPermissive(mode os.FileMode) bool { return mode.Perm()&0o077 != 0 }

// warnIfPermissive warns (does not refuse) on a group/world-readable config.
// Refusing to start over a permission bit is hostile for a single-operator server.
func warnIfPermissive(path string) {
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	if tooPermissive(info.Mode()) {
		log.Printf("WARNING: config %s has mode %#o and contains the shared secret; run: chmod 600 %s",
			path, info.Mode().Perm(), path)
	}
}

// buildRevision reads the VCS revision that Go stamps into any binary built inside
// a git checkout (Go 1.18+). No -ldflags plumbing required.
func buildRevision() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	rev, dirty := "unknown", false
	for _, s := range info.Settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value
		case "vcs.modified":
			dirty = s.Value == "true"
		}
	}
	if dirty {
		return rev + "-dirty"
	}
	return rev
}

// resolveRateLimit applies the requests-per-second default (0 -> defaultRateLimit)
// and rejects negative values. Pulled out of main as a pure function so the
// defaulting/validation logic is unit-testable without spinning up a server.
func resolveRateLimit(configured int) (int, error) {
	if configured == 0 {
		return defaultRateLimit, nil
	}
	if configured < 0 {
		return 0, fmt.Errorf("config rate_limit must be positive, got %d", configured)
	}
	return configured, nil
}

// validateConfig checks a loaded Config for fatal problems and resolves the rate-limit
// default, returning the resolved requests-per-second ceiling. Pulled out of main as a
// pure function (same pattern as resolveRateLimit) so it's unit-testable without
// spinning up a server.
//
// Note: a whitespace-only secret (e.g. " ") is currently ACCEPTED — only the exact
// empty string is rejected. That's a conscious, reviewed gap, not an oversight: pin it
// with a test rather than "fixing" it here.
func validateConfig(cfg Config) (int, error) {
	// An empty secret authenticates every request that omits the Authorization header,
	// because sha256("") == sha256(""). Refuse to start rather than serve wide open.
	// This is the one place refusing (rather than warning) is correct: a warning here
	// would scroll past while the server ran unauthenticated.
	if cfg.Secret == "" {
		return 0, fmt.Errorf("empty secret; refusing to start (every request would authenticate)")
	}
	return resolveRateLimit(cfg.RateLimit)
}

func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	flag.Parse()

	raw, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		log.Fatal(err)
	}
	if cfg.DataFile == "" {
		cfg.DataFile = "seshat-data.json"
	}
	if cfg.Bind == "" {
		cfg.Bind = defaultBind
	}
	// Runs before the fatal validation below so an operator with both a bad secret and a
	// too-permissive config file sees both problems in one pass, not one fix-and-retry
	// cycle per issue.
	warnIfPermissive(*configPath)
	rateLimit, err := validateConfig(cfg)
	if err != nil {
		log.Fatalf("config %s: %v", *configPath, err)
	}
	cfg.RateLimit = rateLimit

	tenants, err := OpenTenants(cfg.DataFile, cfg.RateLimit)
	if errors.Is(err, bolt.ErrInvalid) {
		log.Fatalf("%s is not a bbolt file — Stage 2 changed the storage format; "+
			"load your tasks into a fresh file with test/seed", cfg.DataFile)
	}
	if err != nil {
		log.Fatalf("open data file: %v", err)
	}
	// No defer tenants.Close(): every exit below is log.Fatal -> os.Exit, which
	// skips defers anyway. bbolt commits are durable, so nothing acknowledged is lost.
	store, err := tenants.bootstrapSingle()
	if err != nil {
		log.Fatalf("bootstrap: %v", err)
	}
	srv := NewServer(store, cfg.Secret, cfg.RateLimit)

	addr := fmt.Sprintf("%s:%d", cfg.Bind, cfg.Port)
	// Go's zero-value http.Server has NO deadlines: a connection that opens and
	// sends nothing holds a goroutine and an fd until TCP keepalive gives up.
	hs := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("seshat server listening on %s, data=%s, rev=%s", addr, cfg.DataFile, buildRevision())
	if err := hs.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
