# seshat

A personal task manager built as a **server + client** system. The server is the source of
truth; clients fetch and locally cache task data.

## Layout

- `server/` — Go HTTP server. Single-file (`main.go`), stores tasks in memory with a `Version`
  counter. Auth via a shared `secret` sent in the `Authorization` header. Config (secret, port)
  loaded from YAML. Endpoints under `/api/tasks/` (e.g. `/api/tasks/get`).
  - `Task` = `{ title: string, priority: uint8 }`.
- `client/fish/` — the original minimal client, written in fish shell. Reference implementation
  for client behaviour (`add_task.fish`, `delete_task.fish`, `print_tasks.fish`).
- `client/zig/` — an in-progress rewrite of the client in Zig. See `client/zig/CLAUDE.md` for
  Zig-specific notes. This is where active client development happens.
- `plans/` — design docs (e.g. `mode_a_design.md`).

## Client behaviour

A client:
1. Reads config (server URL, secret, cache settings).
2. On `show`, fetches tasks — serving from a local on-disk cache when fresh, otherwise hitting the
   server and re-caching.
3. Supports `add <title> <priority>` and `delete <title>`, which mutate via the server.

## Conventions

- The server is authoritative; clients must not assume local state is canonical.
- Auth is a plain shared secret in the `Authorization` header (no Bearer prefix).
