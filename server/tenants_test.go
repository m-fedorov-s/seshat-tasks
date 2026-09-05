package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

// openTestTenants opens a Tenants over a fresh temp file, registering a cleanup
// that closes it so every test releases its bbolt flock even on failure.
func openTestTenants(t *testing.T) *Tenants {
	t.Helper()
	path := filepath.Join(t.TempDir(), "seshat.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	t.Cleanup(func() { tn.Close() })
	return tn
}

// reopenRaw opens the file directly with bbolt, outside of Tenants, so a test can
// corrupt its buckets. The explicit Timeout turns a missed Close() in some other
// test into a 1s failure instead of a 10-minute hang (bolt's DefaultOptions.Timeout
// is 0, meaning wait forever).
func reopenRaw(t *testing.T, path string) *bolt.DB {
	t.Helper()
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("reopenRaw: %v", err)
	}
	return db
}

func TestOpenFreshFileCreatesBucketsAndVersion(t *testing.T) {
	tn := openTestTenants(t)

	err := tn.db.View(func(tx *bolt.Tx) error {
		for _, name := range []string{bucketMeta, bucketUsers, bucketData} {
			if tx.Bucket([]byte(name)) == nil {
				t.Fatalf("bucket %q missing", name)
			}
		}
		raw := tx.Bucket([]byte(bucketMeta)).Get([]byte(keyFormatVersion))
		if raw == nil {
			t.Fatalf("format_version missing")
		}
		if got := fromBE64(raw); got != CurrentDataFormatVersion {
			t.Fatalf("format_version = %d, want %d", got, CurrentDataFormatVersion)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("View: %v", err)
	}

	info, err := os.Stat(tn.db.Path())
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("file perm = %o, want 0600", perm)
	}
}

func TestOpenRefusesMissingFormatVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketMeta)).Delete([]byte(keyFormatVersion))
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "format_version") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning format_version", err)
	}

	// The failed open must have released the flock: a following open must not time out.
	tn2 := reopenRaw(t, path)
	if err := tn2.Close(); err != nil {
		t.Fatalf("tn2.Close: %v", err)
	}
}

func TestOpenRefusesNewerFormatVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketMeta)).Put([]byte(keyFormatVersion), be64(CurrentDataFormatVersion+1))
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "upgrade seshat") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning \"upgrade seshat\"", err)
	}
}

func TestSecondOpenOfSamePathTimesOut(t *testing.T) {
	// Costs ~1s on every run of the package. Deliberate: it is the only test that
	// pins the Timeout option, and without that option a second open blocks forever.
	tn := openTestTenants(t)

	start := time.Now()
	_, err := OpenTenants(tn.db.Path(), defaultRateLimit)
	elapsed := time.Since(start)

	if !errors.Is(err, bolt.ErrTimeout) {
		t.Fatalf("second open: want bolt.ErrTimeout, got %v", err)
	}
	// bbolt bails ~50ms early (flockRetryTimeout), so the bound is loose on both
	// sides. The point is that the Timeout option is set at all.
	if elapsed < 500*time.Millisecond || elapsed > 5*time.Second {
		t.Fatalf("second open took %v; want the 1s Timeout option to bound it", elapsed)
	}
}
