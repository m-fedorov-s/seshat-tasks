package main

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
	"gopkg.in/yaml.v3"
)

type Config struct {
	// AdminToken authenticates /api/admin/* only. At least 32 characters: a human does
	// not type 32 random characters by accident (README: openssl rand -hex 32).
	AdminToken string `yaml:"admin_token"`
	// AdminTokenFile names a file whose contents are the admin token, with surrounding
	// whitespace trimmed. Mutually exclusive with AdminToken.
	AdminTokenFile string `yaml:"admin_token_file"`
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

// The built-in defaults. A default port is needed because port 0 is legal to the kernel:
// without one, a start that sets no port binds an ephemeral port with no diagnostic.
const (
	defaultBind     = "127.0.0.1"
	defaultPort     = 8799
	defaultDataFile = "seshat.db"
)

// minAdminTokenLen is the minimum accepted length for the admin token: a human does not
// type 32 random characters by accident, so anything shorter is almost certainly a typo
// or a placeholder left over from copying an example config.
const minAdminTokenLen = 32

// version is the release tag, stamped with -ldflags "-X main.version=v0.1.0": Go's own
// VCS stamp carries the revision, never the tag. "dev" means unstamped.
var version = "dev"

// versionString is what -version prints and what the startup log line reports.
func versionString() string {
	// The linker silently accepts `-X main.version=` with an empty value (a build arg
	// forwarding an unset shell variable); treat that like an unstamped build.
	if version != "" && version != "dev" {
		return version
	}
	return "dev (" + buildRevision() + ")"
}

// provenance maps a config key to where its effective value came from: the config file's
// path or a SESHAT_* variable name. An absent key took the built-in default.
type provenance map[string]string

func (p provenance) recordFile(cfg Config, path string) {
	for key, set := range map[string]bool{
		"bind":             cfg.Bind != "",
		"port":             cfg.Port != 0,
		"data_file":        cfg.DataFile != "",
		"rate_limit":       cfg.RateLimit != 0,
		"admin_token":      cfg.AdminToken != "",
		"admin_token_file": cfg.AdminTokenFile != "",
	} {
		if set {
			p[key] = path
		}
	}
}

// configLines leaves the admin token out by design: main logs only its source.
func configLines(cfg Config, from provenance) []string {
	src := func(key string) string {
		if from[key] == "" {
			return "default"
		}
		return from[key]
	}
	return []string{
		fmt.Sprintf("config bind=%s (%s)", cfg.Bind, src("bind")),
		fmt.Sprintf("config port=%d (%s)", cfg.Port, src("port")),
		fmt.Sprintf("config data_file=%s (%s)", cfg.DataFile, src("data_file")),
		fmt.Sprintf("config rate_limit=%d (%s)", cfg.RateLimit, src("rate_limit")),
	}
}

// tooPermissive reports whether a file mode grants any access to group or other.
func tooPermissive(mode os.FileMode) bool { return mode.Perm()&0o077 != 0 }

// warnIfPermissive warns (does not refuse) on a group/world-readable file holding the admin
// token. Refusing to start over a permission bit is hostile for a single-operator server.
func warnIfPermissive(path string) {
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	if tooPermissive(info.Mode()) {
		log.Printf("WARNING: %s has mode %#o and holds the admin token; run: chmod 600 %s",
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

// loadConfigFile reads and parses the config file. Only a missing file at the default path
// is tolerated (found=false): an env-only deployment has no config to mount, but a typo'd
// -config or an unreadable file must never degrade into an all-defaults start.
func loadConfigFile(path string, explicit bool) (cfg Config, found bool, err error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) && !explicit {
		return Config{}, false, nil
	}
	if err != nil {
		return Config{}, false, err
	}
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return Config{}, false, err
	}
	return cfg, true, nil
}

// applyEnv overlays SESHAT_* onto cfg (env > file > default) and records each override in
// from. An unset or empty variable changes nothing.
func applyEnv(cfg *Config, getenv func(string) string, from provenance) error {
	if v := getenv("SESHAT_BIND"); v != "" {
		cfg.Bind, from["bind"] = v, "SESHAT_BIND"
	}
	if v := getenv("SESHAT_PORT"); v != "" {
		n, err := strconv.ParseUint(v, 10, 16)
		if err != nil {
			return fmt.Errorf("SESHAT_PORT=%q: want a port number 0-65535", v)
		}
		cfg.Port, from["port"] = uint(n), "SESHAT_PORT"
	}
	if v := getenv("SESHAT_DATA_FILE"); v != "" {
		cfg.DataFile, from["data_file"] = v, "SESHAT_DATA_FILE"
	}
	if v := getenv("SESHAT_RATE_LIMIT"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return fmt.Errorf("SESHAT_RATE_LIMIT=%q: want an integer", v)
		}
		// 0 still means "default"; a negative is validateConfig's to reject.
		cfg.RateLimit, from["rate_limit"] = n, "SESHAT_RATE_LIMIT"
	}
	// One credential slot: an env credential replaces both file fields. Within the env
	// layer the file form wins, because image, compose file and shell can each set one.
	file, plain := getenv("SESHAT_ADMIN_TOKEN_FILE"), strings.TrimSpace(getenv("SESHAT_ADMIN_TOKEN"))
	switch {
	case file != "":
		if plain != "" {
			log.Print("WARNING: SESHAT_ADMIN_TOKEN ignored because SESHAT_ADMIN_TOKEN_FILE is set")
		}
		cfg.AdminToken, cfg.AdminTokenFile = "", file
		from["admin_token_file"] = "SESHAT_ADMIN_TOKEN_FILE"
	case plain != "":
		log.Print("WARNING: SESHAT_ADMIN_TOKEN puts the admin token in the process environment, " +
			"readable through docker inspect, systemctl show and /proc; prefer SESHAT_ADMIN_TOKEN_FILE")
		cfg.AdminToken, cfg.AdminTokenFile = plain, ""
		from["admin_token"] = "SESHAT_ADMIN_TOKEN"
	}
	return nil
}

// resolveAdminToken collapses the two credential sources into cfg.AdminToken, so everything
// downstream sees one string. It returns the credential's source for the startup log.
func resolveAdminToken(cfg *Config, from provenance) (string, error) {
	if cfg.AdminTokenFile == "" {
		if cfg.AdminToken != "" {
			return from["admin_token"], nil
		}
		return "", nil
	}
	if cfg.AdminToken != "" {
		return "", errors.New("admin_token and admin_token_file are both set; set exactly one")
	}
	raw, err := os.ReadFile(cfg.AdminTokenFile)
	if err != nil {
		// Not the path: a token pasted where its path belongs must not reach the log.
		return "", fmt.Errorf("admin_token_file from %s: %w", from["admin_token_file"], errors.Unwrap(err))
	}
	// `openssl rand -hex 32 > f` leaves a newline; a token with a trailing \n fails the
	// constant-time compare and the only symptom is a 403 on every admin request.
	tok := strings.TrimSpace(string(raw))
	if tok == "" {
		return "", fmt.Errorf("admin_token_file %s is empty", cfg.AdminTokenFile)
	}
	cfg.AdminToken = tok
	return from["admin_token_file"] + " (" + cfg.AdminTokenFile + ")", nil
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
