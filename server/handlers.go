package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
)

type Server struct {
	store  *Store
	secret string
}

func (s *Server) mux() *http.ServeMux {
	m := http.NewServeMux()
	m.HandleFunc("/api/tasks/get", s.auth(s.handleGet))
	m.HandleFunc("/api/tasks/add", s.auth(s.handleAdd))
	m.HandleFunc("/api/tasks/update", s.auth(s.handleUpdate))
	m.HandleFunc("/api/tasks/delete", s.auth(s.handleDelete))
	return m
}

func (s *Server) auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != s.secret {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "access denied"})
			return
		}
		h(w, r)
	}
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
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	tasks := make([]Task, 0, len(snap.Tasks))
	for _, t := range snap.Tasks {
		tasks = append(tasks, t)
	}
	w.Header().Set("ETag", etag)
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
