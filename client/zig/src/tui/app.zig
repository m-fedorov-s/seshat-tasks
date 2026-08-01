//! The shell: the libvaxis event loop, the keyboard translation table, and the
//! execution of the `Command`s `model.update` returns. This file MAKES NO
//! PRODUCT DECISIONS — no folding rules, no thresholds, no key *semantics*. It
//! translates terminal events into `model.Event`s, hands them to `update`,
//! performs whatever side effect `update` asked for, and repaints. Everything
//! about what a key MEANS lives in `model.zig`; everything about what the screen
//! LOOKS like lives in `render.zig`.
//!
//! Three invariants hold this file together:
//!
//!  1. **Named keys are tested before `.text`.** `vaxis.Key.enter` is codepoint
//!     0x0D and a plain Enter press also carries `text = "\r"`, so a `.text`-first
//!     table would deliver Enter as `{ .char = '\r' }` and every Enter-driven path
//!     in the model would silently stop working. See `toKey`.
//!  2. **A `Command`'s payloads BORROW from the model** (ids from the id arena,
//!     content strings from the live task arena, editor text from an editor
//!     buffer). A request runs off the loop, so the next `update` can invalidate
//!     any of them mid-flight. `execute` copies every byte a request needs into
//!     that request's OWN arena before the async call, never after.
//!  3. **A per-request arena outlives its own request.** The result event carries
//!     `[]const Task` allocated in it; `update` deep-copies what it keeps
//!     (`replaceTasks`/`mergeTasks`). So the arena is freed by the LOOP THREAD,
//!     after `update` has consumed the event — not when the request finishes, and
//!     never on the request thread. Freeing it earlier is a use-after-free inside
//!     the model; never freeing it is a leak per request.
//!
//! There are no unit tests here by design: a loop's behaviour is a terminal. The
//! `test { refAllDecls }` at the bottom exists only to force the compiler to
//! ANALYSE these function bodies — a test build analyses only what a `test` block
//! reaches, and a bare `_ = @import(...)` does not force analysis of function
//! bodies. `refAllDecls` references `run`, and every helper below is reachable
//! from `run`, so a type error anywhere in this file fails `zig build test` with a
//! reference trace. Keep it that way: a helper nothing calls is a helper nothing
//! typechecks.
//!
//! Note on Ctrl-C: libvaxis's `makeRaw` clears `ISIG`, so Ctrl-C arrives as an
//! ordinary keypress rather than a signal. `q` (handled by the model) is the way
//! out.
const std = @import("std");
const vaxis = @import("vaxis");

const api = @import("../api/client.zig");
const types = @import("../api/types.zig");
const taskmod = @import("../core/task.zig");
const Content = taskmod.Content;
const view = @import("../core/view.zig");
const model = @import("model.zig");
const render = @import("render.zig");

// The event union the loop reads. `Loop` uses `@hasField` internally and silently
// drops any terminal event kind we do not declare here, which is exactly the
// filter we want: keys, resizes, and our own posted results.
const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    result: Delivery,
};

const Loop = vaxis.Loop(AppEvent);

// ─── key translation ─────────────────────────────────────────────────────────

// The whole reason `model.Key` exists: the model never sees a vaxis type, and
// this is the single place a terminal key becomes a model key.
//
// ORDER IS LOAD-BEARING. Every named key is tested first; only then do we fall
// through to `.text`. The named constants are plain `u21` values on the
// `vaxis.Key` namespace (there is no enum to switch on), compared with
// `key.matches(cp, mods)`, which does a 3-way loose match (exact codepoint+mods,
// the generated text, and the shifted codepoint).
//
// Returning null means "this terminal event is not a key the model has an opinion
// about" — a bare modifier press, an unmapped function key, a key with no text.
// The loop drops those without disturbing the model.
fn toKey(k: vaxis.Key) ?model.Key {
    if (k.matches(vaxis.Key.enter, .{})) return .enter;
    if (k.matches(vaxis.Key.escape, .{})) return .escape;
    if (k.matches(vaxis.Key.tab, .{})) return .tab;
    if (k.matches(vaxis.Key.up, .{})) return .up;
    if (k.matches(vaxis.Key.down, .{})) return .down;
    if (k.matches(vaxis.Key.left, .{})) return .left;
    if (k.matches(vaxis.Key.right, .{})) return .right;
    if (k.matches(vaxis.Key.backspace, .{})) return .backspace;
    if (k.matches(vaxis.Key.delete, .{})) return .delete;
    if (k.matches(vaxis.Key.home, .{})) return .home;
    if (k.matches(vaxis.Key.end, .{})) return .end;
    if (k.matches('d', .{ .ctrl = true })) return .ctrl_d;
    if (k.matches('u', .{ .ctrl = true })) return .ctrl_u;

    // The ordinary typing path. `text` is set by both the legacy parser and the
    // Kitty protocol (libvaxis negotiates `report_text = true` by default), and
    // by the time an event reaches us through the loop it is a stable,
    // GraphemeCache-owned copy rather than the parser's scratch buffer — so a
    // `.char` handed to the model is safe to read for the duration of `update`.
    if (k.text) |txt| {
        const cp = std.unicode.utf8Decode(txt) catch return null;
        return .{ .char = cp };
    }

    // Safety net for a terminal that reports a printable key with no text at all.
    // Deliberately restricted to ASCII printables with no non-shift modifier: the
    // named keys above live in the Unicode private-use area (57344+), so this can
    // never shadow one, and Ctrl-<letter> must not become a typed character.
    if (k.codepoint >= 0x20 and k.codepoint < 0x7F and
        !k.mods.ctrl and !k.mods.alt and !k.mods.super and !k.mods.hyper and !k.mods.meta)
    {
        return .{ .char = k.codepoint };
    }
    return null;
}

// ─── requests ────────────────────────────────────────────────────────────────

// One in-flight request. `arena` owns EVERYTHING the request touches: the copied
// command payload, the HTTP connection buffers, the response body, and the parsed
// tasks the result event carries. It is destroyed by `retire`, on the loop
// thread, after `update` has consumed that event.
//
// `future` is written by the loop thread immediately after `io.async` returns and
// read only by the loop thread (in `retire`/`drainRequests`), so it never races
// the worker — which touches only `arena`, `client` and `loop`.
const Request = struct {
    arena: std.heap.ArenaAllocator,
    // A `Future` that was never handed to `io.async` awaits instantly, which is
    // what makes the failure paths in `execute` safe to unwind.
    future: std.Io.Future(void) = .{ .any_future = null, .result = {} },
};

// What the worker posts back: the model event, plus the identity of the arena
// that event's payload lives in.
const Delivery = struct {
    req: *Request,
    event: model.Event,
};

// A `model.Command` with every borrowed byte copied into the request arena. This
// type exists precisely so the copy is structural: there is no way to hand the
// worker a `Command` straight from `update`.
const Job = union(enum) {
    fetch,
    commit: struct { id: []const u8, expected_version: u64, content: Content },
    create: Content,
    delete: []const u8,
};

// Perform a job. Every allocation comes from `a` (the request arena), so the
// tasks handed back through the result event die with it.
fn perform(a: std.mem.Allocator, client: *api.Client, job: Job) !model.Event {
    switch (job) {
        .fetch => return .{ .tasks_loaded = try client.fetchTasks(a) },
        .commit => |c| {
            const ops = [_]types.UpdateOp{.{
                .id = c.id,
                .content = c.content,
                .expected_version = c.expected_version,
            }};
            // A 409 is an OUTCOME, not an error (api/client.zig): the server's
            // conflict body already carries the fresh tasks the model reconciles
            // against, and there is no single-task GET to fall back on.
            return switch (try client.updateTasks(a, &ops)) {
                .ok => |tasks| .{ .commit_ok = tasks },
                .conflict => |tasks| .{ .conflict = tasks },
            };
        },
        .create => |content| return .{ .create_ok = try client.addTask(a, content, null) },
        .delete => |id| {
            try client.deleteTask(a, id);
            return .delete_ok;
        },
    }
}

// Turn a failed request into the model's `.request_failed`.
//
// A non-2xx response is recorded on the Client rather than printed (a stray
// stderr write inside an alt screen corrupts the display), and that message is
// OWNED by the Client — valid until the next `recordError`/`clearError`. Only one
// request is ever outstanding (see `run`), so the next `recordError` cannot happen
// before `update` has copied this message into the status line.
//
// Anything else (a refused connection, a dropped socket, OOM) never reached the
// server at all, so `lastError()` would be stale or empty; those get the error
// name instead, formatted into the request arena.
fn failEvent(a: std.mem.Allocator, client: *api.Client, err: anyerror) model.Event {
    if (err == error.ApiFailed) {
        if (client.lastError()) |e| return .{ .request_failed = e.message };
    }
    const msg = std.fmt.allocPrint(a, "could not reach the server ({s})", .{@errorName(err)}) catch
        @errorName(err);
    return .{ .request_failed = msg };
}

// The worker body, run off the loop by `io.async` so rendering and input never
// wait on the network (spec §6). There is no request timeout: Zig 0.16's HTTP
// client has none (`RequestOptions` has no timeout field; the only `timeout` is a
// *connect* timeout on `ConnectTcpOptions`). Accepted — the requirement was that
// the LOOP stays responsive, and it does; a hung request costs the user the
// ability to start another mutation, not the ability to scroll or quit.
fn runRequest(client: *api.Client, loop: *Loop, req: *Request, job: Job) void {
    const a = req.arena.allocator();
    const ev: model.Event = perform(a, client, job) catch |err| failEvent(a, client, err);
    // Posting is the LAST thing the worker does, which is what makes the
    // `future.await` in `retire` return immediately rather than block the loop.
    // A failed post (the queue is 512 deep, so effectively only cancelation) just
    // means this request is reclaimed by `drainRequests` at shutdown instead.
    loop.postEvent(.{ .result = .{ .req = req, .event = ev } }) catch {};
}

// Execute the side effect `update` asked for.
//
// HAZARD 2 lives here: `cmd`'s payloads borrow from the model, and the next
// `update` can free or reset any of them while the request is still in flight.
// So every byte is copied into `req.arena` BEFORE `io.async` — never after, and
// never lazily on the worker.
fn execute(
    io: std.Io,
    gpa: std.mem.Allocator,
    client: *api.Client,
    loop: *Loop,
    pending: *std.ArrayList(*Request),
    cmd: model.Command,
) !void {
    switch (cmd) {
        .none, .quit => return,
        // ── Task 19 seam ────────────────────────────────────────────────────
        // `.open_editor` suspends the TUI, runs $EDITOR on a temp file, resumes,
        // and feeds the result back as `.editor_returned`. It is NOT a network
        // request and must not take a request arena or a worker thread — it has
        // to happen ON the loop thread, between two renders, because it hands the
        // terminal over. Task 19 owns it. Until then it is dropped: the model is
        // left in `.editing` with an empty `.external`, whose own Enter path
        // already says "nothing to save yet" and whose Escape backs out cleanly.
        .open_editor => return,
        else => {},
    }

    const req = try gpa.create(Request);
    errdefer gpa.destroy(req);
    req.* = .{ .arena = .init(gpa) };
    errdefer req.arena.deinit();
    const a = req.arena.allocator();

    const job: Job = switch (cmd) {
        .fetch => .fetch,
        .commit => |c| .{ .commit = .{
            .id = try a.dupe(u8, c.id),
            .expected_version = c.expected_version,
            .content = try dupeContent(a, c.content),
        } },
        .create => |content| .{ .create = try dupeContent(a, content) },
        .delete => |id| .{ .delete = try a.dupe(u8, id) },
        .none, .quit, .open_editor => unreachable, // returned above
    };

    // Registered BEFORE the call: `io.async` is allowed to run the function
    // inline (single-threaded builds, or when the thread pool is exhausted), in
    // which case the result event is already posted by the time it returns.
    try pending.append(gpa, req);
    // Nothing below can fail, so `req` is never stranded off the pending list.
    req.future = io.async(runRequest, .{ client, loop, req, job });
}

fn dupeContent(a: std.mem.Allocator, c: Content) !Content {
    return .{
        .title = try a.dupe(u8, c.title),
        .description = try a.dupe(u8, c.description),
        .status = c.status,
        .priority = c.priority,
        .child_ids = try dupeStrings(a, c.child_ids),
        .tags = try dupeStrings(a, c.tags),
        .due_at = c.due_at,
        .scheduled_at = c.scheduled_at,
    };
}

fn dupeStrings(a: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const out = try a.alloc([]const u8, src.len);
    for (src, out) |s, *d| d.* = try a.dupe(u8, s);
    return out;
}

// HAZARD 3: the only place a request arena is freed, and it runs on the LOOP
// THREAD, AFTER `update` has consumed the event whose payload lives in it.
//
// `await` is what actually reclaims the future (the Io implementation frees it
// there), so skipping it would leak a future and a unit of the thread pool's
// concurrency budget per request. It returns essentially immediately: the worker
// posts its event as its last act, so by the time we are holding that event the
// task is already returning.
fn retire(io: std.Io, gpa: std.mem.Allocator, pending: *std.ArrayList(*Request), req: *Request) void {
    for (pending.items, 0..) |p, i| {
        if (p == req) {
            _ = pending.swapRemove(i);
            break;
        }
    }
    req.future.await(io);
    req.arena.deinit();
    gpa.destroy(req);
}

// Shutdown. A worker holds pointers to `loop` and `client`, both of which die
// with `run`'s stack frame, so every outstanding request must be awaited before
// we return — awaiting is the only thing that proves the worker has stopped
// touching them. Its posted event lands in a queue nobody will read; that is
// fine, the queue is just memory and dies with the loop.
fn drainRequests(io: std.Io, gpa: std.mem.Allocator, pending: *std.ArrayList(*Request)) void {
    for (pending.items) |req| {
        req.future.await(io);
        req.arena.deinit();
        gpa.destroy(req);
    }
    pending.clearRetainingCapacity();
}

// ─── the loop ────────────────────────────────────────────────────────────────

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// Run the TUI until the model says `.quit`.
///
/// `env_map` is not in the task brief's signature but `vaxis.init` requires it,
/// and `std.process.Init` already hands `main.zig` exactly the `*Environ.Map` it
/// wants. The UTC offset comes from `client.config`, so it needs no parameter of
/// its own.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    client: *api.Client,
    filters: view.Filters,
    strategy: view.Strategy,
) !void {
    // HAZARD 4: `Client.deinit` frees the last recorded error message. Under the
    // CLI's process arena nobody missed it; here `gpa` is a real allocator and a
    // TUI session can record hundreds of failures, of which the last one would
    // leak. `recordError` frees the previous message itself, so this is the only
    // call needed — and it is idempotent.
    defer client.deinit();

    // In-place: a `Model` holds interior pointers and must never be copied.
    var m: model.Model = undefined;
    try m.init(gpa, nowSeconds(io), client.config.offset_minutes);
    defer m.deinit();
    // The caller's view configuration. These slices belong to the caller and
    // outlive `run`; the `/` prompt replaces them with id-arena copies of its own.
    m.filters = filters;
    m.strategy = strategy;

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, env_map, .{});
    defer vx.deinit(gpa, tty.writer());

    // `Loop` has a required `init` (its 512-deep queue has no default), so the
    // struct-literal form does not compile.
    var loop: Loop = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    // `start()` posts one synthetic winsize before its read loop; LATER resizes
    // need this handler as well.
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();

    var pending: std.ArrayList(*Request) = .empty;
    defer {
        // Registered after the loop's defers so it runs BEFORE them: the workers
        // must be joined while `loop` is still alive.
        drainRequests(io, gpa, &pending);
        pending.deinit(gpa);
    }

    try vx.enterAltScreen(tty.writer());
    // Capability detection (unicode width, rgb, kitty keyboard). The replies come
    // back through the loop's reader thread, so this must follow `start()`. A
    // terminal that never answers just leaves the conservative defaults in place.
    vx.queryTerminal(tty.writer(), .fromSeconds(1)) catch {};

    // `vx.resize` MUST run at least once before the first `vx.render` (Vaxis
    // starts with a zero-size screen and `render` asserts the buffer matches).
    // The loop's synthetic winsize normally does this, but it races the startup
    // fetch's result event, so size the screen explicitly and tell the model the
    // same thing. The synthetic event repeats both, harmlessly.
    const ws = try tty.getWinsize();
    try vx.resize(gpa, tty.writer(), ws);
    _ = try model.update(gpa, &m, .{ .resize = .{ .cols = ws.cols, .rows = ws.rows } });

    // The initial load. The model's one-mutation rule is enforced by
    // `in_flight`, so a request the SHELL starts has to be recorded there too —
    // otherwise `R` could start a second concurrent fetch, and two workers would
    // race on the Client's recorded error. `tasks_loaded` clears it again.
    m.in_flight = .refresh;
    try execute(io, gpa, client, &loop, &pending, .fetch);

    render.draw(vx.window(), &m);
    try vx.render(tty.writer());

    while (true) {
        const ev = try loop.nextEvent();

        // The clock is read ONCE per iteration and injected, so the model stays
        // I/O-free and relative dates cannot rot across midnight without a timer.
        m.now = nowSeconds(io);

        // Set when this iteration is delivering a request result: the arena that
        // result's payload lives in, to be freed once `update` has consumed it.
        var finished: ?*Request = null;

        const mev: ?model.Event = switch (ev) {
            .key_press => |k| if (toKey(k)) |mk| model.Event{ .key = mk } else null,
            .winsize => |size| blk: {
                try vx.resize(gpa, tty.writer(), size);
                break :blk model.Event{ .resize = .{ .cols = size.cols, .rows = size.rows } };
            },
            .result => |d| blk: {
                finished = d.req;
                break :blk d.event;
            },
        };

        if (mev) |e| {
            const cmd = try model.update(gpa, &m, e);
            // Only now. `update` has deep-copied everything it keeps out of the
            // request arena (`replaceTasks`/`mergeTasks` copy into the model's own
            // arenas, `setStatus` copies the message), so the arena is dead
            // weight from this line onward — and was live memory the model was
            // reading from on the line above.
            if (finished) |req| retire(io, gpa, &pending, req);
            if (cmd == .quit) break;
            try execute(io, gpa, client, &loop, &pending, cmd);
        } else if (finished) |req| {
            // Unreachable today (a `.result` always carries an event), but the
            // arena must not depend on that staying true.
            retire(io, gpa, &pending, req);
        }

        render.draw(vx.window(), &m);
        try vx.render(tty.writer());
    }
}

test {
    // No unit tests here by design — see the file comment. This block is the ONLY
    // thing that gets these function bodies typechecked: a test build analyses
    // only what a `test` block reaches, and nothing in the executable graph
    // imports this file until the `tui` subcommand is wired up. `refAllDecls`
    // references `run`, and every helper above is reachable from `run`.
    std.testing.refAllDecls(@This());
}
