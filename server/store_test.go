package main

import (
	"os"
	"path/filepath"
	"testing"
)

// newTestStore returns a store backed by a temp file, with a deterministic
// clock (always returns 1000) and a counter-based id generator.
func newTestStore(t *testing.T) *Store {
	t.Helper()
	path := filepath.Join(t.TempDir(), "data.json")
	st, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	var n int
	st.now = func() int64 { return 1000 }
	st.newID = func() string { n++; return "id" + string(rune('0'+n)) }
	return st
}

func TestNewStoreCreatesFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	st, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected file created: %v", err)
	}
	if st.Snapshot().StateVersion != 0 {
		t.Fatal("expected fresh state_version 0")
	}
	if len(st.Snapshot().Tasks) != 0 {
		t.Fatal("expected no tasks")
	}
}

func TestLoadRejectsInvalidFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	// B is double-contained -> invalid
	os.WriteFile(path, []byte(`{"state_version":1,"tasks":{
		"A":{"id":"A","content":{"title":"A","status":"todo","priority":"none","child_ids":["B"],"tags":[]},"meta":{}},
		"C":{"id":"C","content":{"title":"C","status":"todo","priority":"none","child_ids":["B"],"tags":[]},"meta":{}},
		"B":{"id":"B","content":{"title":"B","status":"todo","priority":"none","child_ids":[],"tags":[]},"meta":{}}
	}}`), 0o644)
	if _, err := NewStore(path); err == nil {
		t.Fatal("expected load to reject invalid state")
	}
}

func TestSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data.json")
	st, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	st.state.Tasks["A"] = Task{
		ID: "A",
		Content: Content{
			Title:       "Task A",
			Description: "",
			Status:      StatusInProgress,
			Priority:    PriorityMedium,
			ChildIDs:    []string{},
			Tags:        []string{},
		},
		Meta: Meta{},
	}

	snapshot := st.Snapshot()
	task, ok := snapshot.Tasks["A"]
	if !ok {
		t.Fatal("Task A not in snapshot")
	}
	if task.Content.Title != "Task A" {
		t.Fatal("Task title is wrong in snapshot.")
	}
}

func TestSnapshotKeepsEmptySlicesNonNil(t *testing.T) {
	st := newTestStore(t)
	task, _, _ := st.Add(AddRequest{Content: validContent("x")})
	got := st.Snapshot().Tasks[task.ID]
	if got.Content.ChildIDs == nil {
		t.Fatal("snapshot child_ids must stay non-nil so JSON emits [] not null")
	}
	if got.Content.Tags == nil {
		t.Fatal("snapshot tags must stay non-nil so JSON emits [] not null")
	}
}

func validContent(title string) Content {
	return Content{Title: title, Status: StatusTodo, Priority: PriorityNone}
}

func TestAddRoot(t *testing.T) {
	st := newTestStore(t)
	task, sv, err := st.Add(AddRequest{Content: validContent("root task")})
	if err != nil {
		t.Fatal(err)
	}
	if task.ID == "" || task.Meta.Version != 1 || task.Meta.CreatedAt != 1000 {
		t.Fatalf("bad meta: %+v", task.Meta)
	}
	if sv != 1 {
		t.Fatalf("expected state_version 1, got %d", sv)
	}
	if task.Content.ChildIDs == nil || task.Content.Tags == nil {
		t.Fatal("nil slices must be normalized to empty")
	}
}

func TestAddChildBumpsParentVersion(t *testing.T) {
	st := newTestStore(t)
	parent, _, _ := st.Add(AddRequest{Content: validContent("parent")})
	child, sv, err := st.Add(AddRequest{Content: validContent("child"), ParentID: &parent.ID})
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
	_, _, err := st.Add(AddRequest{Content: validContent("x"), ParentID: &ghost})
	if err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestAddRejectsNonEmptyChildIDs(t *testing.T) {
	st := newTestStore(t)
	c := validContent("x")
	c.ChildIDs = []string{"whatever"}
	_, _, err := st.Add(AddRequest{Content: c})
	if _, ok := err.(*ValidationError); !ok {
		t.Fatalf("expected *ValidationError, got %v", err)
	}
}

func TestAddRejectsBadTitle(t *testing.T) {
	st := newTestStore(t)
	_, _, err := st.Add(AddRequest{Content: validContent("   ")})
	if _, ok := err.(*ValidationError); !ok {
		t.Fatalf("expected *ValidationError, got %v", err)
	}
}

func TestAddDoneSetsCompletedAt(t *testing.T) {
	st := newTestStore(t)
	c := validContent("done one")
	c.Status = StatusDone
	task, _, err := st.Add(AddRequest{Content: c})
	if err != nil {
		t.Fatal(err)
	}
	if task.Meta.CompletedAt == nil || *task.Meta.CompletedAt != 1000 {
		t.Fatal("expected completed_at set on creation as done")
	}
}

func TestAddChildAtPosition(t *testing.T) {
	st := newTestStore(t)
	parent, _, _ := st.Add(AddRequest{Content: validContent("parent")})
	a, _, _ := st.Add(AddRequest{Content: validContent("a"), ParentID: &parent.ID})
	b, _, _ := st.Add(AddRequest{Content: validContent("b"), ParentID: &parent.ID})

	// insert c between a and b
	mid := 1
	c, _, err := st.Add(AddRequest{Content: validContent("c"), ParentID: &parent.ID, Position: &mid})
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
	d, _, err := st.Add(AddRequest{Content: validContent("d"), ParentID: &parent.ID, Position: &big})
	if err != nil {
		t.Fatal(err)
	}
	got = st.Snapshot().Tasks[parent.ID].Content.ChildIDs
	if got[len(got)-1] != d.ID {
		t.Fatalf("clamp-to-append: expected last=%s, got %v", d.ID, got)
	}
}
