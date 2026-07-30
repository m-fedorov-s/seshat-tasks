# seshat

A personal task manager built as a **server + client** system. The server is the source of
truth; clients fetch task data from it.

## Commands

```sh
make server-test              # Go server tests
make schema-test              # shared Task-contract tests (Go + Zig halves)
make client-integration-test  # spawns a real server + client through a pipe
cd client/zig && zig build test   # Zig client unit tests

make dev-server               # run a local server (dev/ config)
make dev-seed                 # load a realistic dataset into it
```

All four test targets must pass before any commit.

## Layout

- `server/` — Go HTTP server (`package main`, split across `task.go` / `store.go` / `validate.go`
  / `handlers.go` / `main.go`). Stores tasks in memory, persisted to an atomic-rewrite JSON file,
  with a global `state_version`. Auth via a shared `secret` sent in the `Authorization` header.
  Config (secret, port, data_file, bind, rate_limit) from YAML — `bind` defaults to `127.0.0.1`;
  `rate_limit` defaults to 10 req/s with burst 2x. Endpoints under `/api/tasks/` (`get`, `add`,
  `update`, `delete`). Optimistic concurrency via per-task `meta.version`. Requests pass through
  `MaxBytesHandler → auth → rateLimit → mux`. Two distinct version fields: `state_version`
  (concurrency counter / ETag, bumped per mutation) and the data file's `data_format_version`
  (on-disk format generation, currently 1 — the server refuses to start on a higher one). Do not
  conflate them.
- `schema/` — the shared `Task` contract: `task.schema.json`, `SCHEMA.md`, golden `fixtures/`.
  Enforced across server + client by `make schema-test`.
- `client/zig/` — the canonical client (Zig 0.16). See `client/zig/CLAUDE.md`.
- `client/fish/` — **placeholder README only**; the standalone fish client was retired and the
  shell integration (completions/prompt) is not built yet. See `plans/roadmap.md` → Stage 3.
- `test/` — integration tests needing a real server + client (`make client-integration-test`).
- `dev/` — local dev environment: a throwaway server/client config + scripts to run the server,
  seed a realistic dataset, and run the client (see `dev/README.md`; `make dev-server`/`dev-seed`).
- `plans/`, `docs/superpowers/` — design docs, specs, and implementation plans (gitignored).

## Task model

A `Task` is `{ id (ULID), content, meta }`. `content` (user-editable) = title, description,
`status` (todo/in_progress/done/cancelled), `priority` (none/low/medium/high), `child_ids`
(ordered subtask ids — the hierarchy is a **forest**), tags, due_at, scheduled_at. `meta`
(server-owned) = created_at, updated_at, completed_at, version. See `schema/SCHEMA.md`.

## Client behaviour

The Zig client:
1. Reads config (server URL, secret, optional `width`, `utc_offset`) from JSON (`SESHAT_CONFIG` or
   `~/.config/seshat/config.json`).
2. On `show`, fetches all tasks and renders the forest through a `select → rank → render`
   pipeline. Flags: `--sort <priority|due|title|created|urgency>` (default urgency),
   `--filter <tag:NAME|status:S1,S2|overdue>` (repeatable, AND), `--open`, `--flat` (rank all
   tasks, no tree), `--detailed`, `--json`, `--no-color`. Compact = one line/task with a `#handle`;
   `--detailed` = git-log-style multi-line blocks (meta line + description + `│`-rail subtasks).
3. Supports `add <title> [edits]`, `update <id> [edits]`, `delete <id>`, and `done <id>` — `<id>`
   accepts a short id **tail** / `#handle` — mutating via the server with optimistic concurrency.
   `add`/`update` share one flag set (`--title/--description/--status/--priority/--due/
   --scheduled/--tags`, plus `--dry-run`/`--verbose`).
4. Supports `--version` (build-time git describe), exits 0 on a broken pipe, and prints the
   server's error message on failure.

## Conventions

- The server is authoritative; clients must not assume local state is canonical.
- Auth is a plain shared secret in the `Authorization` header (no Bearer prefix).
