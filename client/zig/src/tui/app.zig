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
//! Almost nothing here is unit tested, by design: a loop's behaviour is a
//! terminal. The `test { refAllDecls }` at the bottom exists mainly to force the
//! compiler to ANALYSE these function bodies — a test build analyses only what a
//! `test` block reaches, and a bare `_ = @import(...)` does not force analysis of
//! function bodies. `refAllDecls` only reaches `pub` decls, i.e. `run`, and every
//! helper below is reachable from `run`, so a type error anywhere in this file
//! fails `zig build test` with a reference trace. Keep it that way: a helper
//! nothing calls is a helper nothing typechecks.
//!
//! The exception is the $EDITOR suspend, whose *decisions* (which editor, what
//! counts as a cancel) were deliberately factored out of the terminal handling
//! into pure functions so they can be tested at all — see the bottom of the file.
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

// ─── the external editor ─────────────────────────────────────────────────────

// The parts of the shell that only `.open_editor` needs: the terminal it hands
// over, the environment it reads $VISUAL/$EDITOR out of, and the model it seeds
// the buffer from. Bundled so `execute` keeps a signature a human can read.
const Shell = struct {
    tty: *vaxis.Tty,
    // TTY OWNERSHIP. `vaxis.Tty` has no "already closed" state — `deinit` calls
    // `tcsetattr` and `close` unconditionally — so the one thing that closes it
    // and reopens it has to say whether the reopen worked. True iff `tty` holds
    // an open handle; `run`'s teardown closes it only then, because closing the
    // same descriptor twice can take out an unrelated one a worker has since
    // opened.
    tty_live: *bool,
    vx: *vaxis.Vaxis,
    env: *const std.process.Environ.Map,
    m: *const model.Model,
};

// A description is task text, not a document. A megabyte is a generous ceiling
// that still refuses to slurp whatever the user pointed $EDITOR at by mistake.
const max_description_bytes = 1024 * 1024;

// The text $EDITOR last handed back, when this descent is a RETRY rather than a
// first open. Seeding a retry from the SERVER's description would silently
// replace the user's work with the value they were editing away from — the one
// field edited outside the TUI would be the one field where a dropped
// connection costs the whole edit.
//
// HONEST NOTE: on every path `model.zig` has TODAY this returns null, because
// `openEditor` builds a fresh `.{ .external = null }` on each descent from the
// field level — Escape is a deliberate discard, and the lossless retry is Enter
// on the restored editor, which never re-enters $EDITOR at all. This is the
// guard that keeps that from silently becoming a data-loss bug if a later task
// adds a "reopen the editor" key.
fn retainedText(m: *const model.Model) ?[]const u8 {
    if (m.mode != .editing) return null;
    const e = m.mode.editing;
    if (e.field != .description) return null;
    if (e.editor != .external) return null;
    return e.editor.external;
}

// $VISUAL, then $EDITOR, then `vi` — the conventional chain, most specific
// first: $VISUAL is the full-screen editor, which is exactly what a terminal we
// have just handed back wants.
fn editorCommand(env: *const std.process.Environ.Map) []const u8 {
    if (nonBlank(env.get("VISUAL"))) |v| return v;
    if (nonBlank(env.get("EDITOR"))) |v| return v;
    return "vi";
}

// Blank counts as unset: `EDITOR=` is how a shell profile disables one, and
// there is nothing in `"   "` to spawn either.
fn nonBlank(v: ?[]const u8) ?[]const u8 {
    const s = std.mem.trim(u8, v orelse return null, " \t");
    return if (s.len == 0) null else s;
}

// The editor plus the file, as argv.
//
// The configured value is SPLIT ON WHITESPACE, because `EDITOR="code --wait"`,
// `EDITOR="nvim -u NONE"` and `EDITOR="emacsclient -nw"` are ordinary settings,
// not exotic ones — treating the whole string as one program name turns any of
// them into an opaque spawn failure at the moment the user tries to edit.
//
// LIMIT, deliberate: this is a plain split, not a shell. A value whose arguments
// contain quoted embedded spaces (`EDITOR='code --wait --user-data-dir "/my
// dir"'`) is not supported and will be split mid-argument. Real quoting means
// either a parser or handing the string to `sh -c`, and `sh -c` would put a
// shell between the user and their terminal for the sake of a rare case.
fn editorArgv(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    path: []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    // `tokenizeAny` drops empty tokens, so runs of spaces collapse on their own.
    var words = std.mem.tokenizeAny(u8, editorCommand(env), " \t");
    while (words.next()) |word| try argv.append(alloc, word);
    // `editorCommand` never returns blank, so there is always at least one word
    // before this and `argv[0]` is never the file itself.
    try argv.append(alloc, path);
    return argv.toOwnedSlice(alloc);
}

// The cancel decision, kept pure so it can be tested without a terminal: a
// non-zero exit (or a killed editor) and text that came back unchanged are both
// "the user did not ask for this to be saved" (spec §5).
fn editedText(term: std.process.Child.Term, initial: []const u8, text: []const u8) ?[]const u8 {
    if (term != .exited or term.exited != 0) return null;
    if (std.mem.eql(u8, text, initial)) return null;
    return text;
}

// DELIBERATE DEVIATION from the letter of "byte-identical". Nearly every editor
// terminates the last line on save, so a description seeded WITHOUT a trailing
// newline comes back WITH one even when the user typed nothing — which would
// make the very first `$EDITOR` visit to every task a spurious commit that
// appends a blank line. One trailing newline is file-format convention, not
// content, so it is dropped before both the comparison and the commit.
fn stripFinalNewline(text: []const u8) []const u8 {
    if (std.mem.endsWith(u8, text, "\n")) return text[0 .. text.len - 1];
    return text;
}

// A single-use path in the system temp directory. UNPREDICTABLE by
// construction: a fixed or pid-derived name in a world-writable directory is a
// symlink-attack target — whoever wins the race owns whatever the create call
// then follows. 128 bits of CSPRNG entropy from `io.random` (0.16 has no
// `std.crypto.random`; entropy comes off the `std.Io` instance, and a
// clock-seeded `DefaultPrng` would be guessable by exactly the attacker who
// cares) plus `.exclusive` on the create, so a name that somehow already exists
// is an error rather than a silent hijack.
fn tempPath(io: std.Io, alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const dir = nonBlank(env.get("TMPDIR")) orelse "/tmp";
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const nonce = std.mem.readInt(u128, &bytes, .little);
    return std.fmt.allocPrint(alloc, "{s}/seshat-{x}.md", .{ dir, nonce });
}

// Take the terminal back. Deliberately infallible: it runs from a `defer` on
// every path out of `runEditor`, including the failing ones, and there is
// nothing useful to do with an error — a complaint about a terminal we could not
// restore would be printed into that same terminal.
//
// `sh.tty_live` is the whole reason this can fail safely. It is FALSE on entry
// (`runEditor` closed the handle) and only goes true again once a new one
// exists, so a failed re-init leaves `run`'s teardown correctly believing there
// is nothing left to close. The session is over either way — the next
// `vx.render` writes to a dead handle, fails, and unwinds `run` — but it ends
// without closing a descriptor a worker may since have been given.
fn resumeTui(io: std.Io, sh: Shell, loop: *Loop, tty_buf: []u8) void {
    const tty = sh.tty;
    const vx = sh.vx;
    tty.* = vaxis.Tty.init(io, tty_buf) catch |err| {
        std.log.err("could not reacquire the terminal: {s}", .{@errorName(err)});
        return;
    };
    sh.tty_live.* = true;
    vx.enterAltScreen(tty.writer()) catch {};
    loop.start() catch {};
    // Separate from `start()` — see client/zig/CLAUDE.md. A no-op today (the
    // Loop remembers `resize_handler_installed` across a stop/start, and
    // `Tty.deinit` does not clear vaxis's process-global handler), kept so this
    // is a true mirror of `run`'s startup and stays correct if either does.
    loop.installResizeHandler() catch {};
    // `smcup` hands back a CLEARED alt-screen buffer, but `vx.screen_last` still
    // describes what was on it before the suspend — so the next diff would emit
    // almost nothing onto a blank screen. Force a full repaint.
    vx.queueRefresh();
    // And the terminal may have been RESIZED while the editor owned it: the
    // SIGWINCH that reported it hit a closed handle. Re-report it through the
    // path the loop already has, which reallocates the screen and the model's
    // viewport together.
    if (tty.getWinsize()) |ws| {
        loop.postEvent(.{ .winsize = ws }) catch {};
    } else |_| {}
}

/// Suspend the TUI, hand the terminal to the user's editor, and take it back.
///
/// Returns the edited text (allocated from `alloc`), or `null` for CANCEL — the
/// editor exited non-zero, or the text came back unchanged (spec §5).
///
/// There is no vaxis suspend API; this composes one, and the ORDER is the whole
/// function. Two steps produce symptoms that surface nowhere near their cause:
///
///  1. **`loop.stop()` FIRST**, before anything is spawned. `stop` unblocks its
///     reader thread by writing a device-status-report and letting that thread
///     consume the terminal's reply. Spawn first and the EDITOR consumes the
///     reply instead — a stray escape sequence in its input, and a terminal that
///     misbehaves long after this function returned.
///  2. **`tty.deinit()` before the re-init.** `vaxis.Tty.init` installs a
///     process-global SIGWINCH handler and parks the Tty in a `global_tty`
///     singleton, so the old one has to be dead before a new one exists.
///
/// Everything after the `deinit` is wrapped. The resume runs from a `defer`, so
/// a temp file that will not open, a child that will not spawn and a read that
/// fails all still leave the user in a live TUI; the unlink runs from an
/// `errdefer`, so none of them leave task text sitting in /tmp.
fn runEditor(
    io: std.Io,
    alloc: std.mem.Allocator,
    sh: Shell,
    loop: *Loop,
    initial: []const u8,
) !?[]const u8 {
    const tty = sh.tty;
    const vx = sh.vx;

    // 1. Stop reading the tty before anything else can read it.
    loop.stop();

    // 2. Give the terminal back. The write buffer belongs to `run`'s frame and
    // outlives both Ttys, so capture it now — the re-init needs that same
    // storage, and a buffer owned by THIS frame would dangle the moment we
    // returned.
    const tty_buf = tty.writer().buffer;
    try vx.exitAltScreen(tty.writer());
    tty.deinit();
    // The handle is gone and nothing has replaced it yet. Held false across the
    // whole editor run, not just across the re-init, so the invariant reads
    // "`tty_live` is true iff `tty` holds an open handle" at every instant —
    // including a panic while the editor is up.
    sh.tty_live.* = false;

    // 5, registered before 3 and 4 can fail. Runs last on every path out.
    defer resumeTui(io, sh, loop, tty_buf);

    // 3. The temp file: 0600 so task text never sits in a world-readable /tmp,
    // exclusive so an attacker cannot have pre-placed the name, and seeded with
    // the BARE description — no comment header to strip back off.
    const path = try tempPath(io, alloc, sh.env);
    const seed_file = try std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        // `Permissions` is a non-exhaustive enum over the platform's mode type;
        // 0o600 is `-rw-------`.
        .permissions = @enumFromInt(0o600),
    });
    // The file exists from here on, so every exit has to take it away again —
    // registered before the seeding write, which can fail with it already there.
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        defer seed_file.close(io);
        try seed_file.writeStreamingAll(io, initial);
    }

    // 4. The editor owns the terminal for the duration — `.inherit` on all three
    // streams is what makes it a full-screen editor rather than something
    // drawing into a pipe. It is spelled out rather than defaulted because it is
    // the point. `argv[0]` is resolved against the parent's PATH.
    var child = try std.process.spawn(io, .{
        .argv = try editorArgv(alloc, sh.env, path),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);

    // 6. Read it back, then remove it whatever the answer turns out to be. The
    // editor may well have replaced the inode rather than rewritten it (vim's
    // default `backupcopy` renames), so this reopens the PATH rather than
    // rewinding the handle above.
    const raw = blk: {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        break :blk try file_reader.interface.allocRemaining(alloc, .limited(max_description_bytes));
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    return editedText(term, initial, stripFinalNewline(raw));
}

// ─── executing commands ──────────────────────────────────────────────────────

// A request arena, on the pending list before anything can fail with it
// half-built. After this returns, the LIST owns `req`: `retire` frees it once
// its event has been consumed, and `drainRequests` frees it at shutdown if no
// event ever arrives — so no caller needs an errdefer of its own.
fn newRequest(gpa: std.mem.Allocator, pending: *std.ArrayList(*Request)) !*Request {
    const req = try gpa.create(Request);
    errdefer gpa.destroy(req);
    req.* = .{ .arena = .init(gpa) };
    errdefer req.arena.deinit();
    try pending.append(gpa, req);
    return req;
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
    sh: Shell,
    cmd: model.Command,
) !void {
    switch (cmd) {
        .none, .quit => return,
        // `.open_editor` is NOT a network request: it hands the terminal over,
        // so it must run ON the loop thread, between two renders, and must never
        // touch a worker. It still reports back through an EVENT rather than
        // calling `update` itself, so the one place events are consumed stays
        // the one place events are consumed.
        .open_editor => |o| {
            const req = try newRequest(gpa, pending);
            const a = req.arena.allocator();
            const seed = retainedText(sh.m) orelse o.initial;
            const text = runEditor(io, a, sh, loop, seed) catch |err| {
                // A $EDITOR that will not start is a typo in a shell profile,
                // not a reason to tear the session down — and `runEditor`'s own
                // `defer` has already put the terminal back. End the descent as
                // a cancel so the user is not parked in an empty editor, then
                // say why. TWO requests because `retire` frees an arena as soon
                // as its event is consumed, and the message lives in one.
                const failure = try newRequest(gpa, pending);
                const msg = try std.fmt.allocPrint(
                    failure.arena.allocator(),
                    "could not run the editor ({s})",
                    .{@errorName(err)},
                );
                try loop.postEvent(.{ .result = .{ .req = req, .event = .{ .editor_returned = null } } });
                try loop.postEvent(.{ .result = .{ .req = failure, .event = .{ .request_failed = msg } } });
                return;
            };
            // `text` is arena-allocated, so it is alive until `retire` frees the
            // arena — which the loop only does after `update` has copied it.
            try loop.postEvent(.{ .result = .{ .req = req, .event = .{ .editor_returned = text } } });
            return;
        },
        else => {},
    }

    const req = try newRequest(gpa, pending);
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

    // The request is already on the pending list, which matters because
    // `io.async` is allowed to run the function inline (single-threaded builds,
    // or an exhausted thread pool), in which case the result event is already
    // posted by the time it returns.
    //
    // Nothing between here and the assignment can fail, so `req` is never
    // stranded with a future the loop will not await.
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
    // `runEditor` CLOSES this handle and opens a new one in its place, so the
    // teardown cannot be an unconditional `deinit`: if the reopen failed, `tty`
    // is a struct wrapped around a descriptor that is already gone, and closing
    // it again could take out one a worker has since been handed. `vaxis.Tty`
    // has no closed state of its own, so the flag is where that lives.
    var tty_live = true;
    defer if (tty_live) tty.deinit();

    var vx = try vaxis.init(io, gpa, env_map, .{});
    // Safe on a dead handle: `Vaxis.deinit` runs its terminal reset through
    // `resetState(tty) catch {}` and swallows the write failure.
    defer vx.deinit(gpa, tty.writer());

    // The terminal, the environment and the model, for the one command that
    // needs them: `.open_editor`. Built once — every field is a pointer to
    // something that outlives the loop below.
    const sh: Shell = .{ .tty = &tty, .tty_live = &tty_live, .vx = &vx, .env = env_map, .m = &m };

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
    try execute(io, gpa, client, &loop, &pending, sh, .fetch);

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
            try execute(io, gpa, client, &loop, &pending, sh, cmd);
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
    // Almost no unit tests here by design — see the file comment. This block is
    // the ONLY thing that gets these function bodies typechecked: a test build
    // analyses only what a `test` block reaches, and nothing in the executable
    // graph imports this file until the `tui` subcommand is wired up.
    // `refAllDecls` references `run`, and every helper above is reachable from
    // `run`.
    std.testing.refAllDecls(@This());
}

// The three DECISIONS inside the $EDITOR suspend that are not about the
// terminal — which editor to run, what counts as a cancel, and what counts as
// content. They are pure by construction so they can be checked here, because
// the rest of `runEditor` can only be checked by a human at a real terminal and
// these are exactly the parts that human is least likely to notice going wrong.

test "the editor is \\$VISUAL, then \\$EDITOR, then vi" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();

    try std.testing.expectEqualStrings("vi", editorCommand(&env));

    try env.put("EDITOR", "nano");
    try std.testing.expectEqualStrings("nano", editorCommand(&env));

    try env.put("VISUAL", "hx");
    try std.testing.expectEqualStrings("hx", editorCommand(&env));

    // `VISUAL=` is how a profile turns one off; it must fall THROUGH rather than
    // being spawned as the empty string.
    try env.put("VISUAL", "");
    try std.testing.expectEqualStrings("nano", editorCommand(&env));
    try env.put("EDITOR", "");
    try std.testing.expectEqualStrings("vi", editorCommand(&env));

    // Whitespace-only is blank too — and would otherwise split into NO words,
    // leaving the temp file itself as `argv[0]`.
    try env.put("EDITOR", "  \t ");
    try std.testing.expectEqualStrings("vi", editorCommand(&env));
}

test "a configured editor with flags becomes separate argv entries" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();

    // The default: one word, then the file.
    {
        const argv = try editorArgv(a, &env, "/tmp/x.md");
        defer a.free(argv);
        try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "vi", "/tmp/x.md" }), argv);
    }

    // The case a single-word spawn breaks on. `code --wait` is not exotic.
    try env.put("EDITOR", "code --wait");
    {
        const argv = try editorArgv(a, &env, "/tmp/x.md");
        defer a.free(argv);
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{ "code", "--wait", "/tmp/x.md" }),
            argv,
        );
    }

    // Surrounding and repeated whitespace must not produce empty argv entries.
    try env.put("VISUAL", "  nvim   -u   NONE  ");
    {
        const argv = try editorArgv(a, &env, "/tmp/x.md");
        defer a.free(argv);
        try std.testing.expectEqualDeep(
            @as([]const []const u8, &.{ "nvim", "-u", "NONE", "/tmp/x.md" }),
            argv,
        );
    }
}

test "a non-zero exit and unchanged text are both cancels" {
    // The happy path: exit 0 and the text moved.
    try std.testing.expectEqualStrings("new", editedText(.{ .exited = 0 }, "old", "new").?);

    // `:cq` in vim, or an editor that could not write.
    try std.testing.expect(editedText(.{ .exited = 1 }, "old", "new") == null);
    // Killed, so it never got to decide anything.
    try std.testing.expect(editedText(.{ .unknown = 9 }, "old", "new") == null);
    // Saved without changing anything: not a commit, and specifically not a
    // commit that would bump `updated_at` for nothing.
    try std.testing.expect(editedText(.{ .exited = 0 }, "same", "same") == null);
    // Emptying the description IS a change.
    try std.testing.expectEqualStrings("", editedText(.{ .exited = 0 }, "old", "").?);
}

test "one trailing newline is file format, not description content" {
    // The case that matters: seeded without a newline, saved untouched, and the
    // editor terminated the last line. That has to still be a cancel.
    try std.testing.expect(editedText(.{ .exited = 0 }, "body", stripFinalNewline("body\n")) == null);

    // Only ONE, so a deliberate blank last line survives.
    try std.testing.expectEqualStrings("body\n", stripFinalNewline("body\n\n"));
    try std.testing.expectEqualStrings("body", stripFinalNewline("body"));
    try std.testing.expectEqualStrings("", stripFinalNewline("\n"));
    try std.testing.expectEqualStrings("", stripFinalNewline(""));
}
