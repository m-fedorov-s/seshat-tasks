package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	bolt "go.etcd.io/bbolt"

	"seshat/internal/task"
)

// putBlob writes data[id] directly, with NO matching users record. loadUsers
// classifies that shape as corruption on reopen, so use it ONLY in tests that
// never reopen the file. Anything that reopens must go through tn.Create().
func putBlob(t *testing.T, tn *Tenants, id UserID, body string) {
	t.Helper()
	if err := tn.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketData)).Put(id[:], []byte(body))
	}); err != nil {
		t.Fatalf("putBlob: %v", err)
	}
}

// newTestStore returns the store of a freshly created user, with a deterministic
// clock (always returns 1000) and a counter-based id generator.
func newTestStore(t *testing.T) *Store {
	t.Helper()
	tn := openTestTenants(t)
	_, id, err := tn.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	st := tn.byID[id].store
	var n int
	st.now = func() int64 { return 1000 }
	st.newID = func() string { n++; return "id" + string(rune('0'+n)) }
	return st
}

func TestNewStoreLoadsEmptyBlob(t *testing.T) {
	st := newTestStore(t)
	snap := st.Snapshot()
	if snap.StateVersion != 0 {
		t.Fatalf("expected fresh state_version 0, got %d", snap.StateVersion)
	}
	if len(snap.Tasks) != 0 {
		t.Fatalf("expected no tasks, got %d", len(snap.Tasks))
	}
	// Pins the constant against cloneState zeroing it; nothing more.
	if snap.DataFormatVersion != CurrentDataFormatVersion {
		t.Fatalf("data_format_version = %d, want %d", snap.DataFormatVersion, CurrentDataFormatVersion)
	}
}

func TestNewStoreRefusesMissingBlob(t *testing.T) {
	tn := openTestTenants(t)
	_, err := newStore(tn.db, UserID{9})
	if err == nil || !strings.Contains(err.Error(), "no data for user") {
		t.Fatalf("newStore: got err %v, want one mentioning \"no data for user\"", err)
	}
}

func TestLoadRejectsInvalidBlob(t *testing.T) {
	tn := openTestTenants(t)
	id := UserID{1}
	// B is double-contained -> single_container violation
	putBlob(t, tn, id, `{"state_version":1,"tasks":{
		"A":{"id":"A","content":{"title":"A","status":"todo","priority":"none","child_ids":["B"],"tags":[]},"meta":{}},
		"C":{"id":"C","content":{"title":"C","status":"todo","priority":"none","child_ids":["B"],"tags":[]},"meta":{}},
		"B":{"id":"B","content":{"title":"B","status":"todo","priority":"none","child_ids":[],"tags":[]},"meta":{}}
	}}`)
	if _, err := newStore(tn.db, id); err == nil {
		t.Fatal("expected load to reject invalid state")
	}
}

func TestSaveStateRefusesWhenBlobGone(t *testing.T) {
	st := newTestStore(t)
	if _, _, err := st.Add(task.AddRequest{Content: validContent("a")}); err != nil {
		t.Fatal(err)
	}
	before := st.Snapshot()

	// Simulate Delete(id) having run while this store is still referenced.
	if err := st.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte(bucketData)).Delete(st.id[:])
	}); err != nil {
		t.Fatalf("deleting blob: %v", err)
	}

	if _, _, err := st.Add(task.AddRequest{Content: validContent("b")}); !errors.Is(err, ErrUserDeleted) {
		t.Fatalf("Add after delete: got err %v, want ErrUserDeleted", err)
	}
	if !reflect.DeepEqual(st.Snapshot(), before) {
		t.Fatal("a failed persist must leave the in-memory state untouched")
	}
}

func TestSnapshot(t *testing.T) {
	st := newTestStore(t)
	st.state.Tasks["A"] = task.Task{
		ID: "A",
		Content: task.Content{
			Title:       "Task A",
			Description: "",
			Status:      task.StatusInProgress,
			Priority:    task.PriorityMedium,
			ChildIDs:    []string{},
			Tags:        []string{},
		},
		Meta: task.Meta{},
	}

	snapshot := st.Snapshot()
	tk, ok := snapshot.Tasks["A"]
	if !ok {
		t.Fatal("Task A not in snapshot")
	}
	if tk.Content.Title != "Task A" {
		t.Fatal("Task title is wrong in snapshot.")
	}
}

func TestSnapshotKeepsEmptySlicesNonNil(t *testing.T) {
	st := newTestStore(t)
	tk, _, _ := st.Add(task.AddRequest{Content: validContent("x")})
	got := st.Snapshot().Tasks[tk.ID]
	if got.Content.ChildIDs == nil {
		t.Fatal("snapshot child_ids must stay non-nil so JSON emits [] not null")
	}
	if got.Content.Tags == nil {
		t.Fatal("snapshot tags must stay non-nil so JSON emits [] not null")
	}
}

func validContent(title string) task.Content {
	return task.Content{Title: title, Status: task.StatusTodo, Priority: task.PriorityNone}
}

func TestAddRoot(t *testing.T) {
	st := newTestStore(t)
	tk, sv, err := st.Add(task.AddRequest{Content: validContent("root task")})
	if err != nil {
		t.Fatal(err)
	}
	if tk.ID == "" || tk.Meta.Version != 1 || tk.Meta.CreatedAt != 1000 {
		t.Fatalf("bad meta: %+v", tk.Meta)
	}
	if sv != 1 {
		t.Fatalf("expected state_version 1, got %d", sv)
	}
	if tk.Content.ChildIDs == nil || tk.Content.Tags == nil {
		t.Fatal("nil slices must be normalized to empty")
	}
}

func TestAddChildBumpsParentVersion(t *testing.T) {
	st := newTestStore(t)
	parent, _, _ := st.Add(task.AddRequest{Content: validContent("parent")})
	child, sv, err := st.Add(task.AddRequest{Content: validContent("child"), ParentID: &parent.ID})
	if err != nil {
		t.Fatal(err)
	}
	snap := st.Snapshot()
	p := snap.Tasks[parent.ID]
	if len(p.Content.ChildIDs) != 1 || p.Content.ChildIDs[0] != child.ID {
		t.Fatalf("child not appended: %+v", p.Content.ChildIDs)
	}
	if p.Meta.Version != 2 {
		t.Fatalf("expected parent version bumped to 2, got %d", p.Meta.Version)
	}
	if sv != 2 {
		t.Fatalf("expected state_version 2, got %d", sv)
	}
}

func TestAddUnknownParent(t *testing.T) {
	st := newTestStore(t)
	ghost := "nope"
	_, _, err := st.Add(task.AddRequest{Content: validContent("x"), ParentID: &ghost})
	if err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestAddRejectsNonEmptyChildIDs(t *testing.T) {
	st := newTestStore(t)
	c := validContent("x")
	c.ChildIDs = []string{"whatever"}
	_, _, err := st.Add(task.AddRequest{Content: c})
	if _, ok := err.(*ValidationError); !ok {
		t.Fatalf("expected *ValidationError, got %v", err)
	}
}

func TestAddRejectsBadTitle(t *testing.T) {
	st := newTestStore(t)
	_, _, err := st.Add(task.AddRequest{Content: validContent("   ")})
	if _, ok := err.(*ValidationError); !ok {
		t.Fatalf("expected *ValidationError, got %v", err)
	}
}

func TestAddDoneSetsCompletedAt(t *testing.T) {
	st := newTestStore(t)
	c := validContent("done one")
	c.Status = task.StatusDone
	tk, _, err := st.Add(task.AddRequest{Content: c})
	if err != nil {
		t.Fatal(err)
	}
	if tk.Meta.CompletedAt == nil || *tk.Meta.CompletedAt != 1000 {
		t.Fatal("expected completed_at set on creation as done")
	}
}

func TestAddChildAtPosition(t *testing.T) {
	st := newTestStore(t)
	parent, _, _ := st.Add(task.AddRequest{Content: validContent("parent")})
	a, _, _ := st.Add(task.AddRequest{Content: validContent("a"), ParentID: &parent.ID})
	b, _, _ := st.Add(task.AddRequest{Content: validContent("b"), ParentID: &parent.ID})

	// insert c between a and b
	mid := 1
	c, _, err := st.Add(task.AddRequest{Content: validContent("c"), ParentID: &parent.ID, Position: &mid})
	if err != nil {
		t.Fatal(err)
	}
	got := st.Snapshot().Tasks[parent.ID].Content.ChildIDs
	want := []string{a.ID, c.ID, b.ID}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("mid-insert: expected %v, got %v", want, got)
	}

	// out-of-range position clamps to append
	big := 99
	d, _, err := st.Add(task.AddRequest{Content: validContent("d"), ParentID: &parent.ID, Position: &big})
	if err != nil {
		t.Fatal(err)
	}
	got = st.Snapshot().Tasks[parent.ID].Content.ChildIDs
	if got[len(got)-1] != d.ID {
		t.Fatalf("clamp-to-append: expected last=%s, got %v", d.ID, got)
	}
}

func TestDataFormatVersionSurvivesAWrite(t *testing.T) {
	// Guards the cloneState trap: cloneState rebuilds State field-by-field, so a
	// field it forgets is zeroed on the first mutation.
	st := newTestStore(t)
	if _, _, err := st.Add(task.AddRequest{Content: validContent("x")}); err != nil {
		t.Fatal(err)
	}
	if got := st.Snapshot().DataFormatVersion; got != CurrentDataFormatVersion {
		t.Fatalf("in-memory version zeroed by a write: got %d", got)
	}
}
