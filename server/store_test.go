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
