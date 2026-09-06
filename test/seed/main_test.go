package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"seshat/internal/task"
)

// TestPostAddRetries429 pins F1: a 429 must not be fatal. The seeder's per-task
// helper (postAdd) retries the SAME request until the server stops throttling it,
// rather than dying and leaving the account half-seeded.
func TestPostAddRetries429(t *testing.T) {
	const throttled = 3 // number of 429s before the server accepts the request

	var requests int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt64(&requests, 1)
		if n <= throttled {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusTooManyRequests)
			json.NewEncoder(w).Encode(map[string]string{"error": "rate limited"})
			return
		}
		resp := addResponse{
			StateVersion: 1,
			Task: task.Task{
				ID: "01ABCDEFGHJKMNPQRSTVWXYZ0",
				Content: task.Content{
					Title:    "hi",
					Status:   task.StatusTodo,
					Priority: task.PriorityNone,
				},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	client := &http.Client{}
	req := task.AddRequest{Content: task.Content{Title: "hi", Status: task.StatusTodo, Priority: task.PriorityNone}}

	tk, err := postAdd(client, srv.URL, "test-token", req)
	if err != nil {
		t.Fatalf("postAdd: %v", err)
	}
	if tk.ID != "01ABCDEFGHJKMNPQRSTVWXYZ0" {
		t.Fatalf("postAdd returned task %+v, want id 01ABCDEFGHJKMNPQRSTVWXYZ0", tk)
	}
	if got := atomic.LoadInt64(&requests); got != throttled+1 {
		t.Fatalf("server saw %d requests, want %d (throttled+1)", got, throttled+1)
	}
}

// TestPostAddNonRetryableError pins the other half: any non-200, non-429 status
// dies immediately, with no retry.
func TestPostAddNonRetryableError(t *testing.T) {
	var requests int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&requests, 1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid JSON: boom"})
	}))
	defer srv.Close()

	client := &http.Client{}
	req := task.AddRequest{Content: task.Content{Title: "hi", Status: task.StatusTodo, Priority: task.PriorityNone}}

	_, err := postAdd(client, srv.URL, "test-token", req)
	if err == nil {
		t.Fatal("postAdd: expected an error, got nil")
	}
	if got := atomic.LoadInt64(&requests); got != 1 {
		t.Fatalf("server saw %d requests, want exactly 1 (no retry on non-429)", got)
	}
}
