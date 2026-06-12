package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
)

// ErrNotFound is returned when a referenced task id does not exist (HTTP 404).
var ErrNotFound = errors.New("task not found")

// ValidationError reports bad client input (HTTP 400).
type ValidationError struct{ Msg string }

func (e *ValidationError) Error() string { return e.Msg }

// ConflictError reports an optimistic-concurrency version mismatch (HTTP 409).
type ConflictError struct{ Conflicts []Task }

func (e *ConflictError) Error() string { return "version conflict" }

type Store struct {
	mu     sync.RWMutex
	state  State
	parent map[string]string // childID -> parentID; absent => root
	path   string
	now    func() int64
	newID  func() string
}

func defaultNewID() string { return ulid.Make().String() }

func NewStore(path string) (*Store, error) {
	st := &Store{
		path:  path,
		now:   func() int64 { return time.Now().Unix() },
		newID: defaultNewID,
	}
	if err := st.load(); err != nil {
		return nil, err
	}
	return st, nil
}

func (st *Store) load() error {
	b, err := os.ReadFile(st.path)
	if errors.Is(err, os.ErrNotExist) {
		st.state = State{StateVersion: 0, Tasks: map[string]Task{}}
		st.rebuildIndex()
		return st.save()
	}
	if err != nil {
		return err
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	if s.Tasks == nil {
		s.Tasks = map[string]Task{}
	}
	if err := validateState(s); err != nil {
		return err
	}
	st.state = s
	st.rebuildIndex()
	return nil
}

// save writes the full state atomically: temp file -> fsync -> rename.
func (st *Store) save() error {
	b, err := json.MarshalIndent(st.state, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(st.path), ".seshat-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once renamed
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, st.path)
}

func (st *Store) rebuildIndex() {
	idx := make(map[string]string)
	for _, t := range st.state.Tasks {
		for _, c := range t.Content.ChildIDs {
			idx[c] = t.ID
		}
	}
	st.parent = idx
}

// Snapshot returns a deep copy of the current state (safe to read/serialize).
func (st *Store) Snapshot() State {
	st.mu.RLock()
	defer st.mu.RUnlock()
	return cloneState(st.state)
}

// cloneState deep-copies the task map and the per-task slices (ChildIDs, Tags).
// The nullable *int64 fields (DueAt, ScheduledAt, CompletedAt) are copied by
// pointer and thus aliased with the live state. This is safe ONLY because every
// mutation replaces Content/Meta wholesale (never writes through these pointers);
// do not introduce in-place mutation through a cloned pointer or it will corrupt
// the live state.
func cloneState(s State) State {
	ts := make(map[string]Task, len(s.Tasks))
	for k, v := range s.Tasks {
		v.Content.ChildIDs = append([]string(nil), v.Content.ChildIDs...)
		v.Content.Tags = append([]string(nil), v.Content.Tags...)
		ts[k] = v
	}
	return State{StateVersion: s.StateVersion, Tasks: ts}
}
