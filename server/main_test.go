package main

import (
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
