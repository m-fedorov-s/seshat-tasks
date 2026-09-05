package main

import (
	"encoding/binary"
	"fmt"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
	"golang.org/x/time/rate"
)

// Bucket names and the meta key holding the on-disk format generation. One bbolt
// file holds one blob per user: "meta" carries file-wide bookkeeping (currently
// just format_version), "users" maps a token hash to a user record, "data" holds
// each user's serialized Store state.
const (
	bucketMeta       = "meta"
	bucketUsers      = "users"
	bucketData       = "data"
	keyFormatVersion = "format_version"
)

// openTimeout: bbolt holds an exclusive flock on the data file. Without a timeout
// a second opener (another process, or this process opening the same path twice)
// hangs forever.
const openTimeout = 1 * time.Second

// UserID keys the data bucket. Bare for now; Task 3 adds hex text encoding and helpers.
type UserID [16]byte

// tenant is one registered user as held in memory. Declared in full now; Task 3
// populates it.
type tenant struct {
	id      UserID
	hash    [32]byte // key in the users bucket; needed by Delete
	store   *Store
	limiter *rate.Limiter
}

// Tenants owns the single bbolt file backing every user's tasks.
type Tenants struct {
	db     *bolt.DB
	rps    int
	mu     sync.RWMutex
	byHash map[[32]byte]*tenant
	byID   map[UserID]*tenant
}

// OpenTenants opens (creating if absent) the bbolt data file at path, laying out
// its buckets and validating its format_version.
func OpenTenants(path string, rps int) (*Tenants, error) {
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: openTimeout})
	if err != nil {
		return nil, fmt.Errorf("open data file %s: %w", path, err)
	}

	t := &Tenants{
		db:     db,
		rps:    rps,
		byHash: map[[32]byte]*tenant{},
		byID:   map[UserID]*tenant{},
	}

	if err := t.init(); err != nil {
		db.Close()      // the ONE close for every init-time failure: a leaked handle
		return nil, err // keeps the flock and poisons the path for later opens
	}

	return t, nil
}

// init creates the bucket layout on a fresh file and validates it on an existing
// one. Task 3 appends a call to load every registered user at the end.
func (t *Tenants) init() error {
	return t.db.Update(func(tx *bolt.Tx) error {
		meta := tx.Bucket([]byte(bucketMeta))
		if meta == nil {
			// Fresh file. bbolt's Open has already written its own pages, so
			// "meta absent" — not "file absent" — is the fresh-file test (spec
			// §5.2).
			var err error
			meta, err = tx.CreateBucket([]byte(bucketMeta))
			if err != nil {
				return err
			}
			if _, err := tx.CreateBucket([]byte(bucketUsers)); err != nil {
				return err
			}
			if _, err := tx.CreateBucket([]byte(bucketData)); err != nil {
				return err
			}
			return meta.Put([]byte(keyFormatVersion), be64(CurrentDataFormatVersion))
		}

		raw := meta.Get([]byte(keyFormatVersion))
		if raw == nil || len(raw) != 8 {
			return fmt.Errorf("data file %s: meta bucket has no format_version (corrupt)", t.db.Path())
		}
		v := fromBE64(raw)
		if v > CurrentDataFormatVersion {
			return fmt.Errorf(
				"data file %s has data_format_version %d, but this binary supports at most %d — upgrade seshat",
				t.db.Path(), v, CurrentDataFormatVersion)
		}

		// users/data must exist whenever meta does; create-if-missing is
		// harmless (idempotent, preserves contents) and keeps a file written by
		// a crashed first run loadable.
		if _, err := tx.CreateBucketIfNotExists([]byte(bucketUsers)); err != nil {
			return err
		}
		if _, err := tx.CreateBucketIfNotExists([]byte(bucketData)); err != nil {
			return err
		}
		return nil
	})
}

// Close releases the underlying bbolt file and its flock.
func (t *Tenants) Close() error {
	return t.db.Close()
}

// be64 encodes v as 8 bytes, big-endian — bbolt orders keys/values byte-wise, so
// big-endian keeps any future range scan over these values in numeric order.
func be64(v uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v)
	return b
}

// fromBE64 decodes 8 big-endian bytes produced by be64.
func fromBE64(b []byte) uint64 {
	return binary.BigEndian.Uint64(b)
}
