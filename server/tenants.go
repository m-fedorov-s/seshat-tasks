package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sort"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
	"golang.org/x/time/rate"

	"seshat/internal/task"
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

// UserID keys the data bucket. Rendered and parsed as 32 lowercase hex chars.
type UserID [16]byte

// String renders the id as 32 lowercase hex characters.
func (id UserID) String() string { return hex.EncodeToString(id[:]) }

// IsZero reports the all-zero id, which is never minted and therefore doubles as
// the corruption sentinel for a user record.
func (id UserID) IsZero() bool { return id == UserID{} }

func (id UserID) MarshalText() ([]byte, error) { return []byte(id.String()), nil }

func (id *UserID) UnmarshalText(b []byte) error {
	v, err := parseUserID(string(b))
	if err != nil {
		return err
	}
	*id = v
	return nil
}

// parseUserID decodes the 32-hex-char form written by String.
func parseUserID(s string) (UserID, error) {
	raw, err := hex.DecodeString(s)
	if err != nil {
		return UserID{}, fmt.Errorf("malformed user id %q: %w", s, err)
	}
	if len(raw) != 16 {
		return UserID{}, fmt.Errorf("malformed user id %q: want 16 bytes, got %d", s, len(raw))
	}
	var id UserID
	copy(id[:], raw)
	return id, nil
}

// User is the value stored under a token hash in the users bucket.
//
// Every field must have a safe zero value: adding one later must load old records
// unchanged (spec §4.1). Unknown fields in a stored record are ignored on read
// (encoding/json default) — that is the forward-compatibility half.
type User struct {
	ID UserID `json:"id"`
}

// ErrUserNotFound wraps the task-domain sentinel on purpose, so a handler mapping
// ErrNotFound to 404 covers it unchanged. The text here is for logs and tests.
var ErrUserNotFound = fmt.Errorf("user not found: %w", ErrNotFound)

// tokenHash is what the users bucket is keyed by: the raw token never touches disk.
func tokenHash(token string) [32]byte { return sha256.Sum256([]byte(token)) }

// newLimiter builds a per-tenant limiter with the same numbers NewServer uses.
func newLimiter(rps int) *rate.Limiter { return rate.NewLimiter(rate.Limit(rps), 2*rps) }

// mintToken returns 32 random bytes as 64 hex characters.
func mintToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("mint token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// mintID returns a random non-zero UserID (zero is the corruption sentinel).
func mintID() (UserID, error) {
	for {
		var id UserID
		if _, err := rand.Read(id[:]); err != nil {
			return UserID{}, fmt.Errorf("mint user id: %w", err)
		}
		if !id.IsZero() {
			return id, nil
		}
	}
}

// tenant is one registered user as held in memory. Declared in full now; Task 3
// populates it.
type tenant struct {
	id      UserID
	hash    [32]byte // key in the users bucket; needed by Delete
	store   *Store
	limiter *rate.Limiter
}

// Tenants owns the single bbolt file backing every user's tasks.
//
// Lock order: the only two orders are Tenants.mu -> bbolt (Create, Delete) and
// Store.mu -> bbolt (saveState). Nothing takes Tenants.mu inside a bbolt
// transaction or inside a Store method, and load/rebuildIndex run before a Store
// is published — so there is no cycle.
//
// Known cost, not a bug: Create/Delete hold the write lock across a bbolt commit
// (two fdatasync), and Go's RWMutex blocks new readers while a writer waits, so a
// user create stalls in-flight Authenticate calls for the length of one commit.
// Acceptable at this scale.
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

	// bolt.Open's mode argument only applies on creation: an existing file that is
	// (or becomes) group/world-readable is silently accepted, unlike the old JSON
	// writer, which recreated the file 0600 on every save. This file now holds
	// every tenant's tasks, so warn (do not refuse, do not chmod) the same way
	// warnIfPermissive does for the config file.
	if info, err := os.Stat(path); err == nil && tooPermissive(info.Mode()) {
		log.Printf("WARNING: data file %s has mode %#o and holds every user's tasks; run: chmod 600 %s",
			path, info.Mode().Perm(), path)
	}

	return t, nil
}

// init creates the bucket layout on a fresh file and validates it on an existing
// one, then loads every registered user into memory.
func (t *Tenants) init() error {
	if err := t.db.Update(func(tx *bolt.Tx) error {
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
	}); err != nil {
		return err
	}
	return t.loadUsers()
}

// loadUsers rebuilds the in-memory registry from the file, refusing any shape the
// code could not have written. Called once, from init, before Tenants is published.
func (t *Tenants) loadUsers() error {
	seen := map[UserID]bool{}
	err := t.db.View(func(tx *bolt.Tx) error {
		users := tx.Bucket([]byte(bucketUsers))
		data := tx.Bucket([]byte(bucketData))
		if err := users.ForEach(func(k, v []byte) error {
			if len(k) != 32 {
				return fmt.Errorf("data file %s is corrupt: users key of length %d", t.db.Path(), len(k))
			}
			var u User
			if err := json.Unmarshal(v, &u); err != nil || u.ID.IsZero() {
				return fmt.Errorf("data file %s is corrupt: bad user record", t.db.Path())
			}
			if seen[u.ID] {
				return fmt.Errorf("data file %s is corrupt: two users share id %s", t.db.Path(), u.ID)
			}
			if data.Get(u.ID[:]) == nil {
				return fmt.Errorf("data file %s is corrupt: user %s has no data", t.db.Path(), u.ID)
			}
			tn := &tenant{id: u.ID, limiter: newLimiter(t.rps)}
			copy(tn.hash[:], k) // COPY: k is only valid for the tx's lifetime
			t.byHash[tn.hash] = tn
			t.byID[u.ID] = tn
			seen[u.ID] = true
			return nil
		}); err != nil {
			return err
		}
		return data.ForEach(func(k, _ []byte) error {
			if len(k) != 16 {
				return fmt.Errorf("data file %s is corrupt: data key of length %d", t.db.Path(), len(k))
			}
			var id UserID
			copy(id[:], k)
			if !seen[id] {
				return fmt.Errorf("data file %s is corrupt: data for unknown user %s", t.db.Path(), id)
			}
			return nil
		})
	})
	if err != nil {
		return err
	}
	// OUTSIDE the View: newStore opens its own View, and bbolt deadlocks on a
	// nested transaction. Keep every store opened outside any transaction.
	//
	// Eager rather than lazy: a corrupt blob fails boot loudly instead of 500ing
	// one user much later (spec §4.4).
	for id, tn := range t.byID {
		st, err := newStore(t.db, id)
		if err != nil {
			return fmt.Errorf("user %s: %w", id, err)
		}
		tn.store = st
	}
	return nil
}

// Create registers a new user and returns its freshly minted token, which is the
// only time the token exists in plaintext.
func (t *Tenants) Create() (string, UserID, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	// Mint until the id/token misses both indexes (a 2^-128 event; the guard is a
	// few lines). A mint ERROR must return, not spin — we hold t.mu here.
	var id UserID
	for {
		var err error
		id, err = mintID()
		if err != nil {
			return "", UserID{}, err
		}
		if _, taken := t.byID[id]; !taken {
			break
		}
	}
	var tok string
	var h [32]byte
	for {
		var err error
		tok, err = mintToken()
		if err != nil {
			return "", UserID{}, err
		}
		h = tokenHash(tok)
		if _, taken := t.byHash[h]; !taken {
			break
		}
	}
	empty, err := json.Marshal(userBlob{StateVersion: 0, Tasks: map[string]task.Task{}})
	if err != nil {
		return "", UserID{}, err
	}
	rec, err := json.Marshal(User{ID: id})
	if err != nil {
		return "", UserID{}, err
	}

	// One transaction for both entries: a crash between them would leave a
	// users-record-without-data that loadUsers refuses. Nothing is registered in
	// memory unless the transaction committed.
	if err := t.db.Update(func(tx *bolt.Tx) error {
		if err := tx.Bucket([]byte(bucketUsers)).Put(h[:], rec); err != nil {
			return err
		}
		return tx.Bucket([]byte(bucketData)).Put(id[:], empty)
	}); err != nil {
		return "", UserID{}, err
	}

	st := newEmptyStore(t.db, id) // no read-back: the blob just written IS this state
	tn := &tenant{id: id, hash: h, store: st, limiter: newLimiter(t.rps)}
	t.byHash[h] = tn
	t.byID[id] = tn
	return tok, id, nil
}

// Authenticate resolves a plaintext token to its tenant.
func (t *Tenants) Authenticate(token string) (*tenant, bool) {
	h := tokenHash(token)
	t.mu.RLock()
	defer t.mu.RUnlock()
	tn, ok := t.byHash[h]
	return tn, ok
}

// Delete removes a user's record and data.
func (t *Tenants) Delete(id UserID) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	tn, ok := t.byID[id]
	if !ok {
		return ErrUserNotFound
	}
	if err := t.db.Update(func(tx *bolt.Tx) error {
		if err := tx.Bucket([]byte(bucketUsers)).Delete(tn.hash[:]); err != nil {
			return err
		}
		return tx.Bucket([]byte(bucketData)).Delete(id[:])
	}); err != nil {
		return err
	}
	delete(t.byHash, tn.hash)
	delete(t.byID, id)
	// The Store may still be referenced by an in-flight request; its next saveState
	// sees data[id] == nil and returns ErrUserDeleted. That one request is allowed
	// to fail (spec §4.4). The limiter dies with the tenant.
	return nil
}

// List returns every registered user id, sorted byte-wise.
func (t *Tenants) List() []UserID {
	t.mu.RLock()
	defer t.mu.RUnlock()
	ids := make([]UserID, 0, len(t.byID))
	for id := range t.byID {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return bytes.Compare(ids[i][:], ids[j][:]) < 0 })
	return ids
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
