package main

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/time/rate"

	"seshat/internal/task"
)

// testAdminToken is >= 32 characters (spec §6.2), like a real deployment's.
const testAdminToken = "test-admin-token-test-admin-token-32+"

// testUser is one registered tenant plus the credential that reaches it.
type testUser struct {
	token string
	id    UserID
	tn    *tenant
	store *Store
}

// newTestServer returns a server over a fresh two-user registry: Alice and Bob.
//
// Each tenant mints ids from its OWN namespace ("a1","a2"… / "b1","b2"…). With a
// shared sequence Alice's first task and Bob's first task would both be "id1", and
// every cross-tenant test would pass for the wrong reason.
func newTestServer(t *testing.T) (*Server, testUser, testUser) {
	t.Helper()
	tn := openTestTenants(t)
	srv := NewServer(tn, testAdminToken, defaultRateLimit)

	mk := func(prefix string) testUser {
		t.Helper()
		tok, id, err := tn.Create()
		if err != nil {
			t.Fatalf("Create: %v", err)
		}
		tnt, ok := tn.Authenticate(tok)
		if !ok {
			t.Fatalf("Authenticate rejected a token it just minted")
		}
		// Same deterministic clock and counter as newTestStore.
		tnt.store.now = func() int64 { return 1000 }
		n := 0
		tnt.store.newID = func() string { n++; return prefix + strconv.Itoa(n) }
		return testUser{token: tok, id: id, tn: tnt, store: tnt.store}
	}
	return srv, mk("a"), mk("b")
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

// addTask POSTs one minimal task as u and returns the server's copy of it.
func addTask(t *testing.T, srv *Server, u testUser, title string) task.Task {
	t.Helper()
	rr := do(t, srv, "POST", "/api/tasks/add", u.token,
		`{"content":{"title":"`+title+`","status":"todo","priority":"none"}}`, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("add %q: expected 200, got %d: %s", title, rr.Code, rr.Body.String())
	}
	var resp struct {
		Task task.Task `json:"task"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("add %q: decode response: %v", title, err)
	}
	return resp.Task
}

// TestAuthMatrix pins the chokepoint: nothing reaches a route without a valid
// credential for THAT branch, and auth runs before routing, so an unknown path
// still answers 403 when unauthenticated.
func TestAuthMatrix(t *testing.T) {
	srv, alice, _ := newTestServer(t)

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf) // the admin rejections below each log; keep the test output clean
	defer log.SetOutput(prev)

	cases := []struct {
		name, method, path, token string
		want                      int
	}{
		{"user ok", "GET", "/api/tasks/get", alice.token, http.StatusOK},
		{"user wrong", "GET", "/api/tasks/get", "wrong", http.StatusForbidden},
		{"user empty", "GET", "/api/tasks/get", "", http.StatusForbidden},
		{"user token minus a byte", "GET", "/api/tasks/get", alice.token[:len(alice.token)-1], http.StatusForbidden},
		{"user token plus a byte", "GET", "/api/tasks/get", alice.token + "0", http.StatusForbidden},
		{"admin token on task path", "GET", "/api/tasks/get", testAdminToken, http.StatusForbidden},
		{"unknown task path, token", "GET", "/api/tasks/nope", alice.token, http.StatusNotFound},
		{"unknown task path, none", "GET", "/api/tasks/nope", "", http.StatusForbidden},
		{"root path, none", "GET", "/", "", http.StatusForbidden},
		// admin routes are POST-only (F2); the 403 rows below reach the auth check
		// before the method check, so they stay GET and must still be 403.
		{"admin ok", "POST", "/api/admin/users/list", testAdminToken, http.StatusOK},
		{"admin empty", "GET", "/api/admin/users/list", "", http.StatusForbidden},
		{"admin minus a byte", "GET", "/api/admin/users/list", testAdminToken[:len(testAdminToken)-1], http.StatusForbidden},
		{"admin plus a byte", "GET", "/api/admin/users/list", testAdminToken + "0", http.StatusForbidden},
		{"user token on admin path", "GET", "/api/admin/users/list", alice.token, http.StatusForbidden},
		{"unknown admin path, token", "GET", "/api/admin/nope", testAdminToken, http.StatusNotFound},
		{"unknown admin path, none", "GET", "/api/admin/nope", "", http.StatusForbidden},
	}
	for _, c := range cases {
		rr := do(t, srv, c.method, c.path, c.token, "", nil)
		if rr.Code != c.want {
			t.Errorf("%s: %s with %q: got %d, want %d (%s)", c.name, c.path, c.token, rr.Code, c.want, rr.Body.String())
			continue
		}
		body := strings.TrimSpace(rr.Body.String())
		switch c.want {
		case http.StatusForbidden:
			if body != `{"error":"access denied"}` {
				t.Errorf("%s: 403 body = %q", c.name, body)
			}
		case http.StatusNotFound:
			if body != `{"error":"not found"}` {
				t.Errorf("%s: 404 body = %q", c.name, body)
			}
		}
	}
}

func TestAdminAuthFailureIsLogged(t *testing.T) {
	srv, _, _ := newTestServer(t)

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	do(t, srv, "GET", "/api/admin/users/list", "wrong", "", nil)

	// httptest.NewRequest sets a fixed RemoteAddr.
	if !strings.Contains(buf.String(), "admin: auth failure from 192.0.2.1:1234") {
		t.Fatalf("expected an admin auth-failure log with the remote address, got %q", buf.String())
	}
	if strings.Contains(buf.String(), "wrong") {
		t.Fatalf("the presented credential was logged: %q", buf.String())
	}
}

func TestAdminAddListDelete(t *testing.T) {
	srv, alice, bob := newTestServer(t)

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	rr := do(t, srv, "POST", "/api/admin/users/add", testAdminToken, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("users/add: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf(`users/add Cache-Control = %q, want "no-store"`, got)
	}
	var added struct {
		ID    string `json:"id"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &added); err != nil {
		t.Fatalf("users/add: decode: %v", err)
	}
	if len(added.ID) != 32 || !isHex(added.ID) {
		t.Fatalf("users/add: id = %q, want 32 hex chars", added.ID)
	}
	if len(added.Token) != 64 || !isHex(added.Token) {
		t.Fatalf("users/add: token = %q, want 64 hex chars", added.Token)
	}
	if !strings.Contains(buf.String(), "admin: created user "+added.ID) {
		t.Fatalf("expected a creation log for %s, got %q", added.ID, buf.String())
	}
	if strings.Contains(buf.String(), added.Token) {
		t.Fatalf("the minted token was logged: %q", buf.String())
	}

	rr = do(t, srv, "POST", "/api/admin/users/list", testAdminToken, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("users/list: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), added.Token) {
		t.Fatalf("users/list leaked a token: %s", rr.Body.String())
	}
	var listed struct {
		IDs []string `json:"ids"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &listed); err != nil {
		t.Fatalf("users/list: decode: %v", err)
	}
	want := []string{alice.id.String(), bob.id.String(), added.ID}
	sort.Strings(want)
	got := append([]string(nil), listed.IDs...)
	if !sort.StringsAreSorted(listed.IDs) {
		t.Errorf("users/list ids are not sorted: %v", listed.IDs)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("users/list = %v, want %v", listed.IDs, want)
	}

	// The new user's token works on the task path.
	if rr := do(t, srv, "GET", "/api/tasks/get", added.Token, "", nil); rr.Code != http.StatusOK {
		t.Fatalf("new user's token on /api/tasks/get: got %d, want 200", rr.Code)
	}

	rr = do(t, srv, "POST", "/api/admin/users/delete", testAdminToken, `{"id":"`+added.ID+`"}`, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("users/delete: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"deleted":"`+added.ID+`"`) {
		t.Fatalf("users/delete body = %s", rr.Body.String())
	}
	if !strings.Contains(buf.String(), "admin: deleted user "+added.ID) {
		t.Fatalf("expected a deletion log for %s, got %q", added.ID, buf.String())
	}
	if rr := do(t, srv, "GET", "/api/tasks/get", added.Token, "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("deleted user's token: got %d, want 403", rr.Code)
	}

	rr = do(t, srv, "POST", "/api/admin/users/list", testAdminToken, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("users/list after delete: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), added.ID) {
		t.Fatalf("users/list still lists the deleted user: %s", rr.Body.String())
	}
}

func isHex(s string) bool {
	return s != "" && strings.Trim(s, "0123456789abcdef") == ""
}

// TestAdminMethodNotAllowed pins F2: an admin route rejects any method but POST,
// but only AFTER auth — a GET with no credential must still read as 403, not 405,
// so an unauthenticated caller learns nothing about which paths exist.
func TestAdminMethodNotAllowed(t *testing.T) {
	srv, _, _ := newTestServer(t)

	rr := do(t, srv, "GET", "/api/admin/users/add", testAdminToken, "", nil)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET users/add with admin token: expected 405, got %d: %s", rr.Code, rr.Body.String())
	}
	if got := strings.TrimSpace(rr.Body.String()); got != `{"error":"method not allowed"}` {
		t.Fatalf("405 body = %q", got)
	}
	if got := rr.Header().Get("Allow"); got != http.MethodPost {
		t.Fatalf("405 Allow header = %q, want %q", got, http.MethodPost)
	}

	rr = do(t, srv, "GET", "/api/admin/users/add", "", "", nil)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("GET users/add with no credential: expected 403 (auth precedes method check), got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAdminDeleteErrors(t *testing.T) {
	srv, _, _ := newTestServer(t)

	rr := do(t, srv, "POST", "/api/admin/users/delete", testAdminToken, `{"id":"zz"}`, nil)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("malformed id: expected 400, got %d: %s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "malformed user id") {
		t.Fatalf("malformed id: body = %s", rr.Body.String())
	}

	rr = do(t, srv, "POST", "/api/admin/users/delete", testAdminToken, `{"id":"`+strings.Repeat("0", 32)+`"}`, nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("unknown id: expected 404, got %d: %s", rr.Code, rr.Body.String())
	}

	rr = do(t, srv, "POST", "/api/admin/users/delete", testAdminToken, `not json`, nil)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("bad JSON: expected 400, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestGetReturnsETag(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", alice.token, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	if rr.Header().Get("ETag") != `"0"` {
		t.Fatalf(`expected ETag "0", got %q`, rr.Header().Get("ETag"))
	}
	if got := rr.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf(`Cache-Control = %q, want "no-store"`, got)
	}
	var resp struct {
		StateVersion uint64      `json:"state_version"`
		Tasks        []task.Task `json:"tasks"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp.StateVersion != 0 || len(resp.Tasks) != 0 {
		t.Fatalf("unexpected body: %+v", resp)
	}
}

func TestGetNotModified(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", alice.token, "", map[string]string{"If-None-Match": `"0"`})
	if rr.Code != http.StatusNotModified {
		t.Fatalf("expected 304, got %d", rr.Code)
	}
	if rr.Body.Len() != 0 {
		t.Fatal("expected empty body on 304")
	}
	if got := rr.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf(`304 Cache-Control = %q, want "no-store"`, got)
	}
}

func TestAddThenGet(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	rr := do(t, srv, "POST", "/api/tasks/add", alice.token, `{"content":{"title":"hi","status":"todo","priority":"none"}}`, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var resp struct {
		StateVersion uint64    `json:"state_version"`
		Task         task.Task `json:"task"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp.Task.ID == "" || resp.StateVersion != 1 {
		t.Fatalf("bad add response: %+v", resp)
	}
}

func TestAddBadInputIs400(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	rr := do(t, srv, "POST", "/api/tasks/add", alice.token, `{not json`, nil)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rr.Code)
	}
}

func TestUpdateConflictIs409(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	tk, _, _ := alice.store.Add(task.AddRequest{Content: task.Content{Title: "x", Status: task.StatusTodo, Priority: task.PriorityNone}})
	body := `{"updates":[{"id":"` + tk.ID + `","content":{"title":"y","status":"todo","priority":"none"},"expected_version":99}]}`
	rr := do(t, srv, "POST", "/api/tasks/update", alice.token, body, nil)
	if rr.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", rr.Code)
	}
	var resp struct {
		Conflicts []task.Task `json:"conflicts"`
	}
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if len(resp.Conflicts) != 1 {
		t.Fatalf("expected 1 conflict, got %+v", resp.Conflicts)
	}
}

func TestDeleteHandler(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	tk, _, _ := alice.store.Add(task.AddRequest{Content: task.Content{Title: "x", Status: task.StatusTodo, Priority: task.PriorityNone}})
	body := `{"id":"` + tk.ID + `"}`
	rr := do(t, srv, "POST", "/api/tasks/delete", alice.token, body, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
}

// One tenant's exhausted bucket must not touch another's.
func TestRateLimitIsPerTenant(t *testing.T) {
	srv, alice, bob := newTestServer(t)
	// Zero refill, single token: request 1 consumes it, request 2 must be rejected.
	alice.tn.limiter = rate.NewLimiter(0, 1)

	if rr := do(t, srv, "GET", "/api/tasks/get", alice.token, "", nil); rr.Code != http.StatusOK {
		t.Fatalf("first request should pass, got %d", rr.Code)
	}
	rr := do(t, srv, "GET", "/api/tasks/get", alice.token, "", nil)
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on second request, got %d", rr.Code)
	}
	var body map[string]string
	json.Unmarshal(rr.Body.Bytes(), &body)
	if body["error"] == "" {
		t.Fatalf("expected an error message in the 429 body, got %q", rr.Body.String())
	}
	if rr := do(t, srv, "GET", "/api/tasks/get", bob.token, "", nil); rr.Code != http.StatusOK {
		t.Fatalf("Alice's exhausted bucket blocked Bob: got %d, want 200", rr.Code)
	}
}

// The limiter must sit AFTER auth, so an unauthenticated flood cannot drain the
// bucket and lock out the legitimate user.
func TestRateLimitNotConsumedByUnauthenticatedRequests(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	alice.tn.limiter = rate.NewLimiter(0, 1)

	for i := 0; i < 5; i++ {
		if rr := do(t, srv, "GET", "/api/tasks/get", "wrong", "", nil); rr.Code != http.StatusForbidden {
			t.Fatalf("unauthenticated request %d: expected 403, got %d", i, rr.Code)
		}
	}
	// The single token must still be available to the authenticated user.
	if rr := do(t, srv, "GET", "/api/tasks/get", alice.token, "", nil); rr.Code != http.StatusOK {
		t.Fatalf("authenticated request after unauthenticated flood: expected 200, got %d", rr.Code)
	}
}

// The admin branch has the same ordering guarantee as the tenant branch.
func TestAdminRateLimit(t *testing.T) {
	srv, _, _ := newTestServer(t)
	srv.adminLimiter = rate.NewLimiter(0, 1)

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf) // the five failures below each log; keep the test output clean
	defer log.SetOutput(prev)

	for i := 0; i < 5; i++ {
		if rr := do(t, srv, "GET", "/api/admin/users/list", "wrong", "", nil); rr.Code != http.StatusForbidden {
			t.Fatalf("unauthenticated admin request %d: expected 403, got %d", i, rr.Code)
		}
	}
	if rr := do(t, srv, "POST", "/api/admin/users/list", testAdminToken, "", nil); rr.Code != http.StatusOK {
		t.Fatalf("admin request after unauthenticated flood: expected 200, got %d", rr.Code)
	}
	if rr := do(t, srv, "POST", "/api/admin/users/list", testAdminToken, "", nil); rr.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 once the single admin token is spent, got %d", rr.Code)
	}
}

// The limiter tests above override their limiters, so they would still pass if the
// wiring were wrong (swapped arguments, zero burst). Pin the wiring instead — for
// the admin bucket and for a tenant's, at the default rate and at a configured one.
func TestLimiterWiring(t *testing.T) {
	srv, alice, _ := newTestServer(t) // constructed with defaultRateLimit
	if got := srv.adminLimiter.Limit(); got != defaultRateLimit {
		t.Errorf("admin limiter rate = %v, want %v", got, float64(defaultRateLimit))
	}
	if got := srv.adminLimiter.Burst(); got != 2*defaultRateLimit {
		t.Errorf("admin limiter burst = %d, want %d", got, 2*defaultRateLimit)
	}
	if got := alice.tn.limiter.Limit(); got != defaultRateLimit {
		t.Errorf("tenant limiter rate = %v, want %v", got, float64(defaultRateLimit))
	}
	if got := alice.tn.limiter.Burst(); got != 2*defaultRateLimit {
		t.Errorf("tenant limiter burst = %d, want %d", got, 2*defaultRateLimit)
	}

	tn2, err := OpenTenants(filepath.Join(t.TempDir(), "x.db"), 50)
	if err != nil {
		t.Fatalf("OpenTenants: %v", err)
	}
	t.Cleanup(func() { tn2.Close() })
	srv2 := NewServer(tn2, testAdminToken, 50)
	if got := srv2.adminLimiter.Limit(); got != 50 {
		t.Errorf("admin limiter rate = %v, want 50", got)
	}
	if got := srv2.adminLimiter.Burst(); got != 100 {
		t.Errorf("admin limiter burst = %d, want 100", got)
	}
	tok, _, err := tn2.Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	u, ok := tn2.Authenticate(tok)
	if !ok {
		t.Fatal("Authenticate rejected a token it just minted")
	}
	if got := u.limiter.Limit(); got != 50 {
		t.Errorf("tenant limiter rate = %v, want 50", got)
	}
	if got := u.limiter.Burst(); got != 100 {
		t.Errorf("tenant limiter burst = %d, want 100", got)
	}
}

func TestOversizedBodyIs413NotBadRequest(t *testing.T) {
	srv, alice, _ := newTestServer(t)
	// A structurally VALID request that is simply too large — so a 400 here would
	// prove the size limit was misclassified as a JSON syntax error.
	huge := strings.Repeat("a", (1<<20)+1024)
	body := `{"content":{"title":"` + huge + `","status":"todo","priority":"none"}}`
	rr := do(t, srv, "POST", "/api/tasks/add", alice.token, body, nil)
	if rr.Code != http.StatusRequestEntityTooLarge {
		// Truncate: the response echoes the task, so the untruncated body would dump
		// more than a megabyte into the test log.
		snippet := rr.Body.String()
		if len(snippet) > 200 {
			snippet = snippet[:200] + "...(truncated)"
		}
		t.Fatalf("expected 413, got %d: %s", rr.Code, snippet)
	}
}
