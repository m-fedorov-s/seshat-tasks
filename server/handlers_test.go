package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/time/rate"
)

func newTestServer(t *testing.T) (*Server, *Store) {
	t.Helper()
	st, err := NewStore(filepath.Join(t.TempDir(), "data.json"))
	if err != nil {
		t.Fatal(err)
	}
	return NewServer(st, "s3cr3t", defaultRateLimit), st
}

func do(t *testing.T, srv *Server, method, path, secret, body string, hdr map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if secret != "" {
		req.Header.Set("Authorization", secret)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	return rr
}

func TestAuthRejected(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", "wrong", "", nil)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rr.Code)
	}
}

func TestGetReturnsETag(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3t", "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	if rr.Header().Get("ETag") != `"0"` {
		t.Fatalf(`expected ETag "0", got %q`, rr.Header().Get("ETag"))
	}
	var resp struct {
		StateVersion uint64 `json:"state_version"`
		Tasks        []Task `json:"tasks"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp.StateVersion != 0 || len(resp.Tasks) != 0 {
		t.Fatalf("unexpected body: %+v", resp)
	}
}

func TestGetNotModified(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3t", "", map[string]string{"If-None-Match": `"0"`})
	if rr.Code != http.StatusNotModified {
		t.Fatalf("expected 304, got %d", rr.Code)
	}
	if rr.Body.Len() != 0 {
		t.Fatal("expected empty body on 304")
	}
}

func TestAddThenGet(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "POST", "/api/tasks/add", "s3cr3t", `{"content":{"title":"hi","status":"todo","priority":"none"}}`, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var resp struct {
		StateVersion uint64 `json:"state_version"`
		Task         Task   `json:"task"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp.Task.ID == "" || resp.StateVersion != 1 {
		t.Fatalf("bad add response: %+v", resp)
	}
}

func TestAddBadInputIs400(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "POST", "/api/tasks/add", "s3cr3t", `{not json`, nil)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rr.Code)
	}
}

func TestUpdateConflictIs409(t *testing.T) {
	srv, st := newTestServer(t)
	task, _, _ := st.Add(AddRequest{Content: Content{Title: "x", Status: StatusTodo, Priority: PriorityNone}})
	body := `{"updates":[{"id":"` + task.ID + `","content":{"title":"y","status":"todo","priority":"none"},"expected_version":99}]}`
	rr := do(t, srv, "POST", "/api/tasks/update", "s3cr3t", body, nil)
	if rr.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", rr.Code)
	}
	var resp struct {
		Conflicts []Task `json:"conflicts"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if len(resp.Conflicts) != 1 {
		t.Fatalf("expected 1 conflict, got %+v", resp.Conflicts)
	}
}

func TestDeleteHandler(t *testing.T) {
	srv, st := newTestServer(t)
	task, _, _ := st.Add(AddRequest{Content: Content{Title: "x", Status: StatusTodo, Priority: PriorityNone}})
	body := `{"id":"` + task.ID + `"}`
	rr := do(t, srv, "POST", "/api/tasks/delete", "s3cr3t", body, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
}

func TestAuthEmptySecretRejected(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", "", "", nil)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for absent Authorization header, got %d", rr.Code)
	}
}

func TestAuthShorterSecretRejected(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3", "", nil)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for truncated secret, got %d", rr.Code)
	}
}

func TestAuthLongerSecretRejected(t *testing.T) {
	srv, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3t-extra", "", nil)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for over-long secret, got %d", rr.Code)
	}
}

func TestRateLimitReturns429(t *testing.T) {
	srv, _ := newTestServer(t)
	// Zero refill, single token: request 1 consumes it, request 2 must be rejected.
	srv.limiter = rate.NewLimiter(0, 1)

	if rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3t", "", nil); rr.Code != http.StatusOK {
		t.Fatalf("first request should pass, got %d", rr.Code)
	}
	rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3t", "", nil)
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on second request, got %d", rr.Code)
	}
	var body map[string]string
	json.Unmarshal(rr.Body.Bytes(), &body)
	if body["error"] == "" {
		t.Fatalf("expected an error message in the 429 body, got %q", rr.Body.String())
	}
}

// The limiter must sit AFTER auth, so an unauthenticated flood cannot drain the
// bucket and lock out the legitimate user.
func TestRateLimitNotConsumedByUnauthenticatedRequests(t *testing.T) {
	srv, _ := newTestServer(t)
	srv.limiter = rate.NewLimiter(0, 1)

	for i := 0; i < 5; i++ {
		if rr := do(t, srv, "GET", "/api/tasks/get", "wrong", "", nil); rr.Code != http.StatusForbidden {
			t.Fatalf("unauthenticated request %d: expected 403, got %d", i, rr.Code)
		}
	}
	// The single token must still be available to the authenticated user.
	if rr := do(t, srv, "GET", "/api/tasks/get", "s3cr3t", "", nil); rr.Code != http.StatusOK {
		t.Fatalf("authenticated request after unauthenticated flood: expected 200, got %d", rr.Code)
	}
}

// Both tests above override the limiter, so they would still pass if NewServer
// configured it wrongly (swapped arguments, zero burst). Pin the wiring instead.
func TestNewServerLimiterConfiguration(t *testing.T) {
	srv, _ := newTestServer(t) // constructed with defaultRateLimit
	if got := srv.limiter.Limit(); got != defaultRateLimit {
		t.Errorf("limiter rate = %v, want %v", got, float64(defaultRateLimit))
	}
	if got := srv.limiter.Burst(); got != 2*defaultRateLimit {
		t.Errorf("limiter burst = %d, want %d", got, 2*defaultRateLimit)
	}
}

// The threshold is configurable, so verify the value is actually plumbed through
// rather than hardcoded.
func TestNewServerHonoursConfiguredRate(t *testing.T) {
	st, err := NewStore(filepath.Join(t.TempDir(), "data.json"))
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(st, "s3cr3t", 50)
	if got := srv.limiter.Limit(); got != 50 {
		t.Errorf("limiter rate = %v, want 50", got)
	}
	if got := srv.limiter.Burst(); got != 100 {
		t.Errorf("limiter burst = %d, want 100", got)
	}
}
