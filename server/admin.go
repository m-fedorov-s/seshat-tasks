package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
)

// The admin branch: user lifecycle, nothing else. It holds *Tenants and never a
// *Store (spec D3) — an operator token can create and destroy users, but cannot
// read or write anybody's tasks.

func (s *Server) adminAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		presented := sha256.Sum256([]byte(r.Header.Get("Authorization")))
		if subtle.ConstantTimeCompare(presented[:], s.adminHash[:]) != 1 {
			// The address only. Never the presented credential: a near-miss in the
			// log is a working credential for whoever reads the log.
			log.Printf("admin: auth failure from %s", r.RemoteAddr)
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "access denied"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) adminRateLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.adminLimiter.Allow() {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate limited"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// adminBranch mirrors tenantBranch: auth -> limiter -> route table, no ServeMux,
// and a JSON 404 that is only reachable once the admin token has checked out.
//
// The method IS enforced here (spec's tables say POST), but only after auth and
// the route lookup: a GET with no credential must still read as "access denied",
// not "method not allowed" — the latter would confirm the path exists to an
// unauthenticated caller.
func (s *Server) adminBranch() http.Handler {
	routes := map[string]http.HandlerFunc{
		"/api/admin/users/add":    s.handleUserAdd,
		"/api/admin/users/list":   s.handleUserList,
		"/api/admin/users/delete": s.handleUserDelete,
	}
	return s.adminAuth(s.adminRateLimit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h, ok := routes[r.URL.EscapedPath()] // exactly as sent, like the task branch
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		h(w, r)
	})))
}

// handleUserAdd registers a user. The response body is the only time the minted
// token exists in plaintext anywhere — it is not stored and not logged.
func (s *Server) handleUserAdd(w http.ResponseWriter, r *http.Request) {
	tok, id, err := s.tenants.Create()
	if err != nil {
		writeErr(w, err)
		return
	}
	log.Printf("admin: created user %s", id)
	writeJSON(w, http.StatusOK, map[string]string{"id": id.String(), "token": tok})
}

func (s *Server) handleUserList(w http.ResponseWriter, r *http.Request) {
	ids := s.tenants.List() // already sorted
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		out = append(out, id.String())
	}
	writeJSON(w, http.StatusOK, map[string]any{"ids": out})
}

func (s *Server) handleUserDelete(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, decodeErr(err))
		return
	}
	id, err := parseUserID(req.ID)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed user id"})
		return
	}
	// ErrUserNotFound wraps ErrNotFound, so writeErr renders it as 404 "not found".
	if err := s.tenants.Delete(id); err != nil {
		writeErr(w, err)
		return
	}
	log.Printf("admin: deleted user %s", id)
	writeJSON(w, http.StatusOK, map[string]string{"deleted": id.String()})
}
