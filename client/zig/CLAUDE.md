# seshat client — Zig rewrite

The canonical seshat client (the standalone fish client has been retired). **Targets Zig 0.16**,
which made breaking changes to the I/O and stdlib APIs — when in doubt, check the actual installed
std source rather than relying on memory or pre-0.16 examples.

## Build & test

```sh
zig build              # compile
zig build run -- show  # run a subcommand (args after --)
zig build test         # NOTE: test root is src/main.zig — only runs tests reachable from it
zig test src/<file>.zig # run a single file's unit tests directly (use this for per-file tests)
```

**Gotcha:** `zig build test` uses `src/main.zig` as the test root, so unit tests in other files
(e.g. `formatter.zig`) are **not** run unless reachable from main's import graph. To exercise a
file's tests, run `zig test src/<file>.zig` directly.

## Layout

- `src/main.zig` — entry point + subcommand dispatch (`show`, `add`, `delete <id>`, `done <id>`,
  `help`). Uses the 0.16 `std.process.Init` entry signature: `pub fn main(init: std.process.Init)
  !void`. Pulls allocator from `init.arena`, args from `init.minimal.args`, env from
  `init.environ_map`, and passes `init.io` (the `std.Io` instance) down into all I/O.
- `src/formatter.zig` — renders the task forest as indented text lines (roots = tasks not
  referenced by any `child_ids`).
- `src/core/config.zig` — `Config` struct, loaded from JSON (`SESHAT_CONFIG` env or
  `~/.config/seshat/config.json`). Fields: `url`, `secret` (required); `max_lines`,
  `cache_ttl_seconds`, `cache_dir` (currently unused — caching is deferred).
- `src/core/task.zig` — `Task = { id, content, meta }` matching `schema/SCHEMA.md`. `Status`/
  `Priority` are string enums with an unknown-value `jsonParse` fallback.
- `src/api/client.zig` — `Client`: fetch (plain GET) / add / update (batch) / delete over HTTP.
  No cache (scope A) — every fetch hits the server.
- `src/api/types.zig` — API wire types (`GetResponse`, `AddRequest`, `UpdateOp`, etc.).
- `src/schema_test.zig` — round-trips the shared `schema/fixtures/` against `Task` (run by
  `make schema-test` alongside the Go side).

## Zig 0.16 API notes (learned the hard way)

These are the 0.16 patterns this codebase relies on. The new I/O model threads an explicit
`std.Io` value through file/socket/http operations.

- **Files:** `std.Io.Dir.cwd().openFile(io, path, .{})`; read via `file.reader(io, &.{})` then
  `reader.interface.allocRemaining(allocator, .limited(n))`.
- **Stdout:** `std.Io.File.stdout().writer(io, &.{})`, then `.interface.print(...)`.
- **HTTP:** `std.http.Client{ .io = io, .allocator = alloc }`; `client.request(.GET, uri, .{...})`,
  `req.sendBodiless()`, `req.receiveHead(&redirect_buffer)`, `response.reader(&.{})`.
- **JSON parse:** `std.json.parseFromSlice(T, alloc, content, .{ .ignore_unknown_fields = true,
  .allocate = .alloc_always })` → `std.json.Parsed(T)` (call `.deinit()`). Under an arena (the CLI
  runtime) use `parseFromSliceLeaky` instead — returns `T` directly, freed with the arena.
- **Enum fallback:** `Status`/`Priority` define `pub fn jsonParse` that reads the field as a
  string then `std.meta.stringToEnum(...) orelse <default>`, so an unknown server enum value maps
  to a fallback instead of erroring.
- **JSON serialize:** `var aw: std.Io.Writer.Allocating = .init(alloc); var w = std.json.Stringify{
  .writer = &aw.writer, .options = .{} }; try w.write(payload);` → body bytes = `aw.written()`.
  Enums serialize as their tag-name string by default.
