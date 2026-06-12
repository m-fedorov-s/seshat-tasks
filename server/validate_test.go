package main

import "testing"

func mkTask(id string, children ...string) Task {
	return Task{ID: id, Content: Content{Title: id, Status: StatusTodo, Priority: PriorityNone, ChildIDs: children, Tags: []string{}}}
}

func stateOf(tasks ...Task) State {
	m := map[string]Task{}
	for _, t := range tasks {
		m[t.ID] = t
	}
	return State{Tasks: m}
}

func TestValidateStateOK(t *testing.T) {
	s := stateOf(mkTask("A", "B"), mkTask("B"), mkTask("C"))
	if err := validateState(s); err != nil {
		t.Fatalf("expected valid, got %v", err)
	}
}

func TestValidateDanglingChild(t *testing.T) {
	s := stateOf(mkTask("A", "ghost"))
	assertInvariant(t, validateState(s), "dangling_child")
}

func TestValidateDoubleContained(t *testing.T) {
	s := stateOf(mkTask("A", "B"), mkTask("C", "B"), mkTask("B"))
	assertInvariant(t, validateState(s), "single_container")
}

func TestValidateDuplicateInList(t *testing.T) {
	s := stateOf(mkTask("A", "B", "B"), mkTask("B"))
	assertInvariant(t, validateState(s), "duplicate_in_list")
}

func TestValidateSelfReference(t *testing.T) {
	s := stateOf(mkTask("A", "A"))
	assertInvariant(t, validateState(s), "cycle")
}

func TestValidateCycle(t *testing.T) {
	s := stateOf(mkTask("A", "B"), mkTask("B", "A"))
	assertInvariant(t, validateState(s), "cycle")
}

func assertInvariant(t *testing.T, err error, want string) {
	t.Helper()
	ie, ok := err.(*InvariantError)
	if !ok {
		t.Fatalf("expected *InvariantError, got %v", err)
	}
	if ie.Invariant != want {
		t.Fatalf("expected invariant %q, got %q", want, ie.Invariant)
	}
}
