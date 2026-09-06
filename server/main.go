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
	// AdminToken authenticates /api/admin/* only. At least 32 characters: a human does
	// not type 32 random characters by accident (README: openssl rand -hex 32).
	AdminToken string `yaml:"admin_token"`
	// Bind is the listen address. Defaults to loopback: the process sits behind a
	// TLS-terminating reverse proxy, and listening on all interfaces would let the
	// proxy be bypassed by hitting the port directly. A field rather than a constant
	// because deployment environments differ.
	Bind string `yaml:"bind"`
	Port uint   `yaml:"port"`
	// DataFile is a bbolt file; defaults to seshat.db.
	DataFile string `yaml:"data_file"`
	// RateLimit is the requests-per-second ceiling, per user, and for the admin branch.
	// 0 means use defaultRateLimit. Burst is derived as twice this value (see NewServer).
	RateLimit int `yaml:"rate_limit"`
}

const defaultBind = "127.0.0.1"

// minAdminTokenLen is the minimum accepted length for the admin token: a human does not
// type 32 random characters by accident, so anything shorter is almost certainly a typo
// or a placeholder left over from copying an example config.
const minAdminTokenLen = 32

// tooPermissive reports whether a file mode grants any access to group or other.
// The config holds the admin token in plaintext.
func tooPermissive(mode os.FileMode) bool { return mode.Perm()&0o077 != 0 }

// warnIfPermissive warns (does not refuse) on a group/world-readable config.
// Refusing to start over a permission bit is hostile for a single-operator server.
func warnIfPermissive(path string) {
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	if tooPermissive(info.Mode()) {
		log.Printf("WARNING: config %s has mode %#o and contains the admin token; run: chmod 600 %s",
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
func validateConfig(cfg Config) (int, error) {
	// An empty token would authenticate an empty Authorization header on the admin
	// branch (sha256("") == sha256("")). Refuse, don't warn — same reasoning as Stage 0.
	if cfg.AdminToken == "" {
		return 0, errors.New(`admin_token required; refusing to start (configs written before Stage 2 used "secret" — see README)`)
	}
	if len(cfg.AdminToken) < minAdminTokenLen {
		return 0, fmt.Errorf("admin_token must be at least %d characters, got %d; refusing to start", minAdminTokenLen, len(cfg.AdminToken))
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
		cfg.DataFile = "seshat.db"
	}
	if cfg.Bind == "" {
		cfg.Bind = defaultBind
	}
	// Runs before the fatal validation below so an operator with both a bad admin token
	// and a too-permissive config file sees both problems in one pass, not one
	// fix-and-retry cycle per issue.
	warnIfPermissive(*configPath)
	rateLimit, err := validateConfig(cfg)
	if err != nil {
		log.Fatalf("config %s: %v", *configPath, err)
	}
	cfg.RateLimit = rateLimit

	tenants, err := OpenTenants(cfg.DataFile, cfg.RateLimit)
	if errors.Is(err, bolt.ErrInvalid) {
		log.Fatalf("%s is not a bbolt file — Stage 2 changed the storage format. Start with a "+
			"fresh data_file, create a user with POST /api/admin/users/add, then load your old "+
			"tasks with: go run ./test/seed -token <that token> <old.json>", cfg.DataFile)
	}
	if err != nil {
		log.Fatalf("open data file: %v", err)
	}
	// No defer tenants.Close(): every exit below is log.Fatal -> os.Exit, which
	// skips defers anyway. bbolt commits are durable, so nothing acknowledged is lost.
	srv := NewServer(tenants, cfg.AdminToken, cfg.RateLimit)

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
	log.Printf("seshat server listening on %s, data=%s, users=%d, rev=%s", addr, cfg.DataFile, len(tenants.List()), buildRevision())
	if err := hs.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
