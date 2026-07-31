# seshat client — Zig rewrite

The canonical seshat client (the standalone fish client has been retired). **Targets Zig 0.16**,
which made breaking changes to the I/O and stdlib APIs — when in doubt, check the actual installed
std source rather than relying on memory or pre-0.16 examples.

## Build & test

```sh
zig build              # compile
zig build run -- show  # run a subcommand (args after --)
zig build test         # runs the whole suite (main.zig aggregates the other files' tests)
zig test src/<file>.zig # run a single file's unit tests directly (fastest iteration)
```

**Requires a git checkout.** `build.zig` derives the `--version` string by shelling out to `git
describe --tags --always --dirty` and aborts the build if that fails (e.g. building from a
tarball with no `.git`). Override with `-Dversion=<string>` when building outside a checkout.

**Gotcha:** `zig build test` uses `src/main.zig` as the test root, so a file's tests only run if
reachable from main's import graph. `src/main.zig` ends with a `test { _ = @import("core/view.zig");
… }` aggregator block precisely so `zig build test` exercises view/args/formatter/config. If you add
a new test-bearing file, add it to that block (or run `zig test src/<file>.zig` directly).

**Gotcha:** `zig test src/<file>.zig` only works for files directly under `src/`. For files under
`src/api/*.zig` or `src/core/*.zig`, a bare `zig test` roots the module at that file's own
directory, so its `@import`s of sibling top-level modules fail with `error: import of file outside
module path`. For those files, use `zig build test` (or add the file to the `main.zig` aggregator
block) instead of `zig test` directly.

**Local dev (server + client + sample data):** see `dev/` at the repo root — `dev/run-server.sh`
starts a dev server, `dev/seed.sh` loads a realistic dataset, `dev/seshat.sh show --detailed` runs
this client against it. Handy for eyeballing rendering. (`make dev-server` / `make dev-seed`.)

## Layout

- `src/main.zig` — entry point + subcommand dispatch (`--version`, `show`, `add`, `update <id>`,
  `delete <id>`, `done <id>`, `help`). `--version` is checked before the config load (and prints
  `build_options.version`), so it works on a machine with no config file. Uses the 0.16
  `std.process.Init` entry signature: `pub fn main(init:
  std.process.Init) !void`. Pulls allocator from `init.arena`, args from `init.minimal.args`, env
  from `init.environ_map`, and passes `init.io` (the `std.Io` instance) down into all I/O. Owns the
  `show` flag declaration (`show_specs`) and `runShow`, which wires the view pipeline (parse →
  fetch → `view.select` → `view.rank` → `formatter.render`|`renderJson`), resolves color
  (`.auto`→on/off via `std.Io.File.stdout().isTty`), width (`COLUMNS` env → `config.width`), and the
  `#handle` length (`view.minUniqueSuffixLen` over *all* fetched tasks, so handles resolve uniquely).
  `done`/`delete` resolve an id **tail/suffix** (or `#handle`) via `view.resolve`.
  - **`add`/`update`** share one flag set (`edit.flag_specs`) and the flag→patch builder
    (`edit.patchFromArgs`): `runAdd`/`runUpdate` build an `edit.Patch`, apply it client-side
    (`edit.applyPatch` — `add` over a default `Content` seeded with the positional title; `update`
    over the freshly-fetched task), `edit.validate` it, then add / optimistic-update via the server.
    Flags: `--title/--description/--status/--priority/--due/--scheduled/--tags`, plus `--dry-run`
    (render the result **detailed**, no write) and `--verbose` (render the server-returned task
    **compact**). `--tags a,b,c` is a wholesale set (`--tags ""` clears). `update` needs ≥1 edit
    (else "nothing to update", nonzero). The old bare `add <title> [prio]` positional was removed
    (use `--priority`). Shared render helper `renderOne` + `resolveWidth`/`nowSeconds`.
  - **Error model:** `main` calls `run` and catches: `error.Reported` (an expected failure whose
    friendly message was already printed) → `std.process.exit(1)` silently; any other error → one
    line `error: <name>` + exit 1. So all commands fail **nonzero and trace-free** — every
    user-facing error site prints its message then `return error.Reported` (bad args, unknown
    enum/date, no-such-id, conflict, empty title, unknown command). `delete`/`done` now exit
    nonzero on not-found (previously exited 0). Piping output to a consumer that closes early
    (`seshat show | head`, quitting a pager) exits **0** with no message — Unix convention treats
    EPIPE as a clean stop. This is scoped to stdout only: each stdout write/flush site in
    `main.zig` maps `error.WriteFailed` to a distinct `error.StdoutClosed` via the `stdoutErr`
    helper before it can reach `main`'s catch; a `error.WriteFailed` from anywhere else (notably a
    dropped network connection in `api/client.zig`, which raises the identical error) is left
    unmapped and still fails nonzero with the one-line message, so a network failure can never be
    mistaken for a successful mutation.
- `src/core/view.zig` — the pure view layer: `Index` (id→Task + which ids are referenced as
  children, for root-ness), `Filters` + `select` (AND-combined `is_root`/tag/status/overdue),
  sort `Strategy` + `rank` (completed sink, stable `created_at,id` tiebreak), the time-aware
  `urgency` score (which compares durations, so the UTC offset cancels and must not be threaded
  in), `resolve` (id **suffix/tail** → unique task), and `minUniqueSuffixLen` (shortest
  unique tail length). All pure, `now: i64` passed in.
- `src/core/args.zig` — a generic, declaration-driven flag parser: `OptionSpec` table in →
  `ParsedArgs` (query by name with `getBool`/`getValue`/`getMulti`). No seshat flag names baked in.
- `src/core/edit.zig` — the **pure edit core** (no I/O), shared by `add`/`update` and the future
  TUI. `Edit(T) = union(enum){ unchanged, set: T }` is the uniform per-field patch; `Patch` is one
  `Edit` per editable `Content` field (`DatePatch = Edit(?i64)`, `.set = null` clears; tags `.set`
  is a wholesale replace, empty = cleared); `applyPatch(base, patch)` is pure (carries `child_ids`
  through — hierarchy is never patched here); `validate` (non-empty title). `parseDate(input, now,
  kind, offset_minutes)` parses ISO dates/times — `YYYY-MM-DD` (date-only → **local end-of-day
  for `.due`**, **local start-of-day for `.scheduled`**, stored as UTC), `YYYY-MM-DDTHH:MM`,
  `+Nd/+Nw/+Nm` (relative to the **local** day, `+Nm` clamps to month end), `none` → clear — via
  a hand-rolled `ymdToEpochDay` (std has no date parser; see `plans/todo.md`). `flag_specs` +
  `patchFromArgs` (takes `offset_minutes`) turn `ParsedArgs` into a `Patch` (`--tags` comma-split
  here; unknown status/priority/date → `BuildError`).
- `src/core/display.zig` — shared presentation logic, no styling: `statusGlyph`, `priorityLabel`,
  `truncate` (codepoint-safe, never splits a UTF-8 codepoint), `formatDate(buf, unix_seconds,
  offset_minutes)`, `handleText(buf, id, len)` (an unstyled `#<tail>`, lower-cased — the caller
  wraps it in dim), `dueWording(buf, due_at, now, completed, offset_minutes)` (a `DueWording`
  tagged union — `.due`/`.overdue{text, days}` — so the caller decides how to style it), and the
  semantic `Style` enum (`normal/dim/overdue/prio_high/prio_medium/prio_low`) with
  `priorityStyle`/`taskStyle`. Every function returns a slice (into a caller-supplied buffer where
  one is needed, otherwise into the input) rather than writing to a stream — libvaxis wants strings
  for cells, not a byte sink. The split is *which style* (`Style`, here) versus *how to emit it*
  (`formatter.zig` maps it to SGR via `Sgr.style`; a future `tui/render.zig` will map the same
  `Style` to a `vaxis.Style`) — this is what stops the CLI and the TUI drifting on what a task looks
  like. `priorityStyle` and `taskStyle` differ only in whether a done/cancelled status forces
  `.dim`: the compact-view root line uses `priorityStyle` (no dimming) while the detailed-view root
  line uses `taskStyle` (dims) — a deliberate asymmetry locked by a formatter test.

  `Style` covers only what **both** renderers need. TUI-only concerns — cursor-row highlight,
  focused-field highlight, a `saving…` marker — are shell-local `vaxis.Style`s and must **not** be
  added here.
- `src/formatter.zig` — `RenderOptions` (one struct, `compact()`/`detailed()` constructors, a
  `layout` mode) + one `render`. **Compact** = one line/task (`<glyph> title #handle`, `├─`/`└─`
  children). **Detailed** = git-log-style multi-line blocks (header, dim meta line `priority · due/⚠
  OVERDUE · sched · #tags · N subtasks`, body, `│` gutter rail for children). Owns layout and SGR
  emission only: `renderJson`, the 16-color `Sgr` helper (`Sgr.style` maps a `core/display.zig`
  `Style` to an escape code), a tail-based `writeHandle` (wraps `display.handleText`). Glyphs,
  labels, truncation, and date/due-wording formatting live in `core/display.zig`, not here.
  Immediate children only (depth 1); `[missing: #tail]` for dangling ids.
- `src/core/config.zig` — `Config` struct, loaded from JSON (`SESHAT_CONFIG` env or
  `~/.config/seshat/config.json`). Fields: `url`, `secret` (required); `max_lines`,
  `cache_ttl_seconds`, `cache_dir` (currently unused — caching is deferred), `utc_offset`
  (format `±HH:MM`, range ±14:00, defaults to `"+00:00"`; malformed value is a hard startup
  error, not a silent fallback), `offset_minutes` (derived from `utc_offset`).
- `src/core/task.zig` — `Task = { id, content, meta }` matching `schema/SCHEMA.md`. `Status`/
  `Priority` are string enums with an unknown-value `jsonParse` fallback.
- `src/api/client.zig` — `Client`: fetch (plain GET) / add / update (batch) / delete over HTTP.
  No cache (scope A) — every fetch hits the server. `postJson` returns the response body; `addTask`
  returns the created `Task` and `updateTasks` returns the updated `[]Task` (server echoes the
  authoritative result — used by `--verbose`). 409 → `error.Conflict`. Every other non-2xx response
  goes through `fail()`, which prints `server error (<code>): <message>` and returns
  `error.Reported` — matching the client-wide error model. `<message>` is the server's own
  `{"error": "..."}` body via `parseServerError`, falling back to `defaultMessage(code)` (a small
  switch over the statuses Stage 0 introduced: 429/413/403/404, else a generic message) when the
  body isn't parseable.
- `src/api/types.zig` — API wire types (`GetResponse`, `AddRequest`, `UpdateOp`, `AddResponse`,
  `UpdateResponse`, etc.).
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
- **No `std.time.timestamp()` in 0.16.** Wall-clock seconds come from the I/O instance:
  `@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)` (the `.nanoseconds`
  field is `i96`, so use `@divTrunc` + `@intCast` to `i64`).
- **No `std.posix.isatty`.** TTY detection is `std.Io.File.stdout().isTty(io)` → `Io.Cancelable!bool`
  (`catch false` for the safe no-color default).
- **`std.ArrayList(T)` is unmanaged.** Init with `.empty` (NOT `{}`); methods take the allocator:
  `list.append(allocator, x)`, `list.toOwnedSlice(allocator)`, `list.deinit(allocator)`.
- **Sorting:** `std.mem.sortUnstable(T, items, ctx, lessThan)` (prefer the unstable variant when the
  comparator is already a total order). Case-insensitive compare: `std.ascii.orderIgnoreCase(a, b)`
  → `std.math.Order`.
- **Dates:** break a unix timestamp into Y-M-D via `std.time.epoch`:
  `EpochSeconds{ .secs }.getEpochDay().calculateYearDay()` → `.year`/`.calculateMonthDay()`
  (`.month.numeric()`, `.day_index + 1`).
- **UTF-8:** `std.unicode.utf8ByteSequenceLength(lead_byte)` (`!u3`) to walk codepoints without
  splitting them; `std.unicode.utf8ValidateSlice`.
