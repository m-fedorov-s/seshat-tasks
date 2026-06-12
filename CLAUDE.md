# seshat

A personal task manager built as a **server + client** system. The server is the source of
truth; clients fetch task data from it.

## Layout

- `server/` — Go HTTP server (`package main`, split across `task.go` / `store.go` / `validate.go`
  / `handlers.go` / `main.go`). Stores tasks in memory, persisted to an atomic-rewrite JSON file,
  with a global `state_version`. Auth via a shared `secret` sent in the `Authorization` header.
  Config (secret, port, data_file) from YAML. Endpoints under `/api/tasks/` (`get`, `add`,
  `update`, `delete`). Optimistic concurrency via per-task `meta.version`.
- `schema/` — the shared `Task` contract: `task.schema.json`, `SCHEMA.md`, golden `fixtures/`.
  Enforced across server + client by `make schema-test`.
- `client/zig/` — the canonical client (Zig 0.16). See `client/zig/CLAUDE.md`.
- `client/fish/` — thin fish *integration* (completions/prompt, shelling out to the Zig binary),
  added in a later spec. The standalone fish client was retired.
- `plans/`, `docs/superpowers/` — design docs, specs, and implementation plans.

## Task model

A `Task` is `{ id (ULID), content, meta }`. `content` (user-editable) = title, description,
`status` (todo/in_progress/done/cancelled), `priority` (none/low/medium/high), `child_ids`
(ordered subtask ids — the hierarchy is a **forest**), tags, due_at, scheduled_at. `meta`
(server-owned) = created_at, updated_at, completed_at, version. See `schema/SCHEMA.md`.

## Client behaviour

The Zig client:
1. Reads config (server URL, secret) from JSON (`SESHAT_CONFIG` or `~/.config/seshat/config.json`).
2. On `show`, fetches all tasks from the server and renders the forest.
3. Supports `add <title> [priority]`, `delete <id>`, and `done <id>`, mutating via the server.

## Conventions

- The server is authoritative; clients must not assume local state is canonical.
- Auth is a plain shared secret in the `Authorization` header (no Bearer prefix).
