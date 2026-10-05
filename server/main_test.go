package main

import (
	"bytes"
	"log"
	"maps"
	"os"
	"path/filepath"
	"strings"
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
	ok32 := strings.Repeat("a", 32)
	cases := []struct {
		name      string
		cfg       Config
		wantErr   bool
		wantMsg   string
		wantLimit int
	}{
		{"missing admin_token", Config{AdminToken: ""}, true, "admin_token required", 0},
		{"short admin_token", Config{AdminToken: strings.Repeat("a", 31)}, true, "at least 32", 0},
		{"32-char admin_token ok", Config{AdminToken: ok32}, false, "", defaultRateLimit},
		{"rate limit zero defaults", Config{AdminToken: ok32, RateLimit: 0}, false, "", defaultRateLimit},
		{"positive rate limit", Config{AdminToken: ok32, RateLimit: 25}, false, "", 25},
		{"negative rate limit", Config{AdminToken: ok32, RateLimit: -1}, true, "", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := validateConfig(c.cfg)
			if c.wantErr {
				if err == nil {
					t.Fatalf("validateConfig(%+v) err = nil, want error", c.cfg)
				}
				if c.wantMsg != "" && !strings.Contains(err.Error(), c.wantMsg) {
					t.Fatalf("validateConfig(%+v) err = %q, want substring %q", c.cfg, err.Error(), c.wantMsg)
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

func writeFile(t *testing.T, name, contents string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadConfigFileOptional(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "config.yaml")

	cfg, found, err := loadConfigFile(missing, false)
	if err != nil || found || cfg != (Config{}) {
		t.Fatalf("missing at the default path: got (%+v, %v, %v), want zero Config, found=false, nil", cfg, found, err)
	}
	if _, _, err := loadConfigFile(missing, true); err == nil {
		t.Fatal("missing at an explicit -config path: err = nil, want error")
	}

	if os.Geteuid() == 0 {
		t.Log("running as root; skipping the unreadable-file case")
	} else {
		unreadable := writeFile(t, "config.yaml", "bind: 0.0.0.0\n", 0o000)
		if _, found, err := loadConfigFile(unreadable, false); err == nil || found {
			t.Fatalf("unreadable at the default path: got (found=%v, err=%v), want an error — never an all-defaults start", found, err)
		}
	}

	present := writeFile(t, "config.yaml", "admin_token_file: /run/secrets/admin_token\nport: 9000\n", 0o600)
	cfg, found, err = loadConfigFile(present, false)
	if err != nil || !found {
		t.Fatalf("present: got (found=%v, err=%v), want found=true, nil", found, err)
	}
	if cfg.AdminTokenFile != "/run/secrets/admin_token" || cfg.Port != 9000 {
		t.Fatalf("present: parsed %+v, want AdminTokenFile=/run/secrets/admin_token Port=9000", cfg)
	}

	malformed := writeFile(t, "config.yaml", "bind: [\n", 0o600)
	if _, _, err := loadConfigFile(malformed, false); err == nil {
		t.Fatal("malformed YAML: err = nil, want error")
	}
}

func TestRecordFileAndConfigLines(t *testing.T) {
	path := "/etc/seshat/config.yaml"
	from := provenance{}
	from.recordFile(Config{Port: 9000, DataFile: "/var/lib/seshat/seshat.db", AdminToken: "x"}, path)
	if want := (provenance{"port": path, "data_file": path, "admin_token": path}); !maps.Equal(from, want) {
		t.Fatalf("recordFile = %v, want %v", from, want)
	}

	cfg := Config{Bind: "0.0.0.0", Port: 9000, DataFile: "/var/lib/seshat/seshat.db", RateLimit: 10, AdminToken: "never-logged"}
	from["bind"] = "SESHAT_BIND"
	got := configLines(cfg, from)
	want := []string{
		"config bind=0.0.0.0 (SESHAT_BIND)",
		"config port=9000 (/etc/seshat/config.yaml)",
		"config data_file=/var/lib/seshat/seshat.db (/etc/seshat/config.yaml)",
		"config rate_limit=10 (default)",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("configLines =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if strings.Contains(strings.Join(got, "\n"), "never-logged") {
		t.Fatal("configLines must not carry the admin token")
	}
}

func TestVersionString(t *testing.T) {
	prev := version
	t.Cleanup(func() { version = prev })

	for _, v := range []string{"dev", ""} {
		version = v
		if got := versionString(); !strings.HasPrefix(got, "dev (") {
			t.Errorf("version=%q: versionString() = %q, want \"dev (<revision>)\"", v, got)
		}
	}
	version = "v9.9.9"
	if got := versionString(); got != "v9.9.9" {
		t.Errorf("stamped: versionString() = %q, want the bare tag", got)
	}
}

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestApplyEnvPrecedence(t *testing.T) {
	file := Config{Bind: "127.0.0.1", Port: 8799, DataFile: "a.db", RateLimit: 10}
	cases := []struct {
		name string
		env  map[string]string
		want Config
	}{
		{"bind", map[string]string{"SESHAT_BIND": "0.0.0.0"}, Config{Bind: "0.0.0.0", Port: 8799, DataFile: "a.db", RateLimit: 10}},
		{"port", map[string]string{"SESHAT_PORT": "9000"}, Config{Bind: "127.0.0.1", Port: 9000, DataFile: "a.db", RateLimit: 10}},
		{"data_file", map[string]string{"SESHAT_DATA_FILE": "b.db"}, Config{Bind: "127.0.0.1", Port: 8799, DataFile: "b.db", RateLimit: 10}},
		{"rate_limit", map[string]string{"SESHAT_RATE_LIMIT": "50"}, Config{Bind: "127.0.0.1", Port: 8799, DataFile: "a.db", RateLimit: 50}},
		{"unset leaves the file value", map[string]string{}, file},
		{"empty leaves the file value", map[string]string{"SESHAT_BIND": "", "SESHAT_PORT": "", "SESHAT_DATA_FILE": "", "SESHAT_RATE_LIMIT": ""}, file},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg, from := file, provenance{}
			from.recordFile(file, "config.yaml")
			if err := applyEnv(&cfg, envOf(c.env), from); err != nil {
				t.Fatalf("applyEnv: %v", err)
			}
			if cfg != c.want {
				t.Fatalf("applyEnv(%v) = %+v, want %+v", c.env, cfg, c.want)
			}
			for key, got := range from {
				want := "config.yaml"
				if v := "SESHAT_" + strings.ToUpper(key); c.env[v] != "" {
					want = v
				}
				if got != want {
					t.Errorf("provenance[%q] = %q, want %q", key, got, want)
				}
			}
		})
	}
}

func TestApplyEnvNumericErrors(t *testing.T) {
	for _, c := range []struct{ key, value string }{
		{"SESHAT_PORT", "abc"},
		{"SESHAT_PORT", "70000"},
		{"SESHAT_RATE_LIMIT", "1O"},
	} {
		var cfg Config
		err := applyEnv(&cfg, envOf(map[string]string{c.key: c.value}), provenance{})
		if err == nil || !strings.Contains(err.Error(), c.key) {
			t.Errorf("%s=%s: err = %v, want an error naming the variable", c.key, c.value, err)
		}
	}
}

func TestApplyEnvAdminTokenSources(t *testing.T) {
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	cfg := Config{AdminToken: "from-file"}
	from := provenance{"admin_token": "config.yaml"}
	if err := applyEnv(&cfg, envOf(map[string]string{"SESHAT_ADMIN_TOKEN_FILE": "/run/secrets/t"}), from); err != nil {
		t.Fatal(err)
	}
	if cfg.AdminToken != "" || cfg.AdminTokenFile != "/run/secrets/t" {
		t.Fatalf("SESHAT_ADMIN_TOKEN_FILE must clear a file-supplied admin_token: got %+v", cfg)
	}
	if from["admin_token_file"] != "SESHAT_ADMIN_TOKEN_FILE" {
		t.Fatalf("provenance[admin_token_file] = %q, want SESHAT_ADMIN_TOKEN_FILE", from["admin_token_file"])
	}

	plain := "pl41n-t0ken-q7x"
	buf.Reset()
	cfg = Config{AdminTokenFile: "/etc/seshat/admin_token"}
	from = provenance{}
	if err := applyEnv(&cfg, envOf(map[string]string{"SESHAT_ADMIN_TOKEN": plain + "\n"}), from); err != nil {
		t.Fatal(err)
	}
	if cfg.AdminToken != plain || cfg.AdminTokenFile != "" {
		t.Fatalf("SESHAT_ADMIN_TOKEN must clear a file-supplied admin_token_file and be trimmed: got %+v", cfg)
	}
	if from["admin_token"] != "SESHAT_ADMIN_TOKEN" {
		t.Fatalf("provenance[admin_token] = %q, want SESHAT_ADMIN_TOKEN", from["admin_token"])
	}
	if out := buf.String(); !strings.Contains(out, "WARNING") || !strings.Contains(out, "prefer SESHAT_ADMIN_TOKEN_FILE") || strings.Contains(out, plain) {
		t.Fatalf("plain token: want a WARNING pointing at SESHAT_ADMIN_TOKEN_FILE and no value, got %q", out)
	}

	buf.Reset()
	cfg = Config{}
	if err := applyEnv(&cfg, envOf(map[string]string{"SESHAT_ADMIN_TOKEN": plain, "SESHAT_ADMIN_TOKEN_FILE": "/run/secrets/t"}), provenance{}); err != nil {
		t.Fatal(err)
	}
	if cfg.AdminToken != "" || cfg.AdminTokenFile != "/run/secrets/t" {
		t.Fatalf("both set: the file form must win, got %+v", cfg)
	}
	out := buf.String()
	if !strings.Contains(out, "WARNING") || !strings.Contains(out, "SESHAT_ADMIN_TOKEN ignored") || !strings.Contains(out, "SESHAT_ADMIN_TOKEN_FILE") {
		t.Fatalf("both set: want a WARNING naming both variables, got %q", out)
	}
	if strings.Contains(out, plain) {
		t.Fatalf("the token value leaked into the log: %q", out)
	}
}

func TestResolveAdminTokenFile(t *testing.T) {
	tok := strings.Repeat("b", 64)
	for _, c := range []struct{ name, contents string }{
		{"trailing newline", tok + "\n"},
		{"crlf", tok + "\r\n"},
		{"padded", "  " + tok + " \n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			path := writeFile(t, "admin_token", c.contents, 0o600)
			cfg := Config{AdminTokenFile: path}
			source, err := resolveAdminToken(&cfg, provenance{"admin_token_file": "config.yaml"})
			if err != nil {
				t.Fatal(err)
			}
			if cfg.AdminToken != tok {
				t.Fatalf("AdminToken = %q, want the trimmed token", cfg.AdminToken)
			}
			if want := "config.yaml (" + path + ")"; source != want {
				t.Fatalf("source = %q, want %q", source, want)
			}
		})
	}

	for _, contents := range []string{"", " \n\t"} {
		path := writeFile(t, "admin_token", contents, 0o600)
		cfg := Config{AdminTokenFile: path}
		if _, err := resolveAdminToken(&cfg, provenance{}); err == nil || !strings.Contains(err.Error(), path) {
			t.Fatalf("contents %q: err = %v, want an error naming %s", contents, err, path)
		}
	}

	// A token pasted where its path belongs: the error names the setting, not the "path".
	secret := "leaky-secret"
	cfg := Config{AdminTokenFile: filepath.Join(t.TempDir(), secret)}
	_, err := resolveAdminToken(&cfg, provenance{"admin_token_file": "SESHAT_ADMIN_TOKEN_FILE"})
	if err == nil || strings.Contains(err.Error(), secret) || !strings.Contains(err.Error(), "SESHAT_ADMIN_TOKEN_FILE") {
		t.Fatalf("missing file: err = %v, want an error naming SESHAT_ADMIN_TOKEN_FILE and not the path", err)
	}

	cfg = Config{AdminToken: secret, AdminTokenFile: writeFile(t, "admin_token", tok, 0o600)}
	if _, err := resolveAdminToken(&cfg, provenance{}); err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("both set: err = %v, want an error that does not carry the token", err)
	}

	cfg = Config{}
	if source, err := resolveAdminToken(&cfg, provenance{}); err != nil || source != "" || cfg.AdminToken != "" {
		t.Fatalf("neither set: got (%q, %v, %+v), want a no-op", source, err, cfg)
	}

	cfg = Config{AdminToken: tok}
	if source, err := resolveAdminToken(&cfg, provenance{"admin_token": "SESHAT_ADMIN_TOKEN"}); err != nil || source != "SESHAT_ADMIN_TOKEN" {
		t.Fatalf("inline token: got (%q, %v), want the recorded source", source, err)
	}
}
