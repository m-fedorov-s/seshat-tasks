package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"

	"seshat/internal/task"
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

func TestOpenWarnsOnPermissiveDataFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatalf("Chmod: %v", err)
	}

	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)

	tn2, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants on a permissive file: got %v, want success", err)
	}
	t.Cleanup(func() { tn2.Close() })

	if got := buf.String(); !strings.Contains(got, "WARNING") || !strings.Contains(got, path) {
		t.Fatalf("log output = %q, want a WARNING mentioning %s", got, path)
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

func TestOpenRefusesShortFormatVersion(t *testing.T) {
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
		return tx.Bucket([]byte(bucketMeta)).Put([]byte(keyFormatVersion), []byte{1, 2, 3, 4})
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
}

func TestOpenRefusesShortUsersKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	tok, _, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	h := tokenHash(tok)
	rec, err := json.Marshal(User{ID: UserID{1}})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		users := tx.Bucket([]byte(bucketUsers))
		if err := users.Delete(h[:]); err != nil {
			return err
		}
		return users.Put(h[:5], rec)
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "corrupt") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning corrupt", err)
	}
}

func TestOpenRefusesShortDataKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	_, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		data := tx.Bucket([]byte(bucketData))
		v := data.Get(id[:])
		vCopy := append([]byte(nil), v...)
		// Leave the real 16-byte entry in place — deleting it would make loadUsers
		// fail on "user has no data" before it ever reaches the data.ForEach length
		// check this test targets. Add a second, malformed-length key alongside it.
		return data.Put(id[:5], vCopy)
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "corrupt") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning corrupt", err)
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

// TestOpenRefusesZeroFormatVersion pins F5: format_version 0 is never written by
// this code (init always writes CurrentDataFormatVersion, >= 1), so a stored 0 is
// corruption — not a legitimate "no version check needed" sentinel.
func TestOpenRefusesZeroFormatVersion(t *testing.T) {
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
		return tx.Bucket([]byte(bucketMeta)).Put([]byte(keyFormatVersion), be64(0))
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

func TestUserIDHexRoundTrip(t *testing.T) {
	id := UserID{0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	const want = "deadbeef000000000000000000000001"
	if got := id.String(); got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}

	b, err := json.Marshal(User{ID: id})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if got := string(b); got != `{"id":"`+want+`"}` {
		t.Fatalf("Marshal = %s", got)
	}
	var u User
	if err := json.Unmarshal(b, &u); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if u.ID != id {
		t.Fatalf("round trip = %s, want %s", u.ID, id)
	}

	if _, err := parseUserID("zz"); err == nil {
		t.Fatal("parseUserID(\"zz\"): want an error, got nil")
	}
	if _, err := parseUserID(strings.Repeat("a", 31)); err == nil {
		t.Fatal("parseUserID(odd length): want an error, got nil")
	}
	if _, err := parseUserID(strings.Repeat("a", 30)); err == nil {
		t.Fatal("parseUserID(15 bytes): want an error, got nil")
	}

	if !(UserID{}).IsZero() {
		t.Fatal("zero UserID must report IsZero")
	}
	if id.IsZero() {
		t.Fatal("non-zero UserID must not report IsZero")
	}
}

func TestCreateThenAuthenticate(t *testing.T) {
	tn := openTestTenants(t)
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(tok) != 64 {
		t.Fatalf("token length = %d, want 64", len(tok))
	}
	if strings.Trim(tok, "0123456789abcdef") != "" {
		t.Fatalf("token %q is not lowercase hex", tok)
	}
	if id.IsZero() {
		t.Fatal("Create returned a zero id")
	}

	tenant, ok := tn.Authenticate(tok)
	if !ok {
		t.Fatal("Authenticate(tok): not ok")
	}
	if tenant.id != id {
		t.Fatalf("tenant.id = %s, want %s", tenant.id, id)
	}
	if tenant.store == nil || tenant.limiter == nil {
		t.Fatalf("tenant not fully populated: %+v", tenant)
	}
	if got := tenant.store.Snapshot().StateVersion; got != 0 {
		t.Fatalf("fresh store state_version = %d, want 0", got)
	}
}

func TestAuthenticateRejects(t *testing.T) {
	tn := openTestTenants(t)
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	for _, bad := range []string{"", "wrong", tok + "0"} {
		if _, ok := tn.Authenticate(bad); ok {
			t.Fatalf("Authenticate(%q): want !ok", bad)
		}
	}
	if err := tn.Delete(id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok := tn.Authenticate(tok); ok {
		t.Fatal("Authenticate after Delete: want !ok")
	}
}

func TestCreateWritesUserAndDataEntries(t *testing.T) {
	tn := openTestTenants(t)
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	h := tokenHash(tok)
	if err := tn.db.View(func(tx *bolt.Tx) error {
		raw := tx.Bucket([]byte(bucketUsers)).Get(h[:])
		if raw == nil {
			t.Fatal("no users record for the minted token hash")
		}
		var u User
		if err := json.Unmarshal(raw, &u); err != nil {
			t.Fatalf("user record is not JSON: %v", err)
		}
		if u.ID != id {
			t.Fatalf("record id = %s, want %s", u.ID, id)
		}
		if tx.Bucket([]byte(bucketData)).Get(id[:]) == nil {
			t.Fatal("no data blob for the new user")
		}
		return nil
	}); err != nil {
		t.Fatalf("View: %v", err)
	}
}

func TestDeleteRemovesRecordAndData(t *testing.T) {
	tn := openTestTenants(t)
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	h := tokenHash(tok)
	tenant, ok := tn.Authenticate(tok)
	if !ok {
		t.Fatal("Authenticate: not ok")
	}
	if _, _, err := tenant.store.Add(task.AddRequest{Content: validContent("x")}); err != nil {
		t.Fatalf("Add: %v", err)
	}

	if err := tn.Delete(id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if err := tn.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket([]byte(bucketUsers)).Get(h[:]) != nil {
			t.Fatal("users record survived Delete")
		}
		if tx.Bucket([]byte(bucketData)).Get(id[:]) != nil {
			t.Fatal("data blob survived Delete")
		}
		return nil
	}); err != nil {
		t.Fatalf("View: %v", err)
	}

	err = tn.Delete(id)
	if !errors.Is(err, ErrUserNotFound) {
		t.Fatalf("second Delete: got %v, want ErrUserNotFound", err)
	}
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("second Delete: %v must wrap ErrNotFound so writeErr maps it to 404", err)
	}
	if got := tn.List(); len(got) != 0 {
		t.Fatalf("List after Delete = %v, want empty", got)
	}
}

func TestDeleteLeavesOtherTenantsIntact(t *testing.T) {
	tn := openTestTenants(t)
	tokA, idA, err := tn.Create()
	if err != nil {
		t.Fatalf("Create A: %v", err)
	}
	tokB, idB, err := tn.Create()
	if err != nil {
		t.Fatalf("Create B: %v", err)
	}
	a, ok := tn.Authenticate(tokA)
	if !ok {
		t.Fatal("Authenticate A: not ok")
	}
	b, ok := tn.Authenticate(tokB)
	if !ok {
		t.Fatal("Authenticate B: not ok")
	}
	if _, _, err := a.store.Add(task.AddRequest{Content: validContent("a-task")}); err != nil {
		t.Fatalf("A Add: %v", err)
	}
	if _, _, err := b.store.Add(task.AddRequest{Content: validContent("b-task")}); err != nil {
		t.Fatalf("B Add: %v", err)
	}

	if err := tn.Delete(idA); err != nil {
		t.Fatalf("Delete A: %v", err)
	}

	if _, ok := tn.Authenticate(tokB); !ok {
		t.Fatal("B no longer authenticates after Delete(A)")
	}
	assertOnlyTask(t, b.store, "b-task")
	if err := tn.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket([]byte(bucketData)).Get(idB[:]) == nil {
			t.Fatal("B's data blob was removed by Delete(A)")
		}
		return nil
	}); err != nil {
		t.Fatalf("View: %v", err)
	}
}

func TestListIsSorted(t *testing.T) {
	tn := openTestTenants(t)
	want := map[UserID]bool{}
	for i := 0; i < 5; i++ {
		_, id, err := tn.Create()
		if err != nil {
			t.Fatalf("Create: %v", err)
		}
		want[id] = true
	}

	got := tn.List()
	if len(got) != 5 {
		t.Fatalf("List returned %d ids, want 5", len(got))
	}
	if !sort.SliceIsSorted(got, func(i, j int) bool { return bytes.Compare(got[i][:], got[j][:]) < 0 }) {
		t.Fatalf("List is not sorted: %v", got)
	}
	for _, id := range got {
		if !want[id] {
			t.Fatalf("List returned unknown id %s", id)
		}
		delete(want, id)
	}
	if len(want) != 0 {
		t.Fatalf("List omitted %d ids", len(want))
	}
}

func TestTwoUsersHaveIndependentBlobs(t *testing.T) {
	tn := openTestTenants(t)
	tokA, _, err := tn.Create()
	if err != nil {
		t.Fatalf("Create A: %v", err)
	}
	tokB, _, err := tn.Create()
	if err != nil {
		t.Fatalf("Create B: %v", err)
	}
	a, _ := tn.Authenticate(tokA)
	b, _ := tn.Authenticate(tokB)

	if _, _, err := a.store.Add(task.AddRequest{Content: validContent("only-a")}); err != nil {
		t.Fatalf("A Add: %v", err)
	}
	snapB := b.store.Snapshot()
	if len(snapB.Tasks) != 0 || snapB.StateVersion != 0 {
		t.Fatalf("A's write leaked into B: %+v", snapB)
	}
	if _, _, err := b.store.Add(task.AddRequest{Content: validContent("only-b")}); err != nil {
		t.Fatalf("B Add: %v", err)
	}
	if got := a.store.Snapshot().StateVersion; got != 1 {
		t.Fatalf("B's write leaked into A: A state_version = %d, want 1", got)
	}

	path := tn.db.Path()
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	tn2, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { tn2.Close() })

	a2, ok := tn2.Authenticate(tokA)
	if !ok {
		t.Fatal("A does not authenticate after reopen")
	}
	b2, ok := tn2.Authenticate(tokB)
	if !ok {
		t.Fatal("B does not authenticate after reopen")
	}
	assertOnlyTask(t, a2.store, "only-a")
	assertOnlyTask(t, b2.store, "only-b")
}

// assertOnlyTask fails unless st holds exactly one task, with the given title.
func assertOnlyTask(t *testing.T, st *Store, title string) {
	t.Helper()
	snap := st.Snapshot()
	if len(snap.Tasks) != 1 {
		t.Fatalf("want exactly 1 task, got %d", len(snap.Tasks))
	}
	for _, tk := range snap.Tasks {
		if tk.Content.Title != title {
			t.Fatalf("task title = %q, want %q", tk.Content.Title, title)
		}
	}
}

func TestPersistenceRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "seshat.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	st := tn.byID[id].store
	var n int
	st.now = func() int64 { return 1000 }
	st.newID = func() string { n++; return "id" + string(rune('0'+n)) }

	parent, _, err := st.Add(task.AddRequest{Content: validContent("p")})
	if err != nil {
		t.Fatalf("Add parent: %v", err)
	}
	if _, _, err := st.Add(task.AddRequest{Content: validContent("c"), ParentID: &parent.ID}); err != nil {
		t.Fatalf("Add child: %v", err)
	}
	done := validContent("p")
	done.Status = task.StatusDone
	done.ChildIDs = st.Snapshot().Tasks[parent.ID].Content.ChildIDs
	if _, _, err := st.Update([]task.UpdateOp{{ID: parent.ID, ExpectedVersion: 2, Content: done}}); err != nil {
		t.Fatalf("Update: %v", err)
	}
	want := st.Snapshot()
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	tn2, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { tn2.Close() })
	tenant2, ok := tn2.Authenticate(tok)
	if !ok {
		t.Fatal("token does not authenticate after reopen")
	}
	if got := tenant2.store.Snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("round trip lost state:\n got %+v\nwant %+v", got, want)
	}
}

func TestOpenRefusesUserWithoutData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	_, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketData)).Delete(id[:])
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "corrupt") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning corrupt", err)
	}

	// The failed open must have released the flock.
	db2 := reopenRaw(t, path)
	if err := db2.Close(); err != nil {
		t.Fatalf("db2.Close: %v", err)
	}
}

func TestOpenRefusesDataWithoutUser(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	tok, _, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	h := tokenHash(tok)

	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketUsers)).Delete(h[:])
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "corrupt") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning corrupt", err)
	}
}

func TestOpenRefusesMalformedUserRecord(t *testing.T) {
	for _, bad := range []string{
		`not json`,
		`{"id":"00000000000000000000000000000000"}`, // zero id is the corruption sentinel
		`{"id":"zz"}`,
	} {
		t.Run(bad, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "x.db")
			tn, err := OpenTenants(path, defaultRateLimit)
			if err != nil {
				t.Fatalf("OpenTenants: %v", err)
			}
			tok, _, err := tn.Create()
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if err := tn.Close(); err != nil {
				t.Fatalf("Close: %v", err)
			}

			h := tokenHash(tok)
			db := reopenRaw(t, path)
			if err := db.Update(func(tx *bolt.Tx) error {
				return tx.Bucket([]byte(bucketUsers)).Put(h[:], []byte(bad))
			}); err != nil {
				t.Fatalf("corrupting update: %v", err)
			}
			if err := db.Close(); err != nil {
				t.Fatalf("db.Close: %v", err)
			}

			if _, err := OpenTenants(path, defaultRateLimit); err == nil {
				t.Fatalf("OpenTenants accepted a malformed user record %q", bad)
			}
		})
	}
}

func TestOpenRefusesTwoUsersSharingAnID(t *testing.T) {
	// The code never writes this shape; it is corruption.
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	_, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	rec, err := json.Marshal(User{ID: id})
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	other := tokenHash("other")
	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketUsers)).Put(other[:], rec)
	}); err != nil {
		t.Fatalf("corrupting update: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	_, err = OpenTenants(path, defaultRateLimit)
	if err == nil || !strings.Contains(err.Error(), "corrupt") {
		t.Fatalf("OpenTenants: got err %v, want one mentioning corrupt", err)
	}
}

func TestUserRecordWithUnknownFieldLoads(t *testing.T) {
	// Forward compatibility (spec §4.1): an unknown field must not fail the load.
	path := filepath.Join(t.TempDir(), "x.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	h := tokenHash(tok)
	db := reopenRaw(t, path)
	if err := db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketUsers)).Put(h[:], []byte(`{"id":"`+id.String()+`","quota":123}`))
	}); err != nil {
		t.Fatalf("rewriting record: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("db.Close: %v", err)
	}

	tn2, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	t.Cleanup(func() { tn2.Close() })
	if _, ok := tn2.Authenticate(tok); !ok {
		t.Fatal("a record with an unknown field must still authenticate")
	}
}

func TestConcurrentCreatesAreDistinct(t *testing.T) {
	// Under -race this also observes the byHash/byID writes under Tenants.mu.
	tn := openTestTenants(t)
	const n = 32
	type made struct {
		tok string
		id  UserID
	}
	ch := make(chan made, n)
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		go func() {
			tok, id, err := tn.Create()
			if err != nil {
				errs <- err
				return
			}
			ch <- made{tok, id}
		}()
	}

	toks := map[string]bool{}
	ids := map[UserID]bool{}
	for i := 0; i < n; i++ {
		select {
		case err := <-errs:
			t.Fatalf("Create: %v", err)
		case m := <-ch:
			if toks[m.tok] {
				t.Fatalf("duplicate token %s", m.tok)
			}
			if ids[m.id] {
				t.Fatalf("duplicate id %s", m.id)
			}
			toks[m.tok] = true
			ids[m.id] = true
		}
	}
	for tok := range toks {
		if _, ok := tn.Authenticate(tok); !ok {
			t.Fatalf("token %s does not authenticate", tok)
		}
	}
	if got := len(tn.List()); got != n {
		t.Fatalf("List returned %d ids, want %d", got, n)
	}
}

func TestDeleteRacingWritesNeverPanics(t *testing.T) {
	// A deadlock/panic smoke test, not a data-race test: the two goroutines share
	// no unguarded memory. What it pins is that Tenants.mu and Store.mu are never
	// nested, so a Delete during a burst of writes cannot deadlock.
	tn := openTestTenants(t)
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	tenant, ok := tn.Authenticate(tok)
	if !ok {
		t.Fatal("Authenticate: not ok")
	}

	started := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 200; i++ {
			if i == 1 {
				close(started) // Delete only after a real Add has committed
			}
			// ErrUserDeleted is expected once Delete lands; a panic is not.
			tenant.store.Add(task.AddRequest{Content: validContent("x")})
		}
	}()

	<-started
	if err := tn.Delete(id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	<-done
}

// TestCreateYieldsAUsableEmptyStoreThatSurvivesReopen is a characterization test
// (Plan A review, finding 5): Create must not depend on a successful read of the
// blob it just wrote — a read-back failure left an on-disk user unregistered.
// That is not observable from outside; what IS observable, and pinned here, is
// that the store Create hands out is usable and empty, and matches a reload.
// This passes before and after the refactor to newEmptyStore; it is not a
// RED->GREEN test.
func TestCreateYieldsAUsableEmptyStoreThatSurvivesReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "seshat.db")
	tn, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	t.Cleanup(func() { tn.Close() }) // belt-and-suspenders: a failed assertion below must not leak the flock
	tok, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	tenant, ok := tn.Authenticate(tok)
	if !ok {
		t.Fatal("Authenticate: not ok")
	}

	snap := tenant.store.Snapshot()
	if snap.StateVersion != 0 {
		t.Fatalf("state_version = %d, want 0", snap.StateVersion)
	}
	if len(snap.Tasks) != 0 {
		t.Fatalf("tasks = %+v, want empty", snap.Tasks)
	}
	if snap.DataFormatVersion != CurrentDataFormatVersion {
		t.Fatalf("data_format_version = %d, want %d", snap.DataFormatVersion, CurrentDataFormatVersion)
	}

	// Direct equivalence against newStore reading the SAME just-written blob: Snapshot
	// and cloneState self-heal a nil Tasks map, and parent is only ever read by Delete,
	// so the assertions above cannot catch newEmptyStore skipping rebuildIndex() or
	// leaving a field nil. Compare the unexported state directly (package main).
	ref, err := newStore(tn.db, id)
	if err != nil {
		t.Fatalf("newStore on the same blob: %v", err)
	}
	if !reflect.DeepEqual(tenant.store.state, ref.state) {
		t.Fatalf("store.state = %+v, want %+v (from newStore on the same blob)", tenant.store.state, ref.state)
	}
	if !reflect.DeepEqual(tenant.store.parent, ref.parent) {
		t.Fatalf("store.parent = %+v, want %+v (from newStore on the same blob)", tenant.store.parent, ref.parent)
	}
	if tenant.store.parent == nil || ref.parent == nil {
		t.Fatal("parent must be a non-nil empty map on both stores")
	}
	if tenant.store.now == nil || tenant.store.newID == nil {
		t.Fatal("store.now and store.newID must be non-nil")
	}

	added, _, err := tenant.store.Add(task.AddRequest{Content: validContent("x")})
	if err != nil {
		t.Fatalf("Add on the fresh store: %v", err)
	}

	if err := tn.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	tn2, err := OpenTenants(path, defaultRateLimit)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { tn2.Close() })
	tenant2, ok := tn2.Authenticate(tok)
	if !ok {
		t.Fatal("token does not authenticate after reopen")
	}
	got := tenant2.store.Snapshot()
	if len(got.Tasks) != 1 {
		t.Fatalf("reopened store has %d tasks, want 1: %+v", len(got.Tasks), got.Tasks)
	}
	reloaded, ok := got.Tasks[added.ID]
	if !ok || reloaded.Content.Title != "x" {
		t.Fatalf("reopened store does not have task %q titled \"x\": %+v", added.ID, got.Tasks)
	}
}
