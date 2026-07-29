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

// TooLargeError reports a request body over the size limit (HTTP 413).
type TooLargeError struct{}

func (e *TooLargeError) Error() string { return "request body too large" }

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
		return st.saveState(st.state)
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

// saveState writes the given state atomically: temp file -> fsync -> rename.
// Callers persist a candidate state BEFORE committing it to st.state, so a save
// failure leaves the in-memory state untouched (no memory/disk divergence).
func (st *Store) saveState(s State) error {
	b, err := json.MarshalIndent(s, "", "  ")
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
		// Clone into a non-nil base so empty slices stay non-nil and serialize as
		// JSON `[]` (not `null`), matching the stored state and the schema contract.
		v.Content.ChildIDs = append([]string{}, v.Content.ChildIDs...)
		v.Content.Tags = append([]string{}, v.Content.Tags...)
		ts[k] = v
	}
	return State{StateVersion: s.StateVersion, Tasks: ts}
}

type AddRequest struct {
	Content  Content `json:"content"`
	ParentID *string `json:"parent_id"`
	Position *int    `json:"position"`
}

func validateContent(c Content) error {
	if len(c.Title) == 0 || onlySpace(c.Title) {
		return &ValidationError{"title must be non-empty"}
	}
	if !c.Status.Valid() {
		return &ValidationError{"unknown status: " + string(c.Status)}
	}
	if !c.Priority.Valid() {
		return &ValidationError{"unknown priority: " + string(c.Priority)}
	}
	return nil
}

func onlySpace(s string) bool {
	for _, r := range s {
		if r != ' ' && r != '\t' && r != '\n' && r != '\r' {
			return false
		}
	}
	return true
}

// applyCompletion sets/clears completed_at on a status transition (§2.6).
func applyCompletion(m Meta, old, next Status, now int64) Meta {
	if !old.Terminal() && next.Terminal() {
		m.CompletedAt = &now
	} else if old.Terminal() && !next.Terminal() {
		m.CompletedAt = nil
	}
	return m
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func insertAt(s []string, i int, v string) []string {
	s = append(s, "")
	copy(s[i+1:], s[i:])
	s[i] = v
	return s
}

func (st *Store) Add(req AddRequest) (Task, uint64, error) {
	if err := validateContent(req.Content); err != nil {
		return Task{}, 0, err
	}
	if len(req.Content.ChildIDs) > 0 {
		return Task{}, 0, &ValidationError{"child_ids must be empty on add"}
	}
	st.mu.Lock()
	defer st.mu.Unlock()

	now := st.now()
	c := req.Content
	c.ChildIDs = []string{}
	if c.Tags == nil {
		c.Tags = []string{}
	}
	id := st.newID()
	t := Task{ID: id, Content: c, Meta: Meta{CreatedAt: now, UpdatedAt: now, Version: 1}}
	t.Meta = applyCompletion(t.Meta, StatusTodo, c.Status, now)

	cand := cloneState(st.state)
	cand.Tasks[id] = t

	if req.ParentID != nil {
		p, ok := cand.Tasks[*req.ParentID]
		if !ok {
			return Task{}, 0, ErrNotFound
		}
		pos := len(p.Content.ChildIDs)
		if req.Position != nil {
			pos = clamp(*req.Position, 0, len(p.Content.ChildIDs))
		}
		p.Content.ChildIDs = insertAt(p.Content.ChildIDs, pos, id)
		p.Meta.Version++
		p.Meta.UpdatedAt = now
		cand.Tasks[*req.ParentID] = p
	}

	if err := validateState(cand); err != nil {
		return Task{}, 0, err
	}
	cand.StateVersion++
	if err := st.saveState(cand); err != nil {
		return Task{}, 0, err
	}
	st.state = cand
	st.rebuildIndex()
	return st.state.Tasks[id], st.state.StateVersion, nil
}

type UpdateOp struct {
	ID              string  `json:"id"`
	Content         Content `json:"content"`
	ExpectedVersion uint64  `json:"expected_version"`
}

func (st *Store) Update(ops []UpdateOp) ([]Task, uint64, error) {
	seen := map[string]struct{}{}
	for _, op := range ops {
		if err := validateContent(op.Content); err != nil {
			return nil, 0, err
		}
		if _, dup := seen[op.ID]; dup {
			return nil, 0, &ValidationError{"duplicate id in batch: " + op.ID}
		}
		seen[op.ID] = struct{}{}
	}
	st.mu.Lock()
	defer st.mu.Unlock()

	// existence
	for _, op := range ops {
		if _, ok := st.state.Tasks[op.ID]; !ok {
			return nil, 0, ErrNotFound
		}
	}
	// conflicts (collect all, then reject)
	var conflicts []Task
	for _, op := range ops {
		cur := st.state.Tasks[op.ID]
		if cur.Meta.Version != op.ExpectedVersion {
			conflicts = append(conflicts, cur)
		}
	}
	if len(conflicts) > 0 {
		return nil, 0, &ConflictError{Conflicts: conflicts}
	}

	now := st.now()
	cand := cloneState(st.state)
	for _, op := range ops {
		t := cand.Tasks[op.ID]
		oldStatus := t.Content.Status
		c := op.Content
		if c.ChildIDs == nil {
			c.ChildIDs = []string{}
		}
		if c.Tags == nil {
			c.Tags = []string{}
		}
		t.Content = c
		t.Meta = applyCompletion(t.Meta, oldStatus, c.Status, now)
		t.Meta.Version++
		t.Meta.UpdatedAt = now
		cand.Tasks[op.ID] = t
	}
	if err := validateState(cand); err != nil {
		return nil, 0, err
	}
	cand.StateVersion++
	if err := st.saveState(cand); err != nil {
		return nil, 0, err
	}
	st.state = cand
	st.rebuildIndex()
	out := make([]Task, 0, len(ops))
	for _, op := range ops {
		out = append(out, st.state.Tasks[op.ID])
	}
	return out, st.state.StateVersion, nil
}

func removeString(s []string, v string) []string {
	out := s[:0]
	for _, x := range s {
		if x != v {
			out = append(out, x)
		}
	}
	return out
}

func (st *Store) Delete(id string) (uint64, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if _, ok := st.state.Tasks[id]; !ok {
		return 0, ErrNotFound
	}
	now := st.now()
	cand := cloneState(st.state)
	if pid, ok := st.parent[id]; ok {
		p := cand.Tasks[pid]
		p.Content.ChildIDs = removeString(p.Content.ChildIDs, id)
		p.Meta.Version++
		p.Meta.UpdatedAt = now
		cand.Tasks[pid] = p
	}
	delete(cand.Tasks, id) // its former children become unreferenced roots
	if err := validateState(cand); err != nil {
		return 0, err
	}
	cand.StateVersion++
	if err := st.saveState(cand); err != nil {
		return 0, err
	}
	st.state = cand
	st.rebuildIndex()
	return st.state.StateVersion, nil
}
