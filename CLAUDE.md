# seshat

A personal task manager built as a **server + client** system. The server is the source of
truth; clients fetch task data from it.

## Commands

```sh
make server-test              # Go server tests (runs with -race)
make schema-test              # shared Task-contract tests (Go + Zig halves)
make client-integration-test  # spawns a real server + client through a pipe
make bot-test                 # Go Telegram bot client tests
make shell-test               # the shell files under fish/bash/zsh, no server (local only)
cd client/zig && zig build test   # Zig client unit tests

make install                  # build the client into ~/.local/bin (or SESHAT_INSTALL_DIR)
make dev-server               # run a local server (dev/ config)
make dev-seed                 # load a realistic dataset into it

make docker-build             # both images, as seshat:dev and seshat-bot:dev (needs buildx)
make docker-smoke             # throwaway images, tested in a container (buildx + compose)
```

All six test targets must pass before any commit. CI (`.github/workflows/ci.yml`) runs five of
them: `make shell-test` is local-only, and CI installs no fish. The two `docker-*` targets are
not among the six: they are run by hand before a release, and CI runs neither. `make install`
writes into the developer's real `~/.local/bin`: try it only with `SESHAT_INSTALL_DIR` set to a
directory under `/tmp`.

## Layout

- The Go module root is the repo root (`go.mod` at top level) — it is not `server/`.
- `internal/task/` — the wire types shared by the server and the Go bot. `State` and
  `CurrentDataFormatVersion` stay in `server/`: on-disk concerns, not part of the wire contract.
- `server/` — the Go HTTP server (`package main`): per-user task stores in memory, persisted in
  one bbolt file. Endpoints: `/api/tasks/{get,add,update,delete}` and
  `/api/admin/users/{add,list,delete}`. Config keys, `SESHAT_*` variables, defaults: `README.md`.
- `schema/` — the shared `Task` contract: `task.schema.json`, `SCHEMA.md`, golden `fixtures/`.
  Enforced across server + client by `make schema-test`.
- `client/zig/` — the canonical client (Zig 0.16): the `seshat` CLI and a full-screen TUI.
  Commands, flags and keys: `README.md`; internals and build gotchas: `client/zig/CLAUDE.md`.
- `client/bot/` — a Go Telegram bot client (`package main`) over the same server API; `main.go`
  is the only place Telegram's own types are touched. Any non-command message becomes a task,
  unconditionally, so free-text edits arrive as `ForceReply` replies. See `client/bot/README.md`.
- `client/shell/` — shell integration: a fisher-layout fish plugin and static bash/zsh
  completions, embedded in the client binary and printed by `seshat completions <shell>` /
  `seshat init fish`. See `client/shell/README.md`.
- `test/` — the integration test (a real server + client), the shell tests (`test/shell/`), and
  `test/seed`, which loads a legacy JSON task file through the API (also the migration tool).
- `dev/` — a throwaway local server + client environment (`make dev-server`, `make dev-seed`);
  see `dev/README.md`.
- `docker/` — how the server is deployed: `Dockerfile.server` and `Dockerfile.bot` (build context
  is the repo root), `compose.yaml`, and the operator guide `docker/README.md`. `smoke.sh` is
  `make docker-smoke`, the only test of anything under `docker/`: run it after any change there.
- `.github/workflows/ci.yml` — CI, on pull requests and on pushes to `main` (never `dev`). Its Go
  version must equal `GO_VERSION` in both Dockerfiles (`go.mod`'s `go` line is only a floor).
  Lint it with `actionlint`.

## Task model

A `Task` is `{ id (ULID), content, meta }`. `content` is user-editable: title, description,
status, priority, tags, due and scheduled dates, and `child_ids` (ordered subtask ids — the
hierarchy is a **forest**). `meta` is server-owned: timestamps and `version`. Fields, enums and
invariants: `schema/SCHEMA.md`.

## Conventions

- The server is authoritative; clients must not assume local state is canonical.
- Auth is a per-user opaque token in the `Authorization` header (no Bearer prefix); the admin
  token is a separate credential for `/api/admin/*` only. Auth runs before routing, so every
  response without a valid credential is a 403.
- Do not conflate the version numbers: per-task `meta.version` (the optimistic-concurrency
  token), per-user `state_version` (the ETag, bumped per mutation) and the data file's
  `format_version` (on-disk format generation; the server refuses to start on a higher one).
- A new server `SESHAT_*` variable must also be added to the `unset` lines in
  `test/broken-pipe.sh` and `dev/run-server.sh`, or an exported value leaks into those servers.
- Deployment defaults (bind, port, data file) live in the image `ENV`, never in the binary.
- The Dockerfiles `COPY` only `go.mod`, `go.sum`, `internal/` and the binary's own directory: a
  new Go directory either binary imports must be added there. None of the six test targets
  notices a missing one, only the two `docker-*` targets.
- **Never `docker compose up` or `down` `docker/compose.yaml` to try it.** Its project name,
  volume name and port are fixed and global: `down -v` from any directory deletes a real
  deployment's data.
- The `sh` blocks in `docker/README.md` must run unchanged in bash, zsh and fish (no heredoc, no
  `exit`, no `{ }`), and the guide must quote server and bot log lines verbatim; nothing
  committed tests either.
