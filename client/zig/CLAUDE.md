# seshat client — Zig rewrite

Rewrite of the fish client (`../fish/`) in Zig. **Targets Zig 0.16**, which made breaking changes
to the I/O and stdlib APIs — when in doubt, check the actual installed std source rather than relying on memory or pre-0.16 examples.

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

- `src/main.zig` — entry point + subcommand dispatch (`show`, `add`, `delete`, `help`). Uses the
  0.16 `std.process.Init` entry signature: `pub fn main(init: std.process.Init) !void`. Pulls
  allocator from `init.arena`, args from `init.minimal.args`, env from `init.environ_map`, and
  passes `init.io` (the `std.Io` instance) down into all I/O.
- `src/formatter.zig` — formats tasks as JSON for output.
- `src/core/config.zig` — `Config` struct, loaded from JSON (`SESHAT_CONFIG` env or
  `~/.config/seshat/config.json`). Fields: `url`, `secret`, `max_lines`, `cache_ttl_seconds`,
  `cache_dir` (defaults to `~/.cache/seshat`).
- `src/core/task.zig` — `Task` struct (owns heap strings; has `deinit`).
- `src/core/cache.zig` — on-disk task cache (`CacheProvider`), keyed by server URL with TTL.
- `src/api/client.zig` — `Client`: fetch/add/delete tasks over HTTP, cache-first on fetch.
- `src/api/types.zig` — API wire types.

## Zig 0.16 API notes (learned the hard way)

These are the 0.16 patterns this codebase relies on. The new I/O model threads an explicit
`std.Io` value through file/socket/http operations.

- **Files:** `std.Io.Dir.cwd().openFile(io, path, .{})`; read via `file.reader(io, &.{})` then
  `reader.interface.allocRemaining(allocator, .limited(n))`.
- **Stdout:** `std.Io.File.stdout().writer(io, &.{})`, then `.interface.print(...)`.
- **HTTP:** `std.http.Client{ .io = io, .allocator = alloc }`; `client.request(.GET, uri, .{...})`,
  `req.sendBodiless()`, `req.receiveHead(&redirect_buffer)`, `response.reader(&.{})`.
- **JSON parse:** `std.json.parseFromSlice(T, alloc, content, .{ .ignore_unknown_fields = true,
  .allocate = .alloc_always })` → returns `std.json.Parsed(T)` (call `.deinit()`).

## Known issues / TODO

- Serialized tasks show `"id": ""` for every task — the id is not being populated from the server
  response (likely in the cache/parse layer). Not yet investigated.
