package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"golang.org/x/time/rate"

	"seshat/internal/task"
)

// defaultRateLimit is the requests-per-second ceiling when config omits one, applied
// per user (and once more to the admin branch). Generous: no interactive client comes
// near it; it only trips on an actual flood, and one user's flood cannot lock out
// another.
const defaultRateLimit = 10

// maxBodyBytes caps request bodies. Without it, a single POST with a huge title is
// accepted, held in memory for the process lifetime, and re-serialized to disk on
// every subsequent write.
const maxBodyBytes = 1 << 20 // 1 MiB

type Server struct {
	tenants *Tenants
	// adminHash is sha256(admin_token), precomputed once so the per-request compare
	// is over fixed-size digests. Hashing both sides closes the length leak that a
	// raw subtle.ConstantTimeCompare would still have (it returns early on length
	// mismatch).
	adminHash    [32]byte
	adminLimiter *rate.Limiter
	// No *Store field, by design (spec D1): a handler gets its store only from
	// tenantBranch, i.e. only after a token has resolved to exactly one tenant.
}

func NewServer(tenants *Tenants, adminToken string, ratePerSecond int) *Server {
	return &Server{
		tenants:      tenants,
		adminHash:    sha256.Sum256([]byte(adminToken)),
		adminLimiter: newLimiter(ratePerSecond),
	}
}

// Handler returns the full chain. The ORDER IS LOAD-BEARING — see
// docs/superpowers/specs/2026-07-29-stage-0-hardening-design.md §2.1. The body cap is
// outermost so it covers both branches; on each branch auth runs BEFORE the rate
// limiter, so unauthenticated traffic cannot drain a bucket and lock the real user
// out, and BEFORE routing, so an unknown path never answers without a credential.
// Deliberately NOT an http.ServeMux: a mux cleans dot-segments and answers 301/307
// before any handler runs — that is, before auth.
func (s *Server) Handler() http.Handler {
	admin := s.adminBranch()
	tenant := s.tenantBranch()
	return http.MaxBytesHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// EscapedPath, not Path: Path is percent-decoded, so "/api/%61dmin/" would
		// take the tenant branch here and the admin route table there.
		if strings.HasPrefix(r.URL.EscapedPath(), "/api/admin/") {
			admin.ServeHTTP(w, r)
			return
		}
		tenant.ServeHTTP(w, r)
	}), maxBodyBytes)
}

// taskHandler is a task endpoint: it never chooses a store, it is handed one.
type taskHandler func(w http.ResponseWriter, r *http.Request, st *Store)

// tenantBranch is the chokepoint (spec §3.3): the presented token resolves to one
// tenant, and that tenant's Store is the only one a handler can see. A hand-rolled
// route table rather than a ServeMux so auth precedes routing without stashing the
// tenant in a context value.
func (s *Server) tenantBranch() http.Handler {
	routes := map[string]taskHandler{
		"/api/tasks/get":    handleGet,
		"/api/tasks/add":    handleAdd,
		"/api/tasks/update": handleUpdate,
		"/api/tasks/delete": handleDelete,
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tn, ok := s.tenants.Authenticate(r.Header.Get("Authorization"))
		if !ok {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "access denied"})
			return
		}
		// Per tenant: handleGet deep-copies the whole task map on every call, and
		// every write fsyncs. One user's flood must not cost another anything.
		if !tn.limiter.Allow() {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate limited"})
			return
		}
		h, ok := routes[r.URL.EscapedPath()] // exactly as sent: no cleaning, no decoding
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		h(w, r, tn.store)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if v != nil {
		json.NewEncoder(w).Encode(v)
	}
}

// writeErr maps domain errors to HTTP status codes + bodies (§5.5).
func writeErr(w http.ResponseWriter, err error) {
	var ve *ValidationError
	var ce *ConflictError
	var ie *InvariantError
	var te *TooLargeError
	switch {
	case errors.As(err, &ve):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": ve.Msg})
	case errors.As(err, &ce):
		writeJSON(w, http.StatusConflict, map[string]any{"conflicts": ce.Conflicts})
	case errors.As(err, &ie):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error": ie.Error(), "invariant": ie.Invariant, "ids": ie.IDs,
		})
	case errors.As(err, &te):
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": te.Error()})
	case errors.Is(err, ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
}

// decodeErr classifies a request-decode failure. MaxBytesReader's error arrives
// through json.Decode, so it must be detected BEFORE the generic "invalid JSON"
// wrapping or an oversized body reports as 400.
func decodeErr(err error) error {
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		return &TooLargeError{}
	}
	return &ValidationError{"invalid JSON: " + err.Error()}
}

func handleGet(w http.ResponseWriter, r *http.Request, st *Store) {
	snap := st.Snapshot()
	etag := `"` + strconv.FormatUint(snap.StateVersion, 10) + `"`
	// Per RFC 9110 a 304 must also carry the ETag, so set it before branching.
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	tasks := make([]task.Task, 0, len(snap.Tasks))
	for _, t := range snap.Tasks {
		tasks = append(tasks, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": snap.StateVersion, "tasks": tasks})
}

func handleAdd(w http.ResponseWriter, r *http.Request, st *Store) {
	var req task.AddRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, decodeErr(err))
		return
	}
	tk, sv, err := st.Add(req)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": sv, "task": tk})
}

func handleUpdate(w http.ResponseWriter, r *http.Request, st *Store) {
	var req struct {
		Updates []task.UpdateOp `json:"updates"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, decodeErr(err))
		return
	}
	tasks, sv, err := st.Update(req.Updates)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": sv, "tasks": tasks})
}

func handleDelete(w http.ResponseWriter, r *http.Request, st *Store) {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, decodeErr(err))
		return
	}
	sv, err := st.Delete(req.ID)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": sv, "deleted": req.ID})
}
