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

make dev-server               # run a local server (dev/ config)
make dev-seed                 # load a realistic dataset into it
```

All six test targets must pass before any commit. `make shell-test` is local-only — CI does not
run it and installs no fish.

## Layout

- The Go module root is the repo root (`go.mod` at top level) — it is not `server/`. Wire types
  shared by the server and the Go bot (`Task`, `Content`, `Meta`, `Status`, `Priority`,
  `AddRequest`, `UpdateOp`) live in `internal/task/`. `State` and `CurrentDataFormatVersion` stay
  in `server/` — they are the server's own on-disk concerns, not part of the wire contract.
- `server/` — Go HTTP server (`package main`, split across `task.go` / `store.go` / `validate.go`
  / `handlers.go` / `admin.go` / `tenants.go` / `main.go`). Stores each user's tasks in memory,
  persisted as one JSON blob per user in a single bbolt file (`tenants.go`: `meta`/`users`/`data`
  buckets; `format_version` per file; `state_version` per user). Auth: per-user opaque tokens in
  the `Authorization` header, resolved by `Tenants.Authenticate` at one chokepoint
  (`tenantBranch`) that hands each handler its own `*Store` — `Server` holds no store. A separate
  `admin_token` (config, ≥32 chars) authenticates only `/api/admin/users/{add,list,delete}`
  (`admin.go`); deleting a user deletes their data. Config (admin_token, port, data_file, bind,
  rate_limit) from YAML — `bind` defaults to `127.0.0.1`; `rate_limit` defaults to 10 req/s with
  burst 2x. Endpoints under `/api/tasks/` (`get`, `add`, `update`, `delete`). Optimistic
  concurrency via per-task `meta.version`. Requests pass through `MaxBytesHandler → prefix
  dispatch on the escaped path → {adminAuth → admin limiter → admin route table | Authenticate →
  per-tenant limiter → task route table}` — no `ServeMux`, no path cleaning or decoding, so every
  response without a valid credential is a 403. Two distinct version fields: `state_version`
  (concurrency counter / ETag, bumped per mutation, now per user) and the on-disk `format_version`
  key in the `meta` bucket (file-wide format generation, currently 1 — the server refuses to
  start on a higher one; the in-memory `State` struct carries the same number as
  `DataFormatVersion`/`data_format_version`, but that field is never itself read from or written
  to a per-user blob). Do not conflate them.
- `schema/` — the shared `Task` contract: `task.schema.json`, `SCHEMA.md`, golden `fixtures/`.
  Enforced across server + client by `make schema-test`.
- `client/zig/` — the canonical client (Zig 0.16). See `client/zig/CLAUDE.md`.
- `client/bot/` — a Go Telegram bot client (`package main`), long-polling via
  `github.com/go-telegram/bot`, over the same server API. A pure core (`view.go` select/rank,
  `render.go` layout) is exercised without any Telegram fake; an I/O shell (`handlers.go`,
  `seshat.go`) does the fetch/mutate/render orchestration; an LRU `Registry` (`actions.go`) maps
  opaque callback tokens (and outstanding ForceReply prompts) back to `Action`s; `main.go` is the
  only place Telegram's own types are touched. Any message becomes a task (capture); `/list` and
  `/find` browse the same ranked forest as the CLI; editing is per-field through a card's inline
  keyboard, with free-text fields (title/description/tags) taken over a ForceReply reply and
  pinned-version optimistic concurrency. See `client/bot/README.md` for config, BotFather
  settings, and deployment.
- `client/shell/` — shell integration. `fish/` is a fisher-layout plugin (completions, a `conf.d`
  `fish_prompt` hook printing a cached task block after inactivity, and the `seshat-prompt`
  control function); `bash/` and `zsh/` are static completions only. The files are embedded in
  the client binary and printed by `seshat completions <shell>` / `seshat init fish`; the
  installer is the distribution channel and a local-path `fisher install` is the dev loop.
  Cache: `$XDG_CACHE_HOME/seshat/prompt`. Tested headlessly by `make shell-test`
  (`test/shell/run.sh`); see `client/shell/README.md`.
- `test/` — integration tests needing a real server + client (`make client-integration-test`).
  `test/seed` loads a legacy JSON task file through the API; also the migration tool.
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
1. Reads config (server URL, secret, optional `width`, `utc_offset`, `timeout_ms`) from JSON
   (`SESHAT_CONFIG` or `~/.config/seshat/config.json`). `timeout_ms` (default 10000, `0` disables)
   is a wall-clock deadline on every HTTP request, so no command can hang forever on a wedged
   server.
2. On `show`, fetches all tasks and renders the forest through a `select → rank → render`
   pipeline. Flags: `--sort <priority|due|title|created|urgency>` (default urgency),
   `--filter <tag:NAME|status:S1,S2|overdue>` (repeatable, AND), `--open`, `--flat` (rank all
   tasks, no tree), `--detailed`, `--json`, `--no-color`, `--limit N` (at most N *rendered rows*,
   cut only on whole-root boundaries — a first root larger than N is rendered whole — then a
   `… and M more` trailer; under `--flat` in compact layout that also bounds lines, otherwise it
   does not). Compact = one line/task with a
   `#handle`; `--detailed` = git-log-style multi-line blocks (meta line + description +
   `│`-rail subtasks).
3. Supports `add <title> [edits]`, `update <id> [edits]`, `delete <id>`, and `done <id>` — `<id>`
   accepts a short id **tail** / `#handle` — mutating via the server with optimistic concurrency.
   `add`/`update` share one flag set (`--title/--description/--status/--priority/--due/
   --scheduled/--tags`, plus `--dry-run`/`--verbose`).
4. On `tui`, opens a full-screen interactive view (libvaxis) over the same data. Takes `--sort`,
   `--filter` and `--open` — the same parse/merge as `show`, but **not** `--flat`. **One screen:**
   a ranked ledger of the forest plus a toggleable detail pane (`Tab`). Rows are ranked by
   **subtree** urgency, and a parent auto-expands only when a descendant needs attention (high
   priority, or due within 3 days), otherwise staying folded behind a `(+n)` badge — so a buried
   urgent subtask is visible with no keypress. `Enter` descends list → field → edit and `Esc`
   climbs back one level; four editor kinds (line, picker, date, and `$EDITOR` for the
   description). Edits commit per field with optimistic concurrency; **refresh is manual** (`R`),
   with polling deferred. See `client/zig/CLAUDE.md` for the full keymap.
5. Supports `--version` (build-time git describe, falling back to `dev` without a `.git`),
   `completions <fish|bash|zsh>` and `init fish` (both print files embedded from `client/shell/`,
   before any config is loaded), exits 0 on a broken pipe, and prints the server's error message on
   failure.

The Telegram bot (`client/bot/`):
1. Reads config (bot token, server URL, `utc_offset`, and a `telegram_id → seshat token` map)
   from JSON (`SESHAT_BOT_CONFIG` or `~/.config/seshat/bot.json`). Refuses to start on an empty
   token, an empty user map, or a bad offset; warns on a group/world-readable file.
2. **Any non-command message becomes a task** — first line is the title, everything after the
   first newline is the description. This rule is unconditional; it is why field edits arrive
   through Telegram's `ForceReply` rather than "the next message you send is the value".
3. `/list` renders open tasks as a page of **5 roots** (never splitting a root from its subtree,
   also capped at 25 rows), ranked by subtree urgency; `/find <text>` searches titles. Both render
   through one paged renderer, with per-page numbered buttons.
4. Tapping a number opens a card; its inline keyboard edits status, priority, due, title,
   description and tags, and deletes. **Selection keeps a closed parent that still has open
   children** — the same rule as `view.zig`'s `select`, so marking a parent done never hides a
   live subtask.
5. **Two concurrency regimes** (`handlers.go` → `applyEdit`): picker fields re-fetch and retry
   once on a 409; free-text fields pin `meta.version` when the prompt is sent, never auto-retry,
   and surface a conflict as `[Overwrite]`/`[Keep theirs]` so a typed value is never lost.
6. Interaction state is an in-memory LRU registry (`actions.go`) mapping opaque button tokens to
   actions. Every action carries the full task ULID, so a tap on a scrolled-back message acts on
   *that* message's task. A restart expires every rendered button — by design.

## Conventions

- The server is authoritative; clients must not assume local state is canonical.
- Auth is a per-user opaque token in the `Authorization` header (no Bearer prefix); the admin
  token is a separate credential for `/api/admin/*` only.
- **Never delete an SDD workspace — archive it.** `superpowers:subagent-driven-development` tells
  you to delete `.superpowers/sdd/<plan>/` once a plan's final review is clean. Do not. Move it to
  `sdd_archive/<plan>/` instead. The ledger, task briefs, implementer reports and review write-ups
  are the only record of *why* the code looks the way it does — which plan steps were wrong, which
  findings were adjudicated how, which deviations were deliberate. The plans themselves are
  gitignored and the commits carry only the outcome, so this is the audit trail for later
  investigation. `sdd_archive/` is gitignored.
