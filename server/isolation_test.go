package main

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"testing"
)

// isolation_test.go — spec §11 "handlers_test.go" cross-tenant rows.
//
// The two tenants mint ids from DISJOINT namespaces ("a1…" / "b1…") — newTestServer
// guarantees it. Without that, "Bob names Alice's id" is indistinguishable from "Bob
// names his own id" and every assertion in this file would pass for the wrong reason.

// stateVersion fetches a tenant's own state_version via GET /api/tasks/get.
func stateVersion(t *testing.T, srv *Server, u testUser) uint64 {
	t.Helper()
	rr := do(t, srv, "GET", "/api/tasks/get", u.token, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /api/tasks/get: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var body struct {
		StateVersion uint64 `json:"state_version"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode state_version: %v", err)
	}
	return body.StateVersion
}

// TestCrossTenantIdsAreNotFound pins that a task id is only meaningful inside the
// tenant that minted it: Bob cannot update, delete, or even see Alice's task by id,
// and Alice's copy is untouched by his attempts.
func TestCrossTenantIdsAreNotFound(t *testing.T) {
	srv, alice, bob := newTestServer(t)
	at := addTask(t, srv, alice, "alice's")

	rr := do(t, srv, "POST", "/api/tasks/update", bob.token,
		`{"updates":[{"id":"`+at.ID+`","expected_version":1,"content":{"title":"stolen","status":"todo","priority":"none"}}]}`, nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("Bob update Alice's task: expected 404, got %d: %s", rr.Code, rr.Body.String())
	}

	rr = do(t, srv, "POST", "/api/tasks/delete", bob.token, `{"id":"`+at.ID+`"}`, nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("Bob delete Alice's task: expected 404, got %d: %s", rr.Code, rr.Body.String())
	}

	// Bob owns a task of his own too: a positive control, so the absence of Alice's
	// id below proves the list is populated and filtered, not just empty.
	bt := addTask(t, srv, bob, "bob's")

	rr = do(t, srv, "GET", "/api/tasks/get", bob.token, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("Bob get: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !strings.Contains(body, bt.ID) || strings.Contains(body, at.ID) {
		t.Fatalf("Bob's task list should contain %s and not %s: %s", bt.ID, at.ID, body)
	}

	if got := alice.store.Snapshot().Tasks[at.ID].Content.Title; got != "alice's" {
		t.Fatalf("Alice's task was mutated by Bob's failed attempts: title = %q", got)
	}
}

// TestCrossTenantReferencesAreRejectedWithoutSideEffects pins that a cross-tenant
// reference is rejected before either store is touched, whether it's used as a
// parent_id on add or planted in child_ids on update.
func TestCrossTenantReferencesAreRejectedWithoutSideEffects(t *testing.T) {
	srv, alice, bob := newTestServer(t)
	at := addTask(t, srv, alice, "alice's")
	bt := addTask(t, srv, bob, "bob's")
	svA, svB := stateVersion(t, srv, alice), stateVersion(t, srv, bob)

	// Bob adds a child under Alice's task: the parent lookup is inside Bob's store
	// only, so Alice's id is simply not found there.
	rr := do(t, srv, "POST", "/api/tasks/add", bob.token,
		`{"content":{"title":"x","status":"todo","priority":"none"},"parent_id":"`+at.ID+`"}`, nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("Bob add under Alice's task: expected 404, got %d: %s", rr.Code, rr.Body.String())
	}

	// Bob names Alice's id in child_ids: it exists (in Alice's store, not his), so
	// this trips the dangling_child invariant rather than a plain not-found.
	rr = do(t, srv, "POST", "/api/tasks/update", bob.token,
		`{"updates":[{"id":"`+bt.ID+`","expected_version":1,"content":{"title":"bob's","status":"todo","priority":"none","child_ids":["`+at.ID+`"]}}]}`, nil)
	if rr.Code != http.StatusUnprocessableEntity {
		t.Fatalf("Bob's dangling child_ids: expected 422, got %d: %s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "dangling_child") {
		t.Fatalf("expected dangling_child in body, got %s", rr.Body.String())
	}

	// Neither side moved: no partial mutation leaked out of either rejected request.
	if got := stateVersion(t, srv, alice); got != svA {
		t.Fatalf("Alice's state_version moved: got %d, want %d", got, svA)
	}
	if got := stateVersion(t, srv, bob); got != svB {
		t.Fatalf("Bob's state_version moved: got %d, want %d", got, svB)
	}
	if got := alice.store.Snapshot().Tasks[at.ID].Meta.Version; got != 1 {
		t.Fatalf("Alice's task version moved: got %d, want 1", got)
	}
	bobTask := bob.store.Snapshot().Tasks[bt.ID]
	if bobTask.Meta.Version != 1 {
		t.Fatalf("Bob's task version moved: got %d, want 1", bobTask.Meta.Version)
	}
	if len(bobTask.Content.ChildIDs) != 0 {
		t.Fatalf("Bob's task acquired a child: %v", bobTask.Content.ChildIDs)
	}
}

// TestETagIsPerTenant pins that handleGet's ETag is derived from the CALLING
// tenant's own state_version: Alice writing does not move Bob's ETag, a 304 still
// works against Bob's own cached value, and the two tenants' ETags differ. If the
// server aliased the two stores, Alice's write would move Bob's ETag too.
func TestETagIsPerTenant(t *testing.T) {
	srv, alice, bob := newTestServer(t)
	rr := do(t, srv, "GET", "/api/tasks/get", bob.token, "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("Bob's initial get: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	bobETag := rr.Header().Get("ETag")
	if bobETag == "" {
		t.Fatalf("Bob's initial get returned no ETag")
	}

	addTask(t, srv, alice, "alice writes")

	if got := do(t, srv, "GET", "/api/tasks/get", bob.token, "", nil).Header().Get("ETag"); got != bobETag {
		t.Fatalf("Bob's ETag moved after Alice's write: got %q, want %q", got, bobETag)
	}
	rr = do(t, srv, "GET", "/api/tasks/get", bob.token, "", map[string]string{"If-None-Match": bobETag})
	if rr.Code != http.StatusNotModified {
		t.Fatalf("Bob's If-None-Match against his own ETag: expected 304, got %d", rr.Code)
	}
	if got := do(t, srv, "GET", "/api/tasks/get", alice.token, "", nil).Header().Get("ETag"); got == bobETag {
		t.Fatalf("Alice's ETag equals Bob's stale ETag: %q", got)
	}
}

// TestDeletedUserTokenIsRejectedImmediately pins that admin deletion revokes a
// token's access on the very next request, and only that user's.
func TestDeletedUserTokenIsRejectedImmediately(t *testing.T) {
	srv, alice, bob := newTestServer(t)
	addTask(t, srv, alice, "a")

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf) // users/delete logs; keep the test output clean
	defer log.SetOutput(prev)

	rr := do(t, srv, "POST", "/api/admin/users/delete", testAdminToken, `{"id":"`+alice.id.String()+`"}`, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete Alice: expected 200, got %d: %s", rr.Code, rr.Body.String())
	}

	if rr := do(t, srv, "GET", "/api/tasks/get", alice.token, "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("Alice's token after her own deletion: expected 403, got %d", rr.Code)
	}
	if rr := do(t, srv, "GET", "/api/tasks/get", bob.token, "", nil); rr.Code != http.StatusOK {
		t.Fatalf("Bob affected by Alice's deletion: expected 200, got %d", rr.Code)
	}
}

// TestDotSegmentsDoNotCrossBranches pins the architecture note in handlers.go: there
// is no ServeMux anywhere, so neither branch cleans or decodes the path. A
// dot-segment or percent-encoded path is looked up EXACTLY as sent and misses its
// branch's route table. The property under test: a credential valid on one branch
// never yields the other branch's data, and nothing at all is answered without one.
func TestDotSegmentsDoNotCrossBranches(t *testing.T) {
	srv, alice, _ := newTestServer(t)

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf) // the admin-branch auth failures below each log; keep the test output clean
	defer log.SetOutput(prev)

	// prefix picks the admin branch (starts with "/api/admin/"); admin auth passes;
	// the uncleaned path is not a route -> 404, no task data.
	rr := do(t, srv, "GET", "/api/admin/../tasks/get", testAdminToken, "", nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("admin token on dot-segment path: expected 404, got %d: %s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), `"tasks"`) {
		t.Fatalf("dot-segment path leaked task data: %s", rr.Body.String())
	}
	// a user token on the admin branch: still 403, dot segments don't help it either.
	if rr := do(t, srv, "GET", "/api/admin/../tasks/get", alice.token, "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("user token on dot-segment admin path: expected 403, got %d", rr.Code)
	}

	// prefix picks the tenant branch (does not start with "/api/admin/"); user auth
	// passes; the uncleaned path is not a route -> 404, no user ids.
	rr = do(t, srv, "GET", "/api/tasks/../admin/users/list", alice.token, "", nil)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("user token on dot-segment path: expected 404, got %d: %s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), `"ids"`) {
		t.Fatalf("dot-segment path leaked user ids: %s", rr.Body.String())
	}
	// nothing at all is answered without a credential.
	if rr := do(t, srv, "GET", "/api/tasks/../admin/users/list", "", "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("no credential on dot-segment path: expected 403, got %d", rr.Code)
	}
	// subtree root without its trailing slash: does not match the "/api/admin/"
	// prefix, so it lands on the tenant branch -> 403, no redirect (no ServeMux).
	if rr := do(t, srv, "GET", "/api/admin", "", "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("admin subtree root, no credential: expected 403, got %d", rr.Code)
	}
	// double slash: "//api/admin/users/list" does not have the "/api/admin/" prefix
	// (it starts with "//"), so it lands on the tenant branch and an admin token
	// there is just the wrong credential.
	if rr := do(t, srv, "GET", "//api/admin/users/list", testAdminToken, "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("double-slash admin path with admin token: expected 403, got %d", rr.Code)
	}
	// percent-encoded variants are NOT decoded before the prefix check (EscapedPath),
	// so they too miss the "/api/admin/" prefix and land on the tenant branch, where
	// the admin token is simply the wrong credential.
	if rr := do(t, srv, "GET", "/api/%61dmin/users/list", testAdminToken, "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("percent-encoded 'a' in admin path with admin token: expected 403, got %d", rr.Code)
	}
	if rr := do(t, srv, "GET", "/api/admin%2fusers/list", testAdminToken, "", nil); rr.Code != http.StatusForbidden {
		t.Fatalf("percent-encoded slash in admin path with admin token: expected 403, got %d", rr.Code)
	}
}

// TestAdminBodyCap pins that MaxBytesHandler sits outermost and covers the admin
// branch too, not just the tenant branch.
func TestAdminBodyCap(t *testing.T) {
	srv, _, _ := newTestServer(t)
	body := `{"id":"` + strings.Repeat("a", (1<<20)+1024) + `"}`
	rr := do(t, srv, "POST", "/api/admin/users/delete", testAdminToken, body, nil)
	if rr.Code != http.StatusRequestEntityTooLarge {
		snippet := rr.Body.String()
		if len(snippet) > 200 {
			snippet = snippet[:200] + "...(truncated)"
		}
		t.Fatalf("oversized admin body: expected 413, got %d: %s", rr.Code, snippet)
	}
}
