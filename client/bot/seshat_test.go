package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"seshat/internal/task"
)

func TestGetSendsBareAuthHeaderAndDecodes(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		if r.URL.Path != "/api/tasks/get" {
			t.Errorf("path = %q", r.URL.Path)
		}
		json.NewEncoder(w).Encode(map[string]any{
			"state_version": 7,
			"tasks": []task.Task{
				{ID: "a", Content: task.Content{Title: "one", Status: task.StatusTodo}},
			},
		})
	}))
	defer srv.Close()

	got, err := NewClient(srv.URL).Get(context.Background(), "sekrit")
	if err != nil {
		t.Fatal(err)
	}
	// No "Bearer " prefix — the seshat contract is a bare shared secret.
	if gotAuth != "sekrit" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "sekrit")
	}
	if len(got) != 1 || got[0].ID != "a" {
		t.Fatalf("decoded %+v", got)
	}
}

func TestAddReturnsServerTask(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req task.AddRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.Content.Title != "new" {
			t.Errorf("title = %q", req.Content.Title)
		}
		if req.ParentID != nil {
			t.Error("v1 never sets parent_id")
		}
		json.NewEncoder(w).Encode(map[string]any{
			"state_version": 1,
			"task":          task.Task{ID: "z", Content: req.Content, Meta: task.Meta{Version: 1}},
		})
	}))
	defer srv.Close()

	got, err := NewClient(srv.URL).Add(context.Background(), "s",
		task.AddRequest{Content: task.Content{Title: "new", Status: task.StatusTodo, Priority: task.PriorityNone}})
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "z" || got.Meta.Version != 1 {
		t.Fatalf("got %+v", got)
	}
}

func TestUpdateSendsOpsAndDecodesTasks(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Updates []task.UpdateOp `json:"updates"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		if len(body.Updates) != 1 || body.Updates[0].ExpectedVersion != 4 {
			t.Errorf("ops = %+v", body.Updates)
		}
		json.NewEncoder(w).Encode(map[string]any{
			"state_version": 9,
			"tasks":         []task.Task{{ID: "a", Meta: task.Meta{Version: 5}}},
		})
	}))
	defer srv.Close()

	got, err := NewClient(srv.URL).Update(context.Background(), "s",
		[]task.UpdateOp{{ID: "a", ExpectedVersion: 4}})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Meta.Version != 5 {
		t.Fatalf("got %+v", got)
	}
}

func TestErrorStatusMapping(t *testing.T) {
	cases := []struct {
		status int
		body   string
		want   string // expected APIError.Msg
	}{
		{http.StatusBadRequest, `{"error":"title must be non-empty"}`, "title must be non-empty"},
		{http.StatusForbidden, `{"error":"access denied"}`, "access denied"},
		{http.StatusNotFound, `{"error":"not found"}`, "not found"},
		{http.StatusTooManyRequests, `{"error":"rate limited"}`, "rate limited"},
		{http.StatusUnprocessableEntity, `{"error":"cycle detected","invariant":"cycle"}`, "cycle detected"},
		// 409 carries NO "error" key — handlers.go:102 writes {"conflicts":[...]}.
		// The decoder must tolerate that and not report an empty message.
		{http.StatusConflict, `{"conflicts":[{"id":"a"}]}`, "version conflict"},
		// A truncated or empty body must not panic or produce "".
		{http.StatusInternalServerError, ``, "server error"},
		{http.StatusBadGateway, `not json at all`, "server error"},
	}
	for _, c := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(c.status)
			w.Write([]byte(c.body))
		}))
		_, err := NewClient(srv.URL).Get(context.Background(), "s")
		srv.Close()

		var ae *APIError
		if !errorsAs(err, &ae) {
			t.Errorf("status %d: want *APIError, got %v", c.status, err)
			continue
		}
		if ae.Status != c.status {
			t.Errorf("status %d: APIError.Status = %d", c.status, ae.Status)
		}
		if ae.Msg != c.want {
			t.Errorf("status %d: Msg = %q, want %q", c.status, ae.Msg, c.want)
		}
	}
}

func TestDeleteHitsEndpoint(t *testing.T) {
	var gotID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"id"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		gotID = body.ID
		json.NewEncoder(w).Encode(map[string]any{"state_version": 2, "deleted": body.ID})
	}))
	defer srv.Close()

	if err := NewClient(srv.URL).Delete(context.Background(), "s", "abc"); err != nil {
		t.Fatal(err)
	}
	if gotID != "abc" {
		t.Errorf("deleted id = %q", gotID)
	}
}

func errorsAs(err error, target **APIError) bool {
	for err != nil {
		if ae, ok := err.(*APIError); ok {
			*target = ae
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}
