package task

import (
	"encoding/json"
	"testing"
)

func TestStatusValid(t *testing.T) {
	valid := []Status{StatusTodo, StatusInProgress, StatusDone, StatusCancelled}
	for _, s := range valid {
		if !s.Valid() {
			t.Errorf("expected %q valid", s)
		}
	}
	if Status("bogus").Valid() {
		t.Error("expected bogus status invalid")
	}
}

func TestPriorityValid(t *testing.T) {
	for _, p := range []Priority{PriorityNone, PriorityLow, PriorityMedium, PriorityHigh} {
		if !p.Valid() {
			t.Errorf("expected %q valid", p)
		}
	}
	if Priority("bogus").Valid() {
		t.Error("expected bogus priority invalid")
	}
}

func TestTaskJSONRoundTrip(t *testing.T) {
	due := int64(1718200000)
	in := Task{
		ID: "01J9Z3K7QABCDEF0123456789",
		Content: Content{
			Title: "Prepare omelet", Description: "", Status: StatusTodo, Priority: PriorityMedium,
			ChildIDs: []string{"01J...A"}, Tags: []string{"cooking"}, DueAt: &due, ScheduledAt: nil,
		},
		Meta: Meta{CreatedAt: 1718100000, UpdatedAt: 1718100000, CompletedAt: nil, Version: 3},
	}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out Task
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out.ID != in.ID || out.Content.Title != in.Content.Title || out.Meta.Version != 3 {
		t.Fatalf("round trip mismatch: %+v", out)
	}
	if out.Content.DueAt == nil || *out.Content.DueAt != due {
		t.Fatal("due_at lost in round trip")
	}
	if out.Content.ScheduledAt != nil {
		t.Fatal("scheduled_at should be nil")
	}
}
