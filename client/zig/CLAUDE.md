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

**Version string, and building without `.git`.** `build.zig` derives `--version` from
`-Dversion=<string>` if it is **non-empty**, else `git describe --tags --always --dirty`, else the
literal `dev` — it no longer aborts, so an exported tree still builds. Caveat: `runAllowFail` spawns
without setting a cwd, so `git describe` resolves against wherever `zig build` was *invoked*, not
the build root — `zig build --build-file …` from outside the repo silently reports `dev`.

**Build flags.** `zig build` takes the standard `-Dtarget=<triple>` / `-Doptimize=<mode>` plus
`-Dstrip` (omit debug info; the release does **not** use it — spec (d) keeps ReleaseSafe stack
traces) and `-Dversion=`. All four release targets (`{x86_64,aarch64}-{linux-musl,macos}`) build
from this tree unchanged. The **test** artifact is pinned to `b.graph.host`, because a
foreign-target test binary cannot be run here: `zig build test -Dtarget=…` still compiles and runs
the full *host* suite, so a green `test` says nothing about a cross-target build — use
`zig build -Dtarget=…` for that. `-Doptimize` is not wired through to the test artifact either; the
tests exercise Debug safety checks and `std.debug.assert`.

**`client/shell/` is a build input.** `build.zig` embeds five files from it (see `src/shell.zig`).
A copy of `client/zig` without its `client/shell` sibling does not build.

**Gotcha:** `zig build test` uses `src/main.zig` as the test root, so a file's tests only run if
reachable from main's import graph. `src/main.zig` ends with a `test { _ = @import("core/view.zig");
… }` aggregator block precisely so `zig build test` exercises view/args/formatter/config. If you add
a new test-bearing file, add it to that block (or run `zig test src/<file>.zig` directly).

**Gotcha: `zig build test` does NOT typecheck the CLI.** A test build only analyzes decls reachable
from a `test` block, and `main()`/`run()` are not — so `zig build test` can report "N/N tests
passed" while `zig build` fails to compile `main.zig` and every `client.*` call site. Always run
**both** `zig build` and `zig build test` before claiming a change is green. The converse also
holds for `src/tui/render.zig` and `src/tui/app.zig`: neither has behavioural tests, and both are
kept analysable by a `test { std.testing.refAllDecls(@This()); }` at the bottom — a bare
`_ = @import(...)` in main.zig's aggregator links a file in **without** analysing a single function
body. Since the `tui` subcommand exists, the executable graph reaches both files too, so
`zig build` now checks them as well; don't delete either safety net.

**Gotcha:** `zig test src/<file>.zig` only works for files directly under `src/`. For files under
`src/api/*.zig` or `src/core/*.zig`, a bare `zig test` roots the module at that file's own
directory, so its `@import`s of sibling top-level modules fail with `error: import of file outside
module path`. For those files, use `zig build test` (or add the file to the `main.zig` aggregator
block) instead of `zig test` directly.

**Local dev (server + client + sample data):** see `dev/` at the repo root — `dev/run-server.sh`
starts a dev server, `dev/seed.sh` loads a realistic dataset, `dev/seshat.sh show --detailed` runs
this client against it. Handy for eyeballing rendering. (`make dev-server` / `make dev-seed`.)

## Layout

- `src/main.zig` — entry point + subcommand dispatch (`--version`, `completions <fish|bash|zsh>`,
  `init fish`, `show`, `tui`, `add`, `update <id>`, `delete <id>`, `done <id>`, `help`).
  `--version`, `completions` and `init` are all handled **before the config load** (the installer
  runs `seshat completions fish` on a machine with no config file and possibly no `$HOME`);
  `completions`/`init` print blobs embedded from `client/shell/` — see `src/shell.zig`. Uses the
  0.16 `std.process.Init` entry signature: `pub fn main(init:
  std.process.Init) !void`. Pulls allocator from `init.arena`, args from `init.minimal.args`, env
  from `init.environ_map`, and passes `init.io` (the `std.Io` instance) down into all I/O.
  Owns the `show` flag declaration (`show_specs`) and `runShow`, which wires the view pipeline
  (parse → fetch → `view.select` → `view.rank` → **`view.limitRows`** → `formatter.render`|
  `renderJson`) … `--limit N` caps *rendered rows* and prints a `… and M more` trailer;
  `count_children` is derived from the parsed flags **before** the `--json` early return, because
  `opts.show_children` does not exist yet at that point. Also resolves color
  (`.auto`→on/off via `std.Io.File.stdout().isTty`), width (`COLUMNS` env → `config.width`), and the
  `#handle` length (`view.minUniqueSuffixLen` over *all* fetched tasks, so handles resolve uniquely).
  `done`/`delete` resolve an id **tail/suffix** (or `#handle`) via `view.resolve`. Also holds two
  structural tests: `build_options.version is non-empty`, and **`every HTTP call site is
  deadlined`**, which embeds every file under `src/` and fails if a `std.http.Client` is
  constructed anywhere but `api/client.zig`'s `requestInner` — **add new source files to its
  `src_files` list**.
  - **`add`/`update`** share one flag set (`edit.flag_specs`) and the flag→patch builder
    (`edit.patchFromArgs`): `runAdd`/`runUpdate` build an `edit.Patch`, apply it client-side
    (`edit.applyPatch` — `add` over a default `Content` seeded with the positional title; `update`
    over the freshly-fetched task), `edit.validate` it, then add / optimistic-update via the server.
    Flags: `--title/--description/--status/--priority/--due/--scheduled/--tags`, plus `--dry-run`
    (render the result **detailed**, no write) and `--verbose` (render the server-returned task
    **compact**). `--tags a,b,c` is a wholesale set (`--tags ""` clears). `update` needs ≥1 edit
    (else "nothing to update", nonzero). The old bare `add <title> [prio]` positional was removed
    (use `--priority`). Shared render helper `renderOne` + `resolveWidth`/`nowSeconds`.
  - **`tui`** (`tui_specs` + `runTui`) parses `--sort`/`--filter`/`--open` with the same
    `filterspec.parse` + merge that `runShow` uses, then calls `tui/app.zig`'s `run`. Three
    things differ from `runShow` and all three are deliberate:
    - **`--flat` is not accepted** (it is an `UnknownFlag` error, nonzero, before the terminal is
      touched). In `show` it means two unrelated things — `roots_only = false` and
      `show_children = false` — and the TUI's ledger is a tree by construction.
    - **Nothing is freed on the way out.** `runShow`'s slices die with the function; the TUI's
      live for the whole session, so there is no `fs.deinit` (the process arena's `free` reclaims
      the most recent allocation and would hand the filter's own bytes out again).
    - **`init.gpa`, not the process arena**, is handed to `app.run`. A TUI frees as it goes
      (per-request arenas, editor buffers, the model's arenas); an arena's no-op `free` would turn
      every refresh into permanent growth. The `Client` is still the arena-allocated one — it only
      ever allocates the last recorded error from it.

    `runTui` also passes the **filter expression text** alongside the parsed `view.Filters`,
    because `m.filtering`/`m.filter_expr` — not `m.filters` — are what drive the header's scope
    word, the dimming of rows that matched only via a descendant, and `ledger.buildRows`' orphan
    gate. `--open` is spelled out as `status:todo,in_progress` so the string re-parses to exactly
    the filters that were applied, and `Esc` (which clears the filter) has something truthful to
    clear.
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
    mistaken for a successful mutation. The same `stdoutErr` path covers `completions`/`init`, so
    `seshat completions fish > file` exits 0 even if the write itself failed (a full disk, say) —
    an installer must check the written file is non-empty rather than trust the exit code.
- `src/shell.zig` — the five shell-integration files, `@embedFile`d at build time from
  **`client/shell/`, which is the single source of truth** (`client/shell/fish/` is also the fisher
  plugin root, and the whole tree is the installer's input). Do **not** edit an embedded copy and
  do not generate these files from the flag tables. `@embedFile` cannot escape a module root, so
  `build.zig` mounts each file as its own anonymous module (`addAnonymousImport` +
  `b.path("../shell/…")`) on **both** the exe and the test
  artifact — the documented mechanism, see the build-system guide's "Producing Assets for
  `@embedFile`". All five files are a **required build input**: delete one and `zig build` fails
  with `error: failed to check cache: '…' file_hash FileNotFound`. Edits to them are cache-tracked
  by content. Two tests: every blob is non-empty, and the fish completion carries an
  `-a <subcommand>` entry for every subcommand (a drift alarm — the completions are hand-written).
- `src/core/view.zig` — the pure view layer: `Index` (id→Task + which ids are referenced as
  children, for root-ness), `Filters` + `select` (AND-combined `is_root`/tag/status/overdue),
  sort `Strategy` + `rank` (completed sink, stable `created_at,id` tiebreak), the time-aware
  `urgency` score (which compares durations, so the UTC offset cancels and must not be threaded
  in), `resolve` (id **suffix/tail** → unique task), `minUniqueSuffixLen` (shortest unique tail
  length), and `limitRows` (`show --limit N`: caps the ranked top-level slice at N *rendered
  rows* — a root plus, when the renderer will print them, its `child_ids`, dangling ids included
  — cutting only on whole-root boundaries so no orphaned `├─` can be printed, and always emitting
  at least the first root). All pure, `now: i64` passed in.
- `src/core/args.zig` — a generic, declaration-driven flag parser: `OptionSpec` table in →
  `ParsedArgs` (query by name with `getBool`/`getValue`/`getMulti`). No seshat flag names baked in.
  Also `positiveInt(s) ?usize`, a generic "positive integer, as `std.fmt.parseUnsigned` parses it"
  helper (`--limit` uses it).
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
  `priorityStyle`/`taskStyle`. `formatDate`/`handleText`/`dueWording` write into a caller-supplied
  buffer and return a slice of it; `truncate` returns a slice of its input; `statusGlyph`/
  `priorityLabel` return static string literals; `priorityStyle`/`taskStyle` return a `Style`
  value. None of it writes to a stream — libvaxis wants strings for cells, not a byte sink. The
  split is *which style* (`Style`, here) versus *how to emit it*
  (`formatter.zig` maps it to SGR via `Sgr.style`; a future `tui/render.zig` will map the same
  `Style` to a `vaxis.Style`) — this is what stops the CLI and the TUI drifting on what a task looks
  like. `priorityStyle` and `taskStyle` differ only in whether a done/cancelled status forces
  `.dim`: the compact-view root line uses `priorityStyle` (no dimming) while the detailed-view root
  line uses `taskStyle` (dims) — a deliberate asymmetry locked by a formatter test.

  `Style` covers only what **both** renderers need. TUI-only concerns — cursor-row highlight,
  focused-field highlight, the `saving…` marker, the attention badge — are shell-local
  `vaxis.Style`s and must **not** be added here.
- `src/formatter.zig` — `RenderOptions` (one struct, `compact()`/`detailed()` constructors, a
  `layout` mode) + one `render`. **Compact** = one line/task (`<glyph> title #handle`, `├─`/`└─`
  children). **Detailed** = git-log-style multi-line blocks (header, dim meta line `priority · due/⚠
  OVERDUE · sched · #tags · N subtasks`, body, `│` gutter rail for children). Owns layout and SGR
  emission: `renderJson`, the 16-color `Sgr` helper (`Sgr.style` maps a `core/display.zig`
  `Style` to an escape code), a tail-based `writeHandle` (wraps `display.handleText`). The old
  `Sgr.priority` was deleted — `Sgr.style(display.priorityStyle(p))` is now the single source of
  truth for priority→colour. Glyphs, labels, truncation, and date/due-wording formatting live in
  `core/display.zig`, not here — but formatter.zig still owns most of the **meta-line vocabulary**:
  the `" · "` separator, `"sched {s}"`, tag rendering, `"{d} subtasks"`, the `├─`/`└─` connectors,
  and `"[missing: {s}]"`. None of that wording has moved into `core/display.zig` yet; it's
  deliberately deferred until the TUI exists to reveal which strings actually need to be shared.
  Immediate children only (depth 1); `[missing: #tail]` for dangling ids.
- `src/core/config.zig` — `Config` struct, loaded from JSON (`SESHAT_CONFIG` env or
  `~/.config/seshat/config.json`). Fields: `url`, `secret` (required); `timeout_ms` (wall-clock
  deadline per HTTP request, default 10000, **`0` = no deadline**); `cache_ttl_seconds`, `cache_dir`
  (currently unused — caching is deferred), `width`, `utc_offset` (format `±HH:MM`, range ±14:00,
  defaults to `"+00:00"`; malformed value is a hard startup error, not a silent fallback),
  `offset_minutes` (derived from `utc_offset`). `max_lines` was deleted (dead since the fish client
  was retired); `.ignore_unknown_fields = true` means an old config that still carries it loads fine.
- `src/core/task.zig` — `Task = { id, content, meta }` matching `schema/SCHEMA.md`. `Status`/
  `Priority` are string enums with an unknown-value `jsonParse` fallback.
- `src/api/client.zig` — `Client`: fetch (plain GET) / add / update (batch) / delete over HTTP.
  No cache (scope A) — every fetch hits the server. Written for a **long-lived caller**, not just
  the one-shot CLI:
  - **Caller-provided allocation.** `fetchTasks`/`addTask`/`updateTasks`/`deleteTask` all take an
    explicit `alloc` used for the connection, the URL, the response body and the parse. Tasks are
    parsed `.allocate = .alloc_always`, so they do **not** alias the response body (which *is*
    freed before returning — every transient allocation has a matching `alloc.free`). What differs
    is who reclaims: a TUI hands in a per-request arena and resets it; the CLI hands in the process
    arena, whose `free` is a no-op, so nothing is actually returned until exit. That asymmetry is
    why the non-aliasing invariant needs its own tests — under the CLI an aliased task string still
    reads correctly forever. `parseGet`/`parseAdd`/`parseConflict`/`updateResultFrom` exist as
    separate functions so each parse site can be tested against a body that has been freed; do not
    inline them. Nothing is allocated from `self.allocator` except the recorded error.
  - **Errors are data, not output.** A non-2xx response goes through `fail()`, which calls
    `recordError` and returns `error.ApiFailed`. Nothing is printed — inside an alt-screen TUI a
    stray stderr write corrupts the display. `lastError()` returns `?ApiError{code, message}`;
    `clearError(alloc)` frees it (idempotent). **`ApiError.message` is OWNED**: `recordError`
    *dupes* it, because `parseServerError` returns a slice into the body, and the body dies with
    the per-request arena. `<message>` is the server's own `{"error": "..."}` text, falling back to
    `defaultMessage(code)` (429/413/403/404, else generic). `main.zig` prints
    `server error (<code>): <message>` itself via `reportApiError`, so CLI output is unchanged.
  - **409 is an outcome, not an error.** `updateTasks` returns
    `UpdateResult = union(enum){ ok: []Task, conflict: []Task }`. The server's conflict body already
    carries the fresh tasks (`{"conflicts": [Task, …]}` — `types.ConflictResponse`), and there is
    **no single-task GET endpoint**, so parsing it is the only way to reconcile without a full
    refetch. `parseConflict` yields an empty slice for an unparseable body (OOM still propagates).
    The status→result decision lives in the pure `updateResultFrom` so the 409 branch is unit
    testable — no CLI invocation can reach it (the CLI refetches immediately before every update).
  - **One chokepoint, and every request is deadlined.** `requestInner` is the only place in the
    whole client that constructs a `std.http.Client`; `request` wraps it in `deadlined`, which races
    it against `Io.sleep` inside an `Io.Select` and cancels the loser — the babysitter-task pattern
    upstream recommends (ziglang/zig#31098), since 0.16's HTTP client has no timeout at all.
    `fetchTasks`/`postJson` interpret the status and parse *outside* the deadline, so a cancelled
    task can only discard a body buffer. Four rules, all load-bearing: (1) **`cancelDiscard` on
    every path out** of `deadlined` — the `Select` owns locals, and returning with a task still live
    is a use-after-return that will not reproduce under test; (2) **`concurrent`, never `async`** —
    the async path silently runs the function inline when it is out of budget, which would make the
    deadline do nothing; (3) the **allocator must be an arena**, because a cancelled task's result is
    discarded without being freed (and it is not threadsafe to touch that arena from the calling
    thread while the request is in flight); (4) the error is **`DeadlineExceeded`, not `Timeout`** —
    `error.Timeout` is already reachable from `Io.net`, so it could not tell a deadline from a
    kernel ETIMEDOUT. `timeout_ms: 0` short-circuits before any `Select` exists. A deadline records
    **no** `ApiError`, so `lastError()` is not clobbered. If `concurrent` is ever refused, the
    request runs inline with no deadline and `deadline_unavailable` (an atomic — the TUI writes it
    from a worker and reads it on the loop thread) is set: the CLI prints one stderr warning, the
    TUI a status-line note; this file still never prints. `main.zig`'s
    `test "every HTTP call site is deadlined"` is what keeps the chokepoint single.
- `src/api/types.zig` — API wire types (`GetResponse`, `AddRequest`, `UpdateOp`, `AddResponse`,
  `UpdateResponse`, etc.).
- `src/tui/` — the interactive client (`seshat tui`). **Five files, split on one boundary:
  `ledger.zig`, `editors.zig` and `model.zig` never import vaxis and do no I/O; `render.zig` and
  `app.zig` own the terminal and make no product decisions.** That line is why a TUI is testable
  at all here — every rule that could be wrong lives on the pure side, and the shell is the part
  a human has to eyeball. Keep it: a threshold that appears in `render.zig`, or a `vaxis.` in
  `model.zig`, is the regression.
  - `ledger.zig` — the ranking/folding core. `Score` per task (`own`/`sub` urgency, `attention`
    and `descendants` counts, `all_complete`, `matches`/`self_matches`) computed by a memoized,
    cycle-safe post-order `walk`; `needsAttention` (high priority, or due within 3 days — the
    same bucket boundary `view.dueFactor` uses, so "soon" cannot mean two things); `buildRows`
    (the flattened, ordered row list, auto-expanding only subtrees that contain attention,
    emitting a `(+n)` badge otherwise, and gating an orphan pass on `filtering`); `Folds`
    (explicit per-id overrides); `layoutFor` + `chrome_rows` + `pane_min_rows` (how many rows
    the ledger and the detail pane get). Both constants live here *because* two files have to
    agree on them: `chrome_rows` is subtracted identically by `render.draw` and
    `model.recompute`, and `pane_min_rows` is the floor on an open pane, which must be at least
    the number of `FieldId`s `render.drawPane` paints — the pane does not scroll, so a shorter
    one hides its last field while the focus still moves onto it. `render.zig` asserts the two
    numbers match at comptime.
  - `editors.zig` — `Key` (the model's terminal-free key union, declared HERE and re-exported by
    `model.zig`), `LineEditor` (a UTF-8-boundary-safe single-line buffer) and `PickEditor` (a
    wrapping index over an enum's declaration order).
  - `model.zig` — the state and the event handler: `Model` (three arenas — `live`/`spare`
    double-buffer the task set and its `Index`, `ids` is never reset and holds the cursor id,
    fold keys, `filter_expr` and the filter's tag/status slices), `Mode`
    (`list`/`field`/`editing`/`filter`/`add`/`confirm_delete`), `InFlight` (at most **one**
    outstanding mutation — a refused key is dropped, never queued), `Event`, `Command`, and
    `update(gpa, m, ev) !Command`. `recompute` is the single funnel: select → score → rank →
    rows → re-resolve the cursor → scroll. Reuses `core/edit.zig`'s `Patch`/`applyPatch`/
    `parseDate`/`validate` and `core/filterspec.zig` unchanged.
  - `render.zig` — paints a `Model` onto a `vaxis.Window`: header (scope · sort · rows n–m of N ·
    overdue count · `saving…`), ledger, optional detail pane, rule, footer (prompt > status line >
    key bar). Maps `core/display.zig`'s `Style` to a `vaxis.Style` — that mapping is the only
    place the TUI decides how a *task* looks, and TUI-only styling (cursor bar, focus highlight,
    badge) stays local here rather than becoming a `display.Style` variant.

    **One signal, one surface:** the header's `saving…` means *a write is outstanding* and nothing
    else — a refresh gets no header marker, because `refreshing…` on the status line already
    reports it and that is the surface the user reads. (This marker lost that argument once
    already: for a refused connection it lives for milliseconds, which is what made `R` look like
    a dead key.) **A prompt does not swallow the status:** `drawPrompt` draws `m.status()`
    right-aligned on the prompt's own line, message first so the prompt overpaints it, with one
    blank column reserved between — a rejected `/` or `a` keeps its typed text *and* says why.

    Seven tests, all of invariants rather than of aesthetics and every one added after a human
    found the thing broken at a terminal: cell strings must outlive `draw` (libvaxis cells borrow
    them); every field the model can focus must get a painted focus bar; the `#handle` column
    (right-aligned, width = `m.handle_len + 1` read off the model, one blank gap column always)
    must line up whatever the row depth, keep that gap at every handle width, and never cost the
    title — extras are dropped due-wording-first, badge-second, and the title is the last thing to
    go; anything the model puts on the status line must be reachable on screen *including while a
    prompt owns the footer*; and a refresh must be reported on exactly one surface.
    None needs a TTY — a `vaxis.Window` only needs a `Screen`.
  - `app.zig` — the shell: `vaxis.Loop`, the key translation table (`toKey`, **named keys tested
    before `.text`** — Enter also carries `text = "\r"`), execution of `Command`s on a worker via
    `io.async` with one arena per request (freed on the loop thread *after* `update` consumed the
    event), and the `$EDITOR` suspend (`loop.stop()` first, `tty.deinit()` before re-init; the
    three *decisions* inside it — which editor, what counts as a cancel, what counts as content —
    are pure functions with unit tests, and `spawnEditor` — the one *step* that needs no
    terminal — is tested by actually spawning something harmless).

  **Keymap** (also shown in the footer key bar):

  | Mode | Keys |
  | --- | --- |
  | list | `j`/`k` or `↓`/`↑` move · `l`/`h` or `→`/`←` expand/collapse · `Ctrl-D`/`Ctrl-U` page · `g`/`G` first/last · `Space` cycle status · `a` add · `x` delete · `/` filter · `Tab` toggle pane · `R` refresh · `Esc` clear filter · `⏎` descend to fields · `q` quit |
  | field | `↑`/`↓` change field · `⏎` edit · `Esc` back to the list (**closes the detail pane** — leaving the task closes it, unconditionally) |
  | editing | `⏎` save · `Esc` cancel (back to the field, not the list); `←`/`→` **or** `↑`/`↓` choose in a picker; everything else goes to the editor |
  | filter / add prompt | `⏎` apply/create · `Esc` cancel · line editing (`←`/`→`/`Home`/`End`/`Backspace`/`Delete`) |
  | confirm delete | `y` delete · `n` or `Esc` cancel |

  Four editor kinds behind `⏎`: a **line** editor (title), a **picker** (status, priority), a
  **date** line editor accepting everything `core/edit.zig`'s `parseDate` does, and **`$EDITOR`**
  for the description (`$VISUAL` → `$EDITOR` → the first of `vi`/`vim`/`nvim`/`nano` that is
  actually **on PATH**, split on whitespace; a non-zero exit or unchanged text is a cancel).
  The fallback is probed rather than hardcoded to `vi` because Arch ships `vim` with no `vi`
  symlink, which made every description edit fail with an opaque `FileNotFound`; a `$VISUAL`/
  `$EDITOR` the user set is never probed, and the failure message names the program it tried.
  Refresh is **manual** (`R`, which writes `refreshing…` so a retry that fails again is
  distinguishable from a dead key) — there is no polling; see `plans/todo.md`. A refresh can now
  also fail on a deadline: `server did not respond within 10 s` on the status line. Quitting with a
  request still in flight now blocks for at most `timeout_ms` while it drains; `timeout_ms: 0`
  removes that bound too, so `q` waits for the request instead.

  The **status line is transient**. The footer shows `m.status()` *instead of* the key bar, so a
  message that is never taken back costs the user their keymap for the rest of the session.
  `model.retractStatus` clears it on the next keypress, with two exceptions: while something is
  in flight (`refreshing…`, `still saving…`, `deleting — …`), which the reply retracts rather
  than a key; and in `.confirm_delete`, where the status line *is* the question `y`/`n` answers.
  That is a separate mechanism from `tasks_loaded`'s narrow retraction of `refreshing_status` —
  an in-flight marker has to die when its request lands even if no key is touched, and clearing
  unconditionally there eats `deleted`, whose own refetch arrives at the same handler.
  A status set while a prompt is open (`applyFilter`'s `not a filter: …`, `submitAdd`'s
  `a title cannot be empty`, a `request_failed` that keeps the typed title) is still shown —
  `render.drawPrompt` puts it right-aligned on the prompt's line. Both of those handlers keep
  the prompt open *on purpose* so the typo can be fixed in place; a message that never renders
  makes Enter look like a dead key.
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

### libvaxis 0.6.0 (verified against the real API, not guessed)

Added as the `vaxis` dependency in `build.zig.zon`, pinned to a commit sha (not a tag — see below).
Imported as `@import("vaxis")` from `src/tui/render.zig` and `src/tui/app.zig` (the only two files
allowed to — see the `src/tui/` boundary above), wired in `build.zig` via
`b.dependency("vaxis", .{ .target = b.graph.host, .optimize = .Debug })` then
`.root_module.addImport("vaxis", vaxis_dep.module("vaxis"))` on **both** the exe and the test
artifact. Pulls in `zigimg` (non-lazy) and `uucode` (lazy) transitively — three packages total,
matching upstream's own `build.zig.zon`. It is what makes the binary ~35 MB.

The notes below were established with a throwaway `src/spike.zig` (`zig build spike`), which has
since been **deleted** — the real TUI subsumes it, and a second reachable `main` next to the CLI
is a liability. Re-verify against the installed dependency source (`~/.cache/zig/p/…`), not
against a spike that no longer exists.

**Pinning note:** upstream `rockorager/libvaxis` has no `v0.6.0` git tag (`git ls-remote --tags`
tops out at `v0.5.1`), but `main`'s current HEAD already declares `.version = "0.6.0"` in its own
`build.zig.zon` with exactly the expected non-lazy-zigimg/lazy-uucode shape. `build.zig.zon` here
pins to that HEAD commit sha directly (an immutable sha, not a moving branch ref) rather than a
tag. If upstream later tags `v0.6.0` on a different commit, or moves `main` past this state, re-fetch
and re-verify against the notes below before trusting them.

The 0.16 `std.Io`-threaded model applies throughout — same pattern as the rest of this codebase.

- **`Tty`:** platform-selected type (`vaxis.Tty` = `PosixTty` on Linux). `Tty.init(io: std.Io,
  buffer: []u8) !Tty` opens `/dev/tty` and puts it in raw mode (fails with `error.NoDevice` if
  there's no controlling terminal — expected in a sandboxed/CI shell, not a compile error).
  `tty.deinit()` (value receiver) restores the original termios. `tty.writer()` takes a `*Tty`
  receiver and returns `*std.Io.Writer` — every `Vaxis` write call (`enterAltScreen`, `render`,
  `resize`, `deinit`) takes that same `*std.Io.Writer`, not the `Tty` itself. `tty` must therefore
  be declared `var`, not `const`.
- **`vaxis.init`:** `vaxis.init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map,
  opts: Vaxis.Options) !Vaxis`. `init.environ_map` from `std.process.Init` is already `*Environ.Map`
  so it passes straight through unchanged. `alloc` must be a real `std.mem.Allocator` —
  `init.arena` in `std.process.Init` is a `*std.heap.ArenaAllocator`, **not** an `Allocator`; pass
  `init.arena.allocator()` (same pattern `main.zig` already uses). `Vaxis.Options` has **two**
  fields, both optional to set: `kitty_keyboard_flags: KittyFlags = .{}` and an optional
  `system_clipboard_allocator: ?std.mem.Allocator = null` (without it, system-clipboard requests
  aren't possible). `Vaxis.Options{}` (empty) is fine for a plain TUI. `KittyFlags` is a `packed
  struct(u5)` controlling what the Kitty keyboard protocol negotiation reports:
  `disambiguate: bool = true` (distinguishes e.g. Ctrl+I from Tab), `report_events: bool = false`
  (emit `key_release` events, not just `key_press` — off by default), `report_alternate_keys: bool
  = true` (populates `shifted_codepoint`/`base_layout_codepoint`), `report_all_as_ctl_seqs: bool =
  true`, `report_text: bool = true` (populates `Key.text`). A later task wanting key-release events
  or tighter disambiguation tunes these via `Vaxis.Options{ .kitty_keyboard_flags = .{ ... } }`.
- **`vx.deinit`:** `deinit(self: *Vaxis, alloc: ?std.mem.Allocator, tty: *std.Io.Writer) void` —
  resets terminal state (exits alt screen, shows cursor, etc.) and, if `alloc` is non-null, frees
  Vaxis-owned buffers. Pass the same `tty.writer()` used elsewhere.
- **`Loop` construction:** `Loop(T)` is *not* built as a plain struct literal — it has a required
  `init` function because one field (`queue: Queue(T, 512)`) itself needs initializing:
  `var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);` (positional: `io`, `*Tty`, `*Vaxis`). The
  brief's struct-literal form (`.{ .io = io, .tty = &tty, .vaxis = &vx }`) compiles-by-accident
  only if `queue`'s default is legal, which it isn't (no default) — use `.init(...)`.
  - `loop.start() !void` spawns a background thread (`io.concurrent`) that reads the tty and posts
    parsed events into the internal queue. On a non-Windows posix tty it also immediately posts one
    synthetic `.winsize` event with the current size before entering its read loop — so the very
    first `nextEvent()` after `start()` is reliably a winsize, useful for sizing the screen before
    the first render.
  - `loop.installResizeHandler() !void` / `loop.uninstallResizeHandler()` separately register/remove
    a SIGWINCH handler so *later* terminal resizes also produce `.winsize` events (not automatic
    from `start()` alone; call it once after `start()`).
  - `loop.stop() void` sets a quit flag, nudges the tty with a bogus write to unblock the read, and
    joins the background thread. No error return — safe to call from a `defer`.
  - `loop.nextEvent() !T` blocks until an event is available (note: `!T`, must be `try`'d — the
    brief's example omitted the `try`). `loop.postEvent(event: T) !void` pushes synthetically
    (blocks if the 512-deep queue is full); `loop.tryPostEvent` is the non-blocking form.
  - The `Event` union you pass as `T` only needs the variants you care about — `Loop` uses
    `@hasField(Event, "key_press")` etc. internally and silently drops event kinds your union
    doesn't declare a field for.
- **`Window.printSegment(segment: Segment, opts: PrintOptions) PrintResult`:** exact match for the
  brief's guess — a one-`Segment` shortcut for `print(&.{segment}, opts)`. `Segment = struct { text:
  []const u8, style: Style = .{}, link: Hyperlink = .{} }`. `PrintOptions` has `row_offset`/
  `col_offset` (both default 0), `wrap: enum { grapheme, word, none } = .grapheme`, and `commit:
  bool = true` (set false to measure without drawing). Returns `PrintResult{ col, row, overflow:
  bool }` — non-void, so a bare call needs `_ = win.printSegment(...)`.
- **`PrintResult.col` under `wrap = .none` is exactly the next free column**, i.e. where a
  following run would start. The `.none` branch just accumulates `col +|= w` per grapheme and
  returns it. This is what lets one screen row be composed left-to-right out of differently-styled
  runs by chaining `col = put(win, y, col, text, style)` — no width bookkeeping of your own.
  **Under the default `.grapheme` wrap the same field is reset to 0 (and `row` bumped) on
  overflow**, so the identical chain silently corrupts the row. If you are chaining, `.none` is
  load-bearing, not a stylistic choice.
- **`Window.gwidth(str: []const u8) u16`:** the terminal-capability-aware display width of a
  string (uses the screen's `width_method`). Two uses in `tui/render.zig`: reserving the trailing
  columns of a ledger row before handing the remainder to `display.truncate`, and converting a
  `LineEditor`'s **byte** cursor into a **column** for `showCursor`.
- **`Window.showCursor(col: u16, row: u16)` / `Window.hideCursor()`:** set/clear the screen's
  cursor position and visibility. `showCursor` already adds the window's own `x_off`/`y_off` and
  silently no-ops when the coordinate falls outside the window, so a prompt drawn in a 1-row footer
  child can pass plain window-local coordinates with no clamping. `render.draw` calls
  `win.hideCursor()` up front and only an open prompt/line editor turns it back on.
- **`Window.child(opts: ChildOptions) Window`:** field names are `x_off: i17 = 0`, `y_off: i17 = 0`,
  `width: ?u16 = null` (null = "fill remaining", not a magic sentinel — confirms the v0.5.0
  changelog's stated breaking change already landed), `height: ?u16 = null`, and `border:
  BorderOptions = .{}` (itself `{ style: Cell.Style = .{}, where: union(enum) { none, all, top,
  right, bottom, left, other: Locations } = .none, glyphs: ... = .single_rounded }`) for an
  optional inline border drawn as part of the child.
- **`Window.clear()`:** `self.fill(.{ .default = true })` — fills the window with default (blank,
  unstyled) cells.
- **`win.width` / `win.height`:** plain `u16` fields directly on `Window` (not methods).
- **`vx.enterAltScreen(tty: *std.Io.Writer) !void` / `vx.exitAltScreen(tty) !void`:** write the
  `smcup`/`rmcup` control sequences and flush; set/clear `vx.state.alt_screen`. `deinit` already
  calls the alt-screen-exit + full terminal reset via `resetState`, so an explicit `exitAltScreen`
  before `deinit` is optional (belt-and-suspenders) but not required.
- **`vx.resize(alloc, tty: *std.Io.Writer, winsize: Winsize) !void`:** (re)allocates the internal
  screen buffers to the new size and issues a hardware clear. **Must be called at least once
  before the first `vx.render`** — `Vaxis.init` starts with a zero-size screen
  (`screen = .{}`), and `render` asserts `screen.buf.len == width*height`. In practice the loop's
  automatic first `.winsize` event (see above) makes this happen naturally if the event loop drives
  `resize` before the first `window()`/`render()` call.
- **`vx.render(tty: *std.Io.Writer) !void`:** diffs the current screen against the last-rendered
  one and writes only the changed cells + escape codes, then flushes.
- **`vx.window() Window`:** returns a `Window` spanning the whole current screen
  (`x_off/y_off = 0`, `width/height = screen.width/height`).
- **`vaxis.Key` shape:** `{ codepoint: u21, text: ?[]const u8 = null, shifted_codepoint: ?u21 =
  null, base_layout_codepoint: ?u21 = null, mods: Modifiers = .{} }`. `Modifiers` is a packed
  struct: `shift, alt, ctrl, super, hyper, meta, caps_lock, num_lock: bool`. **`text` lifetime
  hazard (upstream-documented, on `Key.matchText`):** `text` points into the parser's per-event
  scratch buffer and is only valid until the next event is decoded — a caller that retains a `Key`
  past that point (e.g. queues it to another thread) must copy `text` first, or it races the parser
  overwriting its buffer. This is safe on the path Task 18 will actually use: `Loop`'s internal
  `handleEventGeneric` runs `mut_key.text = cache.put(text)` through a `GraphemeCache` before
  posting the event to the queue `nextEvent()` reads from, so `text` on an event you get back from
  `loop.nextEvent()` is already a stable, cache-owned copy, not the raw scratch-buffer slice. Named
  key constants
  are plain `u21` values on the `Key` (i.e. `vaxis.Key`) namespace — `vaxis.Key.enter` (`0x0D`),
  `.tab`, `.escape`, `.space`, `.backspace`, plus a large block of Kitty-protocol-encoded values in
  the Unicode private-use area for `.up/.down/.left/.right/.home/.end/.page_up/.page_down/.insert/
  .delete/.f1`–`.f35`/keypad keys/modifier keys — there is no `vaxis.Key.up` as an enum tag, they're
  all `u21` constants compared via `matches`, not switched on directly.
  `key.matches(cp: u21, mods: Modifiers) bool` — the brief's `k.matches('q', .{})` compiles as-is
  (ordinary chars are just their ASCII/Unicode codepoint). It does a 3-way loose match: exact
  codepoint+mods (ignoring caps/num lock), the key's generated `text` against the UTF-8 encoding of
  `cp` (ignoring shift/caps/num lock — handles e.g. shifted symbol keys), and `shifted_codepoint`
  match with shift removed. `matchesAny(cps, mods)` checks a slice; `isModifier()` reports whether
  the key itself *is* a bare modifier press.
- **`vaxis.Style` shape:** `{ fg: Color = .default, bg: Color = .default, ul: Color = .default,
  ul_style: Underline = .off, bold: bool = false, dim: bool = false, italic: bool = false, blink:
  bool = false, reverse: bool = false, invisible: bool = false, strikethrough: bool = false }`.
  `Color = union(enum) { default, index: u8, rgb: [3]u8 }` — a 16/256-color index is
  `.{ .fg = .{ .index = 1 } }` (as the brief guessed), true color is `.{ .fg = .{ .rgb = .{ r, g, b
  } } }`. `dim` and `bold` both exist as independent `bool` flags directly on `Style` (not part of
  `Color`) — relevant for Task 17's `core/display.Style` → `vaxis.Style` mapping.
