package main

import "testing"

func TestUpdateContentBumpsVersion(t *testing.T) {
	st := newTestStore(t)
	task, _, _ := st.Add(AddRequest{Content: validContent("orig")})
	c := task.Content
	c.Title = "renamed"
	updated, sv, err := st.Update([]UpdateOp{{ID: task.ID, Content: c, ExpectedVersion: 1}})
	if err != nil {
		t.Fatal(err)
	}
	if updated[0].Content.Title != "renamed" || updated[0].Meta.Version != 2 {
		t.Fatalf("bad update: %+v", updated[0])
	}
	if sv != 2 {
		t.Fatalf("expected state_version 2, got %d", sv)
	}
}

func TestUpdateStaleVersionConflicts(t *testing.T) {
	st := newTestStore(t)
	task, _, _ := st.Add(AddRequest{Content: validContent("orig")})
	_, _, err := st.Update([]UpdateOp{{ID: task.ID, Content: task.Content, ExpectedVersion: 99}})
	ce, ok := err.(*ConflictError)
	if !ok {
		t.Fatalf("expected *ConflictError, got %v", err)
	}
	if len(ce.Conflicts) != 1 || ce.Conflicts[0].ID != task.ID {
		t.Fatalf("expected conflict to carry current task, got %+v", ce.Conflicts)
	}
}

func TestUpdateRejectsDuplicateIDInBatch(t *testing.T) {
	st := newTestStore(t)
	task, _, _ := st.Add(AddRequest{Content: validContent("orig")})
	c := task.Content
	c.Title = "renamed"
	_, _, err := st.Update([]UpdateOp{
		{ID: task.ID, Content: c, ExpectedVersion: 1},
		{ID: task.ID, Content: c, ExpectedVersion: 1},
	})
	if _, ok := err.(*ValidationError); !ok {
		t.Fatalf("expected *ValidationError for duplicate id, got %v", err)
	}
	if st.Snapshot().Tasks[task.ID].Meta.Version != 1 {
		t.Fatal("expected no mutation on duplicate-id rejection")
	}
}

func TestUpdateUnknownID(t *testing.T) {
	st := newTestStore(t)
	_, _, err := st.Update([]UpdateOp{{ID: "ghost", Content: validContent("x"), ExpectedVersion: 1}})
	if err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestUpdateAtomicReparent(t *testing.T) {
	st := newTestStore(t)
	pOld, _, _ := st.Add(AddRequest{Content: validContent("pOld")})
	pNew, _, _ := st.Add(AddRequest{Content: validContent("pNew")})
	child, _, _ := st.Add(AddRequest{Content: validContent("child"), ParentID: &pOld.ID})

	snap := st.Snapshot()
	oldC := snap.Tasks[pOld.ID].Content
	oldC.ChildIDs = []string{} // remove child
	newC := snap.Tasks[pNew.ID].Content
	newC.ChildIDs = []string{child.ID} // add child

	_, _, err := st.Update([]UpdateOp{
		{ID: pOld.ID, Content: oldC, ExpectedVersion: snap.Tasks[pOld.ID].Meta.Version},
		{ID: pNew.ID, Content: newC, ExpectedVersion: snap.Tasks[pNew.ID].Meta.Version},
	})
	if err != nil {
		t.Fatalf("reparent failed: %v", err)
	}
	final := st.Snapshot()
	if len(final.Tasks[pOld.ID].Content.ChildIDs) != 0 {
		t.Fatal("child not removed from old parent")
	}
	if len(final.Tasks[pNew.ID].Content.ChildIDs) != 1 {
		t.Fatal("child not added to new parent")
	}
}

func TestUpdateRejectsDoubleContainNothingApplied(t *testing.T) {
	st := newTestStore(t)
	pOld, _, _ := st.Add(AddRequest{Content: validContent("pOld")})
	pNew, _, _ := st.Add(AddRequest{Content: validContent("pNew")})
	child, _, _ := st.Add(AddRequest{Content: validContent("child"), ParentID: &pOld.ID})

	snap := st.Snapshot()
	newC := snap.Tasks[pNew.ID].Content
	newC.ChildIDs = []string{child.ID} // add to new WITHOUT removing from old -> double contained

	_, _, err := st.Update([]UpdateOp{
		{ID: pNew.ID, Content: newC, ExpectedVersion: snap.Tasks[pNew.ID].Meta.Version},
	})
	if _, ok := err.(*InvariantError); !ok {
		t.Fatalf("expected *InvariantError, got %v", err)
	}
	final := st.Snapshot()
	if len(final.Tasks[pNew.ID].Content.ChildIDs) != 0 || final.Tasks[pNew.ID].Meta.Version != snap.Tasks[pNew.ID].Meta.Version {
		t.Fatal("expected no mutation on invariant rejection")
	}
}

func TestUpdateTransitionSetsCompletedAt(t *testing.T) {
	st := newTestStore(t)
	task, _, _ := st.Add(AddRequest{Content: validContent("t")})
	c := task.Content
	c.Status = StatusDone
	updated, _, _ := st.Update([]UpdateOp{{ID: task.ID, Content: c, ExpectedVersion: 1}})
	if updated[0].Meta.CompletedAt == nil {
		t.Fatal("expected completed_at set on transition to done")
	}
}
