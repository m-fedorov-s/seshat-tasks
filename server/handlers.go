package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"golang.org/x/time/rate"
)

// defaultRateLimit is the requests-per-second ceiling when config omits one.
// Generous: no interactive CLI use comes near it with a handful of clients, so it
// only trips on an actual flood. Global for now — with one shared secret, per-token
// IS global. Stage 2 makes it a per-user lookup.
const defaultRateLimit = 10

type Server struct {
	store *Store
	// secretHash is sha256(secret), precomputed once so the per-request compare is
	// over fixed-size digests. Hashing both sides closes the length leak that a raw
	// subtle.ConstantTimeCompare would still have (it returns early on length
	// mismatch). Stage 3 will read this digest from config instead of computing it.
	secretHash [32]byte
	limiter    *rate.Limiter
}

func NewServer(store *Store, secret string, ratePerSecond int) *Server {
	return &Server{
		store:      store,
		secretHash: sha256.Sum256([]byte(secret)),
		limiter:    rate.NewLimiter(rate.Limit(ratePerSecond), 2*ratePerSecond),
	}
}

// Handler returns the full middleware chain. The ORDER IS LOAD-BEARING — see
// docs/superpowers/specs/2026-07-29-stage-0-hardening-design.md §2.1. In particular
// auth runs BEFORE the rate limiter so that unauthenticated traffic cannot exhaust
// the bucket and lock the real user out.
func (s *Server) Handler() http.Handler {
	return s.auth(s.rateLimit(s.mux()))
}

func (s *Server) mux() *http.ServeMux {
	m := http.NewServeMux()
	m.HandleFunc("/api/tasks/get", s.handleGet)
	m.HandleFunc("/api/tasks/add", s.handleAdd)
	m.HandleFunc("/api/tasks/update", s.handleUpdate)
	m.HandleFunc("/api/tasks/delete", s.handleDelete)
	return m
}

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		presented := sha256.Sum256([]byte(r.Header.Get("Authorization")))
		if subtle.ConstantTimeCompare(presented[:], s.secretHash[:]) != 1 {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "access denied"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// rateLimit guards the expensive paths: handleGet deep-copies the whole task map on
// every call (cloneState), and every write fsyncs and rewrites the entire JSON file.
// It runs after auth deliberately; see Handler.
func (s *Server) rateLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.limiter.Allow() {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate limited"})
			return
		}
		next.ServeHTTP(w, r)
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
	switch {
	case errors.As(err, &ve):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": ve.Msg})
	case errors.As(err, &ce):
		writeJSON(w, http.StatusConflict, map[string]any{"conflicts": ce.Conflicts})
	case errors.As(err, &ie):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error": ie.Error(), "invariant": ie.Invariant, "ids": ie.IDs,
		})
	case errors.Is(err, ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
}

func (s *Server) handleGet(w http.ResponseWriter, r *http.Request) {
	snap := s.store.Snapshot()
	etag := `"` + strconv.FormatUint(snap.StateVersion, 10) + `"`
	// Per RFC 9110 a 304 must also carry the ETag, so set it before branching.
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	tasks := make([]Task, 0, len(snap.Tasks))
	for _, t := range snap.Tasks {
		tasks = append(tasks, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": snap.StateVersion, "tasks": tasks})
}

func (s *Server) handleAdd(w http.ResponseWriter, r *http.Request) {
	var req AddRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, &ValidationError{"invalid JSON: " + err.Error()})
		return
	}
	task, sv, err := s.store.Add(req)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": sv, "task": task})
}

func (s *Server) handleUpdate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Updates []UpdateOp `json:"updates"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, &ValidationError{"invalid JSON: " + err.Error()})
		return
	}
	tasks, sv, err := s.store.Update(req.Updates)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": sv, "tasks": tasks})
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, &ValidationError{"invalid JSON: " + err.Error()})
		return
	}
	sv, err := s.store.Delete(req.ID)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state_version": sv, "deleted": req.ID})
}
