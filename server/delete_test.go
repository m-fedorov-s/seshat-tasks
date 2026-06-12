package main

import "testing"

func TestDeleteDetachesFromParent(t *testing.T) {
	st := newTestStore(t)
	parent, _, _ := st.Add(AddRequest{Content: validContent("parent")})
	child, _, _ := st.Add(AddRequest{Content: validContent("child"), ParentID: &parent.ID})

	sv, err := st.Delete(child.ID)
	if err != nil {
		t.Fatal(err)
	}
	snap := st.Snapshot()
	if _, ok := snap.Tasks[child.ID]; ok {
		t.Fatal("child not deleted")
	}
	if len(snap.Tasks[parent.ID].Content.ChildIDs) != 0 {
		t.Fatal("child id not removed from parent")
	}
	if snap.Tasks[parent.ID].Meta.Version != 3 { // 1 create, 2 add child, 3 detach
		t.Fatalf("expected parent version 3, got %d", snap.Tasks[parent.ID].Meta.Version)
	}
	if sv == 0 {
		t.Fatal("expected state_version bumped")
	}
}

func TestDeletePromotesChildrenToRoots(t *testing.T) {
	st := newTestStore(t)
	parent, _, _ := st.Add(AddRequest{Content: validContent("parent")})
	child, _, _ := st.Add(AddRequest{Content: validContent("child"), ParentID: &parent.ID})

	if _, err := st.Delete(parent.ID); err != nil {
		t.Fatal(err)
	}
	snap := st.Snapshot()
	if _, ok := snap.Tasks[child.ID]; !ok {
		t.Fatal("child should survive (non-cascade)")
	}
	for _, tk := range snap.Tasks {
		for _, c := range tk.Content.ChildIDs {
			if c == child.ID {
				t.Fatal("child should be unreferenced (a root) after parent delete")
			}
		}
	}
}

func TestDeleteUnknown(t *testing.T) {
	st := newTestStore(t)
	if _, err := st.Delete("ghost"); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}
