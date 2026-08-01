//! The TUI's pure state: types, memory ownership, and nothing else. No I/O, and
//! it never imports vaxis — the shell (task 18) owns the terminal, this owns the
//! bytes. `update` is the event handler: it mutates the model and returns a
//! `Command` describing any side effect for the shell to perform.
const std = @import("std");
const taskmod = @import("../core/task.zig");
const Task = taskmod.Task;
const Content = taskmod.Content;
const Priority = taskmod.Priority;
const Status = taskmod.Status;
const view = @import("../core/view.zig");
const filterspec = @import("../core/filterspec.zig");
const display = @import("../core/display.zig");
const edit = @import("../core/edit.zig");
const ledger = @import("ledger.zig");
const editors = @import("editors.zig");

pub const Key = editors.Key;
pub const Viewport = struct { cols: u16 = 80, rows: u16 = 24 };

pub const FieldId = enum { title, description, status, priority, due, scheduled, tags };

pub const Editor = union(enum) {
    line: editors.LineEditor,
    pick: editors.PickEditor,
    // The description is edited OUT of process, so there is no in-process buffer
    // to type into — but the text $EDITOR handed back is OWNED here (gpa), so a
    // failed commit can give it back and Enter can retry it. Without that, the
    // one field edited outside the TUI was the one field where a dropped
    // connection cost the whole edit. `null` = nothing has come back yet.
    external: ?[]const u8,

    pub fn deinit(self: *Editor, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .line => |*le| le.deinit(gpa),
            .external => |retained| if (retained) |text| gpa.free(text),
            .pick => {},
        }
        // Retag to the empty variant so a second deinit is a no-op. NOTE: this is
        // the ONE ownership site the exhaustive, else-less switches above cannot
        // protect — it used to read `self.* = .external`, which stayed valid
        // shorthand for a payload-carrying variant only by accident of syntax.
        self.* = .{ .external = null };
    }
};

// The open-editor payload of `Mode.editing`. Named (rather than inline) so the
// handlers that mutate it in place can take a `*Editing` — an anonymous struct
// type has no spellable name to write in a signature.
//
// `id` is the task the editor was OPENED ON, interned like every other stored id.
// It is not a convenience copy of `cursor_id`: the commit path targets THIS id,
// never the cursor. The cursor is a viewport position and it moves on its own —
// `recompute` re-resolves it, and drops it onto a neighbour whenever the edited
// task's row disappears (a filter it no longer matches, a fold, a refresh). An
// editor that targeted the cursor would then write the user's typed text onto an
// unrelated task, at that task's version, and the server would accept it.
pub const Editing = struct { id: []const u8, field: FieldId, editor: Editor };

pub const Mode = union(enum) {
    list,
    field: FieldId,
    editing: Editing,
    filter: editors.LineEditor,
    add: editors.LineEditor,
    confirm_delete: struct { id: []const u8 }, // id is interned; `promotes` is
    // recomputed at confirm time
};

pub const InFlight = union(enum) {
    none,
    commit: struct { id: []const u8, field: FieldId, editor: Editor },
    create: struct { title: []const u8 },
    delete: struct { id: []const u8 },
    refresh,
};

// A Command's payloads BORROW from the model (ids from the id arena, content
// strings from the live task arena, editor text from an editor buffer). The
// shell must copy whatever it needs into the request's own arena before it
// returns control to `update` — the next event can swap the task set out from
// under any of these slices.
pub const Command = union(enum) {
    none,
    fetch,
    quit,
    commit: struct { id: []const u8, expected_version: u64, content: Content },
    create: Content,
    delete: []const u8,
    open_editor: struct { id: []const u8, initial: []const u8 },
};

pub const Event = union(enum) {
    key: Key,
    resize: Viewport,
    tasks_loaded: []const Task,
    commit_ok: []const Task,
    create_ok: Task,
    delete_ok,
    conflict: []const Task,
    request_failed: []const u8,
    editor_returned: ?[]const u8,
};

pub const Model = struct {
    gpa: std.mem.Allocator,

    // Task storage is DOUBLE-BUFFERED. A refresh builds the new task set and the
    // new Index into `spare`, then swaps, then resets the old one. This is what
    // makes "rebuild the Index before freeing the old task set" structural rather
    // than a rule someone has to remember (spec §12).
    live: *std.heap.ArenaAllocator,
    spare: *std.heap.ArenaAllocator,
    // Interned ids: cursor, fold keys, and every id held in Mode/InFlight — plus
    // the filter expression and the tag/status slices `filters` points at, which
    // are the same lifetime class (they outlive both the `filterspec.Parsed` they
    // were built from and the editor buffer that Parsed borrowed). Must outlive
    // task-set swaps, so it is a THIRD arena, never reset during a session.
    ids: *std.heap.ArenaAllocator,

    tasks: []Task = &.{},
    idx: view.Index = undefined,
    idx_built: bool = false,
    scores: ledger.Scores,
    rows: []ledger.Row = &.{},
    folds: ledger.Folds,

    // The selected task. ALWAYS a slice into the `ids` arena (see `internId`),
    // never a borrow of `Task.id` or `Row.id` — both of those point into the
    // live task arena, which the next `replaceTasks` resets.
    cursor_id: ?[]const u8 = null,
    // The cursor's last known ROW INDEX. Never a source of truth for what is
    // selected — `cursor_id` is — only the anchor `recompute` falls back to when
    // the selected task cannot be resolved, so the cursor drops to its old
    // neighbour instead of jumping to the top. It has to be a stored field
    // because `replaceTasks` retires `rows` before `recompute` runs, leaving no
    // row list to derive the old position from. Written in exactly two places:
    // snapshotted just before `replaceTasks` frees `rows`, and refreshed at the
    // end of `recompute`. May exceed `rows.len` after a shrink; every reader
    // clamps.
    cursor_anchor: usize = 0,
    filters: view.Filters = .{},
    filter_expr: []const u8 = "", // interned; drives the header and empty state
    filtering: bool = false,
    strategy: view.Strategy = .urgency,
    // The `#handle` tail length: the shortest id suffix that is unique across the
    // WHOLE fetched set. Derived state, recomputed by `recompute`; the default is
    // `view.minUniqueSuffixLen`'s own floor, for a model that has never had one.
    // It lives on the Model rather than in the renderer because computing it needs
    // an allocator and can fail, and `render.draw(win, m) void` has neither.
    handle_len: usize = 4,
    now: i64,
    offset_minutes: i32,

    mode: Mode = .list,
    in_flight: InFlight = .none,
    status_buf: std.ArrayList(u8) = .empty,
    load_failed: bool = false,
    pane_open: bool = false,
    scroll_top: usize = 0,
    viewport: Viewport = .{},

    // In-place init: a Model must never be returned or copied by value. Its hash
    // maps use `gpa` (stable), but the arenas are held by pointer and the struct
    // is large; in-place construction keeps every interior pointer valid.
    pub fn init(m: *Model, gpa: std.mem.Allocator, now: i64, offset_minutes: i32) !void {
        const live = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(live);
        live.* = .init(gpa);
        errdefer live.deinit();
        const spare = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(spare);
        spare.* = .init(gpa);
        errdefer spare.deinit();
        const ids = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(ids);
        ids.* = .init(gpa);
        m.* = .{
            .gpa = gpa,
            .live = live,
            .spare = spare,
            .ids = ids,
            .scores = ledger.Scores.init(gpa), // gpa, NOT an arena
            .folds = ledger.Folds.init(gpa), // gpa, NOT an arena
            .now = now,
            .offset_minutes = offset_minutes,
        };
    }

    pub fn deinit(m: *Model) void {
        // Derived state first: `rows` and `scores` keys borrow id slices out of
        // the live arena, so they must go before it does.
        m.gpa.free(m.rows);
        m.rows = &.{};
        m.scores.deinit();
        // `folds` keys borrow from the id arena; same rule, different arena.
        m.folds.deinit();
        // The Index's maps are gpa-allocated but keyed on live-arena slices.
        if (m.idx_built) {
            m.idx.deinit();
            m.idx_built = false;
        }
        m.status_buf.deinit(m.gpa);
        // Editor buffers are gpa-allocated and can outlive nothing else — but
        // they are the easiest leak in the whole struct, because they hide
        // inside a union that most code paths never look into.
        m.clearMode();
        m.clearInFlight();
        // Now the arenas, then the boxes holding them. `create`d separately in
        // init, so `destroy`d separately here.
        m.live.deinit();
        m.spare.deinit();
        m.ids.deinit();
        m.gpa.destroy(m.live);
        m.gpa.destroy(m.spare);
        m.gpa.destroy(m.ids);
        m.* = undefined;
    }

    // Drop the current mode, freeing any editor buffer it owns, and return to
    // the list. Every mode transition out of an editing state goes through here.
    pub fn clearMode(m: *Model) void {
        switch (m.mode) {
            .editing => |*e| e.editor.deinit(m.gpa),
            .filter, .add => |*le| le.deinit(m.gpa),
            .list, .field, .confirm_delete => {},
        }
        m.mode = .list;
    }

    // Same, for the in-flight request slot (`.commit` carries the editor the
    // request was built from, so a conflict can restore it).
    pub fn clearInFlight(m: *Model) void {
        switch (m.in_flight) {
            .commit => |*c| c.editor.deinit(m.gpa),
            .none, .create, .delete, .refresh => {},
        }
        m.in_flight = .none;
    }

    // Where the cursor currently sits in `rows`, or null if its task is not on
    // screen at all (filtered out, inside a collapsed subtree, or gone).
    pub fn cursorIndex(m: *const Model) ?usize {
        const id = m.cursor_id orelse return null;
        for (m.rows, 0..) |r, i| {
            if (r.kind == .task and std.mem.eql(u8, r.id, id)) return i;
        }
        return null;
    }

    pub fn status(m: *const Model) []const u8 {
        return m.status_buf.items;
    }

    pub fn setStatus(m: *Model, comptime fmt: []const u8, args: anytype) !void {
        m.status_buf.clearRetainingCapacity();
        try m.status_buf.print(m.gpa, fmt, args);
    }

    // Copy an id into the id arena. Every id stored in cursor_id, folds,
    // Mode, or InFlight goes through here.
    pub fn internId(m: *Model, id: []const u8) ![]const u8 {
        return m.ids.allocator().dupe(u8, id);
    }

    // Deep-copy `incoming` into `spare`, build the Index there, then swap and
    // reset. Never frees before the new Index exists.
    pub fn replaceTasks(m: *Model, incoming: []const Task) !void {
        const a = m.spare.allocator();
        // Nothing live points into `spare`, so on any failure below we can roll
        // it back wholesale and leave the model exactly as it was.
        errdefer _ = m.spare.reset(.retain_capacity);

        // Deep copy. The JSON parser hands back slices borrowed from the response
        // body, so a shallow copy would dangle the moment that body is freed.
        const copy = try a.alloc(Task, incoming.len);
        for (incoming, copy) |src, *dst| dst.* = .{
            .id = try a.dupe(u8, src.id),
            .content = .{
                .title = try a.dupe(u8, src.content.title),
                .description = try a.dupe(u8, src.content.description),
                .status = src.content.status,
                .priority = src.content.priority,
                .child_ids = try dupeStrings(a, src.content.child_ids),
                .tags = try dupeStrings(a, src.content.tags),
                .due_at = src.content.due_at,
                .scheduled_at = src.content.scheduled_at,
            },
            .meta = src.meta,
        };

        // Build the new Index BEFORE anything old is torn down. Its maps use gpa
        // (a StringHashMap stores its allocator, and an arena-backed one would
        // die with the arena), but its keys are `copy`'s ids — so the Index and
        // the task set it indexes now live and die together, by construction.
        var next_idx = try view.Index.build(m.gpa, copy);
        errdefer next_idx.deinit();

        // Past this point nothing can fail. Retire the old derived state, whose
        // ids all point into the arena that is about to be reset.
        //
        // Read the cursor's row index BEFORE `rows` goes away: this is the last
        // instant it exists. `recompute` cannot recover it afterwards — it would
        // see an empty row list and silently degrade to a "jump to row 0"
        // fallback rather than to the nearest surviving row.
        m.cursor_anchor = m.cursorIndex() orelse m.cursor_anchor;
        m.gpa.free(m.rows);
        m.rows = &.{};
        m.scores.clearRetainingCapacity();
        if (m.idx_built) m.idx.deinit();
        m.idx = next_idx;
        m.idx_built = true;
        m.tasks = copy;

        // Swap, then reset what used to be live. `folds`, `cursor_id` and any id
        // held in Mode/InFlight are interned in `ids`, which is untouched here.
        const outgoing = m.live;
        m.live = m.spare;
        m.spare = outgoing;
        _ = m.spare.reset(.retain_capacity);
    }
};

// The single funnel: rebuilds every piece of derived state (selection, scores,
// ranking, rows, cursor, scroll offset) after ANY change to tasks, filters,
// folds or strategy. Every branch of `update` ends by calling it, and nothing
// else may rebuild these fields piecemeal.
fn recompute(m: *Model) !void {
    // Where the cursor SAT, so a vanished task falls to its neighbour rather
    // than to the top of the list. When `rows` is still valid (a fold, filter or
    // strategy change) that is exact; after a `replaceTasks` the row list is
    // already gone and the anchor `replaceTasks` snapshotted is all there is.
    const old_index = m.cursorIndex() orelse m.cursor_anchor;

    // The `#handle` length, derived the SAME way `main.zig` derives it for the CLI
    // (`view.minUniqueSuffixLen` over every fetched id) so a handle names the same
    // task in both front ends. A fixed length would print two identical handles
    // wherever two ids share a 4-char tail while `seshat show` widened to five —
    // precisely the CLI/TUI drift `core/display.zig` exists to prevent.
    //
    // Done FIRST, before anything is torn down: `minUniqueSuffixLen` allocates a
    // hash map per candidate length and so can fail, and failing here leaves the
    // model exactly as it was rather than half-rebuilt.
    {
        const ids = try m.gpa.alloc([]const u8, m.tasks.len);
        defer m.gpa.free(ids);
        for (m.tasks, ids) |task_, *dst| dst.* = task_.id;
        m.handle_len = try view.minUniqueSuffixLen(m.gpa, ids);
    }

    m.gpa.free(m.rows);
    m.rows = &.{};
    m.scores.deinit();
    m.scores = ledger.Scores.init(m.gpa);

    const roots = try view.select(m.gpa, m.tasks, &m.idx, m.filters, m.now);
    defer m.gpa.free(roots);

    m.scores = try ledger.computeScores(m.gpa, m.tasks, &m.idx, m.filters, m.now);

    if (m.strategy == .urgency) {
        const sc = try m.gpa.alloc(i64, roots.len);
        defer m.gpa.free(sc);
        const complete = try m.gpa.alloc(bool, roots.len);
        defer m.gpa.free(complete);
        for (roots, 0..) |r, i| {
            // computeScores visits every task, so a miss is unreachable in
            // practice — but `sc`/`complete` are uninitialised memory, and
            // skipping an entry would hand rankByScore a garbage sort key.
            const s = m.scores.get(r.id) orelse ledger.Score{
                .own = 0,
                .sub = 0,
                .attention = 0,
                .descendants = 0,
                .all_complete = false,
                .matches = true,
                .self_matches = true,
            };
            sc[i] = s.sub;
            complete[i] = s.all_complete;
        }
        try view.rankByScore(m.gpa, roots, sc, complete, m.strategy, m.now);
    } else {
        view.rank(roots, m.strategy, m.now);
    }

    m.rows = try ledger.buildRows(m.gpa, roots, m.tasks, &m.idx, &m.scores, &m.folds, m.filtering);

    // Re-resolve the cursor BY ID; fall back to the nearest surviving position.
    if (m.cursorIndex() == null) {
        m.cursor_id = null;
        if (nearestTaskRow(m.rows, old_index)) |i| {
            // Must be interned: `Row.id` borrows from the live task arena, which
            // the next replaceTasks resets.
            m.cursor_id = try m.internId(m.rows[i].id);
        }
    }

    // Refresh the anchor from the resolved cursor. When the cursor cannot be
    // resolved — filtered away, inside a collapsed subtree, or an empty list —
    // KEEP the previous anchor rather than zeroing it. It is the only memory of
    // where the user was, so clearing a filter that matched nothing must put
    // them back there instead of at the top of the list.
    m.cursor_anchor = m.cursorIndex() orelse m.cursor_anchor;

    const layout = ledger.layoutFor(m.viewport.rows -| ledger.chrome_rows, m.pane_open);
    // Clamp into the current list: a stale anchor left over from a longer one
    // must not drag the viewport past the end.
    const focus = @min(m.cursor_anchor, m.rows.len -| 1);
    m.scroll_top = ledger.ensureVisible(focus, m.rows.len, layout.ledger_rows, m.scroll_top);
}

// The `.task` row nearest to `anchor`, searched OUTWARD in both directions
// (backward wins a tie). Returns null only when there is no selectable row at
// all. Scanning backward only would strand the cursor at null whenever row 0 is
// an `unreachable_header` — which is exactly what cyclic data produces, since
// then there are no roots and the header leads the list.
fn nearestTaskRow(rows: []const ledger.Row, anchor: usize) ?usize {
    if (rows.len == 0) return null;
    const start = @min(anchor, rows.len - 1);
    var d: usize = 0;
    while (d < rows.len) : (d += 1) {
        if (d <= start and rows[start - d].kind == .task) return start - d;
        const fwd = start + d;
        if (d > 0 and fwd < rows.len and rows[fwd].kind == .task) return fwd;
    }
    return null;
}

// ─── update ──────────────────────────────────────────────────────────────────
//
// The event handler, and the only entry point the shell calls. It is pure of
// I/O: it mutates the model and RETURNS a description of the side effect it
// wants (`Command`), never performs one.
//
// Dispatch is on `m.mode` FIRST and on the event second. That order is the whole
// reason `Mode` is a single tagged union: the mode is what decides what a key
// means, so there is exactly one place per mode where its key map lives.
pub fn update(allocator: std.mem.Allocator, m: *Model, ev: Event) !Command {
    return switch (m.mode) {
        .list => listMode(m, ev),
        .field => |f| fieldMode(allocator, m, f, ev),
        // BY POINTER, not by value: `Editor` transitively owns a heap ArrayList,
        // so a by-value capture would hand the keystroke path a copy to mutate —
        // leaking the reallocation and leaving `m.mode`'s buffer stale.
        .editing => |*e| editingMode(m, e, ev),
        // Both prompts own a heap LineEditor, so BY POINTER for the same reason
        // `.editing` is.
        .filter => |*le| filterMode(m, le, ev),
        .add => |*le| addMode(m, le, ev),
        // A copy of the id slice, not of an owner: `confirm_delete` carries only
        // an interned id and nothing that needs writing back through `m.mode`.
        .confirm_delete => |c| confirmDeleteMode(m, c.id, ev),
    };
}

// The events whose meaning does not depend on the mode. Every mode handler falls
// through to here for anything it does not itself interpret.
fn sharedEvent(m: *Model, ev: Event) !Command {
    switch (ev) {
        .resize => |vp| {
            m.viewport = vp;
            // A new height changes the valid scroll range.
            try recompute(m);
        },
        .tasks_loaded => |tasks| {
            // A refresh that lands is the answer to the request that asked for it.
            // Only `.refresh` is cleared: a `.commit` slot owns an editor that a
            // failure still has to hand back, and an unrelated fetch must not free it.
            if (m.in_flight == .refresh) m.in_flight = .none;
            m.load_failed = false; // we have data again, whatever came before
            // WHICH task the current mode is about, read before the swap. A
            // background refresh must not close a prompt just because it landed:
            // the ONLY thing that invalidates a mode is its task disappearing.
            // Interned, so it survives `replaceTasks` and can be looked up after.
            const anchored = modeAnchor(m);
            try m.replaceTasks(tasks);
            try recompute(m);
            // `.filter`/`.add` anchor to nothing — they belong to the user, not to
            // the task set — so a refresh never throws away what they hold.
            if (anchored) |id| {
                if (!m.idx.by_id.contains(id)) m.clearMode();
            }
        },
        // The server created the task and echoed it back. A brand-new task scores
        // urgency 0, so it ranks LAST — landing the cursor on it and opening the
        // pane is what stops it vanishing off the bottom the instant it exists.
        .create_ok => |created| {
            if (m.in_flight == .create) m.clearInFlight();
            const one = [_]Task{created};
            try mergeTasks(m, &one);
            m.clearMode(); // frees the add prompt's editor
            // INTERNED: `created.id` borrows the shell's response buffer.
            m.cursor_id = try m.internId(created.id);
            m.pane_open = true;
            m.mode = .{ .field = .priority };
            try recompute(m);
            try m.setStatus("created — set a priority, or escape to the list", .{});
        },
        // A delete is the one mutation whose effect is not confined to the task
        // written: the server promotes the children, so the only honest way to
        // learn the new shape of the forest is to ask for it.
        .delete_ok => {
            if (m.in_flight == .delete) {
                m.clearInFlight();
                m.in_flight = .refresh; // the refetch below is now the outstanding request
            }
            try m.setStatus("deleted", .{});
            return .fetch;
        },
        // The server accepted the edit and echoed the authoritative task. That
        // echo is the ONLY thing that changes what the user sees — there is no
        // optimistic write anywhere on the commit path.
        .commit_ok => |tasks| {
            // Scoped to `.commit`, for the same reason `tasks_loaded`'s clear is
            // scoped to `.refresh`: an unconditional clear would silently cancel
            // whatever OTHER request happens to be outstanding, leaving its own
            // reply with nothing expecting it.
            if (m.in_flight == .commit) m.clearInFlight(); // the edit landed; the editor is done
            try mergeTasks(m, tasks);
            try recompute(m);
            try m.setStatus("saved", .{});
        },
        // A conflict is BOTH halves: the server's version wins on screen, and the
        // user's typed value comes back into an open editor so re-applying it
        // costs one keystroke rather than a retype.
        .conflict => |tasks| {
            const f = restoreEditor(m);
            // `restoreEditor` empties a `.commit` slot on its way past; any OTHER
            // slot still has to be cleared here or the model jams "busy" forever
            // and refuses every subsequent mutation.
            m.clearInFlight();
            try mergeTasks(m, tasks);
            try recompute(m);
            if (f) |field| {
                try m.setStatus("{s} changed on the server — your edit is still here, press enter to reapply", .{@tagName(field)});
            } else {
                try m.setStatus("that task changed on the server", .{});
            }
        },
        .request_failed => |msg| {
            switch (m.in_flight) {
                // Hand the editor back so the typed text survives the round trip.
                .commit => _ = restoreEditor(m),
                // `Mode.add` still holds the title the user typed; leave it alone.
                .create, .delete => {},
                .none, .refresh => {
                    // Only the INITIAL load fails with nothing on screen. A failed
                    // refresh must keep the data the user already has rather than
                    // replacing a working list with an error page.
                    if (m.tasks.len == 0) m.load_failed = true;
                },
            }
            m.clearInFlight(); // `.commit` was already emptied above; every branch ends here
            try m.setStatus("{s}", .{msg});
        },
        // `.key` reaches here only from a mode with no key map yet.
        else => {},
    }
    return .none;
}

// The task a mode is ABOUT, or null when it is about none. `.field`/`.editing`
// edit the cursor's task and `.confirm_delete` names its own, so all three become
// meaningless the moment that task stops existing; `.filter` and `.add` hold text
// the user typed, which no refresh has any business discarding. Every id returned
// here is interned, so the caller may hold it across a task-set swap.
fn modeAnchor(m: *const Model) ?[]const u8 {
    return switch (m.mode) {
        // `.editing` names its own task (see `Editing.id`); `.field` has only the
        // cursor, which is what it acts on.
        .editing => |e| e.id,
        .field => m.cursor_id,
        .confirm_delete => |c| c.id,
        .list, .filter, .add => null,
    };
}

// Fold the server's authoritative tasks into the current set BY ID, then install
// the result through `replaceTasks` — the same double-buffering, so the new
// Index exists before the old arena is reset.
//
// `scratch` holds BORROWED task values: some point into the live arena, some into
// the caller's response buffer. `replaceTasks` deep-copies the whole thing into
// `spare` before it touches anything live, so both sets of borrows are still
// valid at the instant they are read.
fn mergeTasks(m: *Model, incoming: []const Task) !void {
    const scratch = try m.gpa.alloc(Task, m.tasks.len + incoming.len);
    defer m.gpa.free(scratch);
    @memcpy(scratch[0..m.tasks.len], m.tasks);
    var n = m.tasks.len;
    outer: for (incoming) |src| {
        for (scratch[0..n]) |*dst| {
            if (std.mem.eql(u8, dst.id, src.id)) {
                dst.* = src;
                continue :outer;
            }
        }
        // A task the client has never seen (a subtask the server created as part
        // of the same write): keep it rather than silently dropping it.
        scratch[n] = src;
        n += 1;
    }
    try m.replaceTasks(scratch[0..n]);
}

// Move the `Editor` back OUT of `in_flight` and INTO `Mode` — the exact mirror of
// the move in `commitEdit`, and the other half of that handshake. Copy the value,
// retag `in_flight`, then install: `moved` is the sole owner in between, and
// nothing fallible runs there, so there is exactly one owner at every instant.
// Deliberately NOT `clearInFlight`, which would free the very buffer being handed
// back. Returns the field the editor belongs to, or null when no commit was
// outstanding.
fn restoreEditor(m: *Model) ?FieldId {
    switch (m.in_flight) {
        .commit => |c| {
            // The status-cycle key commits from `.list` with no editor at all,
            // parking an empty `.external` in the slot so the commit path keeps
            // one shape. There is nothing to hand back, and reopening `.editing`
            // on it would strand the user in an editor whose only reply is
            // "nothing to save yet". A description commit can never look like
            // this: it only ever commits text that has already come back.
            if (c.editor == .external and c.editor.external == null) {
                m.in_flight = .none;
                return null;
            }
            const f = c.field;
            const moved = c.editor;
            // Carry the TARGET id back too, not just the buffer. `c.id` is what
            // the rejected request was for; the caller (`.conflict`) merges and
            // recomputes immediately afterwards, which can move `cursor_id` off
            // this task entirely — so the restored editor has to remember its own
            // target or "press enter to reapply" lands on whatever the cursor
            // drifted to. Interned, and the id arena is never reset.
            const target_id = c.id;
            m.in_flight = .none; // in_flight no longer owns it; `moved` does
            // `fieldMode` refuses to open an editor while a commit is
            // outstanding, so `Mode` should hold none — but going through
            // clearMode keeps that a guarantee rather than an assumption.
            m.clearMode();
            m.mode = .{ .editing = .{ .id = target_id, .field = f, .editor = moved } };
            return f;
        },
        else => return null,
    }
}

fn listMode(m: *Model, ev: Event) !Command {
    const k = switch (ev) {
        .key => |k| k,
        else => return sharedEvent(m, ev),
    };
    switch (k) {
        .char => |c| switch (c) {
            'q' => return .quit,
            'j' => try moveCursor(m, .next),
            'k' => try moveCursor(m, .prev),
            'l' => try setFold(m, true),
            'h' => try setFold(m, false),
            'g' => try jumpToEdge(m, true),
            'G' => try jumpToEdge(m, false),
            ' ' => return cycleStatus(m),
            'a' => try openPrompt(m, .add),
            '/' => try openPrompt(m, .filter),
            'x' => try openConfirmDelete(m),
            // Manual refresh. Also the ONLY way out of a failed initial load, so
            // it has to exist from this task onward rather than waiting for the
            // rest of the list keys.
            'R' => {
                if (try refuseIfBusy(m)) return .none;
                m.in_flight = .refresh;
                return .fetch;
            },
            else => {},
        },
        .down => try moveCursor(m, .next),
        .up => try moveCursor(m, .prev),
        .right => try setFold(m, true),
        .left => try setFold(m, false),
        .ctrl_d => try pageBy(m, .next),
        .ctrl_u => try pageBy(m, .prev),
        .tab => {
            m.pane_open = !m.pane_open;
            // The pane takes/gives back rows from the ledger, so the old scroll
            // offset may no longer be valid for the new layout.
            try recompute(m);
        },
        .enter => {
            // Nothing selected — there is no task to descend INTO. Without this
            // guard the pane opens onto a phantom, and the commit path in a later
            // task would have no id to write back against.
            if (m.cursor_id == null) return .none;
            m.pane_open = true; // descending always shows the task being edited
            m.mode = .{ .field = .title };
            // The pane takes rows away from the ledger, so the scroll offset the
            // old layout produced may no longer be valid.
            try recompute(m);
        },
        // Escape is the way OUT of a filtered view. In `.list` it is otherwise
        // inert, so it costs nothing and there is no other key that undoes `/`.
        .escape => try clearFilter(m),
        else => {},
    }
    return .none;
}

const Dir = enum { prev, next };

// Move the cursor to the adjacent SELECTABLE row, skipping `.missing` and
// `.unreachable_header` rows, and clamping at both ends (no wrap).
fn moveCursor(m: *Model, dir: Dir) !void {
    var i = m.cursorIndex() orelse return;
    while (true) {
        switch (dir) {
            .next => {
                if (i + 1 >= m.rows.len) return; // clamped: nothing selectable ahead
                i += 1;
            },
            .prev => {
                if (i == 0) return; // clamped
                i -= 1;
            },
        }
        if (m.rows[i].kind == .task) break;
    }
    // INTERNED: `Row.id` points into the live task arena, which the next
    // `replaceTasks` resets. `cursor_id` has to outlive that.
    m.cursor_id = try m.internId(m.rows[i].id);
    // recompute is the funnel — it re-resolves the cursor, refreshes the anchor
    // and scrolls the viewport to follow it.
    try recompute(m);
}

// h/l and ←/→: record an EXPLICIT fold for the cursor's task, overriding the
// auto-expand rule. `cursor_id` is already interned, which is exactly what a
// `folds` key must be — it outlives every task-set swap, while `Row.id` does not.
fn setFold(m: *Model, expanded: bool) !void {
    const id = m.cursor_id orelse return;
    try m.folds.put(id, expanded);
    try recompute(m);
}

// g/G: jump to the first/last SELECTABLE row. `nearestTaskRow` anchored at row 0
// or the last row does exactly this — it searches outward from the anchor, so
// anchoring at an end turns it into a directional scan that steps past a leading
// `.unreachable_header` or a trailing `.missing` run instead of landing on one.
fn jumpToEdge(m: *Model, first: bool) !void {
    if (m.rows.len == 0) return;
    const anchor: usize = if (first) 0 else m.rows.len - 1;
    const i = nearestTaskRow(m.rows, anchor) orelse return;
    // INTERNED: see moveCursor.
    m.cursor_id = try m.internId(m.rows[i].id);
    try recompute(m);
}

// The first `.task` row AT OR PAST `start`, scanning strictly in `dir`. Unlike
// `nearestTaskRow` (which picks whichever direction is closer — exactly wrong
// here, since it can resolve back to the row the cursor is already on and
// stall a page key forever) this only ever looks the way the key is pointing.
// Falls back to the last/first `.task` row in the whole list when `dir` runs
// off the end without finding one — mirroring where `g`/`G` would land.
fn scanTaskRow(rows: []const ledger.Row, start: usize, dir: Dir) ?usize {
    switch (dir) {
        .next => {
            var i = start;
            while (i < rows.len) : (i += 1) {
                if (rows[i].kind == .task) return i;
            }
            return nearestTaskRow(rows, rows.len -| 1);
        },
        .prev => {
            // Unlike .next, whose loop simply does not run, a backward scan
            // dereferences rows[i] before any bounds check. Guard both an empty
            // list and a start past the end so the helper is total over its
            // signature, not merely safe for today's one caller.
            if (rows.len == 0) return null;
            var i = @min(start, rows.len - 1);
            while (true) {
                if (rows[i].kind == .task) return i;
                if (i == 0) break;
                i -= 1;
            }
            return nearestTaskRow(rows, 0);
        },
    }
}

// Ctrl-D/Ctrl-U: move by half a ledger page (spec §11), clamped at both ends,
// then settle on the nearest selectable row IN THE DIRECTION OF TRAVEL — the
// raw arithmetic target can land inside a `.missing` run or the
// `.unreachable_header`, and picking the globally-nearest task row (as
// `nearestTaskRow` does) can resolve back to the row the cursor started on,
// stalling the key forever when a long non-task run sits about half a page
// ahead/behind.
fn pageBy(m: *Model, dir: Dir) !void {
    const cur = m.cursorIndex() orelse return;
    const layout = ledger.layoutFor(m.viewport.rows -| ledger.chrome_rows, m.pane_open); // same reservation recompute used
    const half = ledger.halfPage(layout.ledger_rows);
    const target = switch (dir) {
        .next => @min(cur + half, m.rows.len -| 1),
        .prev => cur -| half,
    };
    const i = scanTaskRow(m.rows, target, dir) orelse return;
    // INTERNED: see moveCursor.
    m.cursor_id = try m.internId(m.rows[i].id);
    try recompute(m);
}

// ─── the mutating list keys ──────────────────────────────────────────────────

// space: the one edit with NO editor at all — the next status is a pure function
// of the current one, so there is nothing to type. It commits straight from
// `.list` and stays there.
fn cycleStatus(m: *Model) !Command {
    if (try refuseIfBusy(m)) return .none;
    const target = cursorTask(m) orelse return .none;
    const next: Status = switch (target.content.status) {
        // Closing a task is what the key is FOR, so both open states go straight
        // to done rather than stepping through each other. The two terminal
        // states return to todo, which is the only non-destructive way back from
        // a mis-press.
        .todo, .in_progress => .done,
        .done, .cancelled => .todo,
    };
    const content = edit.applyPatch(target.content, .{ .status = .{ .set = next } });
    const id = m.cursor_id.?; // proven non-null by `cursorTask` resolving
    // An EMPTY `.external` editor. The slot keeps the shape every other commit
    // uses, so `commit_ok`/`conflict`/`request_failed` need no new case; and an
    // `.external` holding null owns nothing, so no teardown path can leak or
    // double-free it. `restoreEditor` knows not to reopen an editor on it.
    m.in_flight = .{ .commit = .{ .id = id, .field = .status, .editor = .{ .external = null } } };
    return .{ .commit = .{
        .id = id,
        .expected_version = target.meta.version,
        .content = content,
    } };
}

const Prompt = enum { add, filter };

// `a` and `/` both open a one-line prompt. The in-flight refusal is here for a
// MEMORY reason as much as a policy one: `in_flight.commit` may already own the
// editor a failed commit has to hand back, and a prompt installed in `Mode`
// alongside it would be a SECOND live editor — the invariant `fieldMode` has
// guarded since task 14, now reachable from two more keys.
fn openPrompt(m: *Model, which: Prompt) !void {
    if (try refuseIfBusy(m)) return;
    // Built BEFORE the old mode is dropped, so a failed allocation leaves the
    // model exactly as it was. Nothing below can fail, so `le` is never stranded
    // unowned. Same shape as `openEditor`.
    const le = try editors.LineEditor.init(m.gpa, "");
    m.clearMode(); // frees whatever the outgoing mode owned
    m.mode = switch (which) {
        .add => .{ .add = le },
        .filter => .{ .filter = le },
    };
}

// `x`: the prompt carries ONLY the (already interned) id. The number of children
// the server will promote is read out of `m.tasks` again when `y` is pressed, so
// a refresh landing while the prompt is open cannot leave the user confirming
// against a count that has stopped being true.
fn openConfirmDelete(m: *Model) !void {
    if (try refuseIfBusy(m)) return;
    const id = m.cursor_id orelse return;
    try m.setStatus("delete this task? {d} subtasks would be promoted to top level — y/n", .{promoteCount(m, id)});
    m.clearMode();
    m.mode = .{ .confirm_delete = .{ .id = id } };
}

// How many of a task's children are real tasks, and would therefore be promoted
// to top level by deleting it. Counted against the Index rather than taken as
// `child_ids.len`: a dangling child id is not a task, and nothing can promote it.
fn promoteCount(m: *const Model, id: []const u8) usize {
    if (!m.idx_built) return 0;
    const task_ = m.idx.by_id.get(id) orelse return 0;
    var n: usize = 0;
    for (task_.content.child_ids) |c| {
        if (m.idx.by_id.contains(c)) n += 1;
    }
    return n;
}

// y/n only. Every other key is SWALLOWED rather than falling through to the list
// key map — a confirmation prompt that quietly acts on whatever else is pressed
// is exactly how the wrong task gets deleted.
fn confirmDeleteMode(m: *Model, id: []const u8, ev: Event) !Command {
    const k = switch (ev) {
        .key => |k| k,
        else => return sharedEvent(m, ev),
    };
    switch (k) {
        .char => |c| switch (c) {
            'y' => {
                if (try refuseIfBusy(m)) return .none;
                // Read NOW, not when the prompt opened.
                const n = promoteCount(m, id);
                try m.setStatus("deleting — {d} subtasks promoted to top level", .{n});
                m.clearMode();
                // `id` is interned and the id arena is never reset, so it stays
                // valid for the whole round trip and for the Command below.
                m.in_flight = .{ .delete = .{ .id = id } };
                return .{ .delete = id };
            },
            'n' => try cancelConfirm(m),
            else => {},
        },
        .escape => try cancelConfirm(m),
        else => {},
    }
    return .none;
}

fn cancelConfirm(m: *Model) !void {
    m.clearMode();
    // The prompt's question must not stay on the status line after it is answered.
    try m.setStatus("cancelled", .{});
}

fn addMode(m: *Model, le: *editors.LineEditor, ev: Event) !Command {
    const k = switch (ev) {
        .key => |k| k,
        else => return sharedEvent(m, ev),
    };
    switch (k) {
        .escape => m.clearMode(),
        .enter => return submitAdd(m, le),
        else => try le.handle(m.gpa, k),
    }
    return .none;
}

// Enter in the add prompt. `Mode` STAYS `.add` until the server answers: a failed
// create has to give the typed title back, and the prompt still holding it is the
// cheapest possible way to do that (`request_failed`'s `.create` branch is
// deliberately a no-op for exactly this reason).
fn submitAdd(m: *Model, le: *editors.LineEditor) !Command {
    if (try refuseIfBusy(m)) return .none;
    const typed = std.mem.trim(u8, le.text(), " \t");
    edit.validate(.{ .title = typed }) catch |err| switch (err) {
        error.EmptyTitle => {
            try m.setStatus("a title cannot be empty", .{});
            return .none; // the prompt stays open
        },
    };
    // Interned for the same reason every other stored slice is: it has to outlive
    // the editor buffer it was typed into AND the Command that carries it out.
    const title = try m.internId(typed);
    m.in_flight = .{ .create = .{ .title = title } };
    return .{ .create = .{ .title = title } };
}

fn filterMode(m: *Model, le: *editors.LineEditor, ev: Event) !Command {
    const k = switch (ev) {
        .key => |k| k,
        else => return sharedEvent(m, ev),
    };
    switch (k) {
        // Abandons the EDIT, not the view: an already-active filter stays on.
        // Escape from `.list` is what clears one.
        .escape => m.clearMode(),
        .enter => try applyFilter(m, le.text()),
        else => try le.handle(m.gpa, k),
    }
    return .none;
}

// Enter in the filter prompt. A rejected expression keeps the prompt OPEN with
// the text intact — which is the whole reason `filterspec.parse` returns
// `error.BadFilter` instead of printing and exiting the way the CLI needs.
fn applyFilter(m: *Model, typed: []const u8) !void {
    const trimmed = std.mem.trim(u8, typed, " \t");
    if (trimmed.len == 0) {
        // An emptied prompt says the same thing Escape from the list says.
        m.clearMode();
        return clearFilter(m);
    }

    // `parse` takes the CLI's repeatable `--filter` form; one typed line is that
    // same list with spaces where the flag repeats used to be.
    var exprs = std.ArrayList([]const u8).empty;
    defer exprs.deinit(m.gpa);
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |e| try exprs.append(m.gpa, e);

    const parsed = filterspec.parse(m.gpa, exprs.items) catch |err| switch (err) {
        error.BadFilter => {
            try m.setStatus("not a filter: {s} (try tag:NAME, status:todo,done, or overdue)", .{trimmed});
            return; // still `.filter`, still holding what the user typed
        },
        else => |leftover| return leftover,
    };
    defer parsed.deinit(m.gpa);

    // COPY into the ID ARENA, which is the only one that outlives both hazards:
    // `parsed.tags` are subslices of the editor buffer `clearMode` frees three
    // lines down, and `m.filters` is read by every later `recompute`, across
    // every task-set swap. Nothing here may point into `live`.
    const ia = m.ids.allocator();
    const tags = try ia.alloc([]const u8, parsed.tags.len);
    for (parsed.tags, tags) |src, *dst| dst.* = try ia.dupe(u8, src);
    const statuses = try ia.dupe(Status, parsed.statuses);
    const expr = try m.internId(trimmed);

    // MERGE, not replace: `roots_only` describes the view's shape, not anything
    // the user can type into this prompt.
    m.filters.tags = tags;
    m.filters.statuses = statuses;
    m.filters.overdue = parsed.overdue;
    m.filter_expr = expr;
    m.filtering = true;
    m.clearMode();
    try recompute(m);
}

fn clearFilter(m: *Model) !void {
    if (!m.filtering) return;
    m.filters = .{ .roots_only = m.filters.roots_only };
    m.filter_expr = "";
    m.filtering = false;
    try recompute(m);
}

fn fieldMode(allocator: std.mem.Allocator, m: *Model, f: FieldId, ev: Event) !Command {
    const k = switch (ev) {
        .key => |k| k,
        else => return sharedEvent(m, ev),
    };
    switch (k) {
        .up => m.mode = .{ .field = stepField(f, -1) },
        .down => m.mode = .{ .field = stepField(f, 1) },
        // Opening an editor is the first step of a mutation, and it is also what
        // would put a SECOND `Editor` in `Mode` while `in_flight` still holds the
        // one a failed commit has to restore (task 14). Refusing here keeps
        // "exactly one live editor" an invariant rather than a coincidence.
        .enter => {
            if (try refuseIfBusy(m)) return .none;
            return openEditor(allocator, m, f);
        },
        // No editor is live in `.field`, but clearMode is the one sanctioned way
        // back to `.list` — never hand-roll the teardown.
        .escape => m.clearMode(),
        else => {},
    }
    return .none;
}

// At most ONE mutation may be outstanding. Every key path that would start one
// asks here first; a refused key gets a message and is DROPPED, never queued —
// queuing would let the user stack edits against a state the server has not
// confirmed, which is the same trap as an optimistic write. NOT a pure query: it
// writes the status line when it returns true, hence the imperative name.
fn refuseIfBusy(m: *Model) !bool {
    if (m.in_flight == .none) return false;
    try m.setStatus("still saving…", .{});
    return true;
}

// ↑/↓ walk FieldId's DECLARATION order, clamped at both ends — deliberately no
// wrapping: a field list is short enough that wrapping only ever surprises.
fn stepField(f: FieldId, delta: i8) FieldId {
    const last: i8 = @typeInfo(FieldId).@"enum".fields.len - 1;
    const i: i8 = @intFromEnum(f);
    return @enumFromInt(std.math.clamp(i + delta, 0, last));
}

fn cursorTask(m: *const Model) ?Task {
    const id = m.cursor_id orelse return null;
    return taskById(m, id);
}

// Any task by id, whether or not it is on screen. The commit path uses this
// rather than `cursorTask`: a task that no longer matches the filter still
// EXISTS, and an editor open on it must still be able to save.
fn taskById(m: *const Model, id: []const u8) ?Task {
    if (!m.idx_built) return null;
    return m.idx.by_id.get(id);
}

// Open the editor whose TYPE matches the field, seeded from the cursor's task.
// Returns `.open_editor` for the one field that is not edited in-process.
fn openEditor(allocator: std.mem.Allocator, m: *Model, f: FieldId) !Command {
    // FIRST, above every write to `m.mode`. `.field` outlives its task being
    // filtered away — `recompute` nulls `cursor_id` while `modeAnchor` keeps the
    // mode alive, because only leaving the *Index* invalidates a mode. Installing
    // `.editing` and only then discovering there is no id to build the command
    // from parked the user in an editor that never opens: `.description` returned
    // `.none`, so `$EDITOR` never ran, and the pane said "editing in $EDITOR…"
    // with nothing to wait for.
    const id = m.cursor_id orelse {
        try m.setStatus("nothing selected", .{});
        return .none;
    };
    const c: Content = if (cursorTask(m)) |task_| task_.content else .{ .title = "" };
    var date_buf: [16]u8 = undefined;

    // Build the editor BEFORE dropping the old mode, so a failed allocation
    // leaves the model exactly as it was.
    const editor: Editor = switch (f) {
        // Enum fields pick from the declaration order, seeded at the current value.
        .status => .{ .pick = .{
            .len = @typeInfo(Status).@"enum".fields.len,
            .index = @intFromEnum(c.status),
        } },
        .priority => .{ .pick = .{
            .len = @typeInfo(Priority).@"enum".fields.len,
            .index = @intFromEnum(c.priority),
        } },
        .title => .{ .line = try editors.LineEditor.init(m.gpa, c.title) },
        .tags => blk: {
            // Same comma-separated form the CLI's `--tags` takes.
            const joined = try std.mem.join(allocator, ",", c.tags);
            defer allocator.free(joined);
            break :blk .{ .line = try editors.LineEditor.init(m.gpa, joined) };
        },
        // Dates prefill with the formatted local date, empty when unset.
        .due => .{ .line = try editors.LineEditor.init(m.gpa, dateText(&date_buf, c.due_at, m.offset_minutes)) },
        .scheduled => .{ .line = try editors.LineEditor.init(m.gpa, dateText(&date_buf, c.scheduled_at, m.offset_minutes)) },
        // A description is edited in $EDITOR — the shell runs it and reports back
        // through `editor_returned`, which is what fills in the retained text.
        .description => .{ .external = null },
    };
    // Nothing below can fail, so `editor` cannot be stranded unowned.
    m.clearMode(); // frees whatever the outgoing mode owned
    m.mode = .{ .editing = .{ .id = id, .field = f, .editor = editor } };

    if (f == .description) {
        // `id` came from `cursor_id`, already interned in the `ids` arena (never
        // reset, so it outlives every task-set swap the round trip races);
        // `initial` borrows the live task arena, which survives until the next
        // swap. Both outlast this return, which is all a Command payload promises.
        return .{ .open_editor = .{ .id = id, .initial = c.description } };
    }
    return .none;
}

fn dateText(buf: []u8, at: ?i64, offset_minutes: i32) []const u8 {
    const unix = at orelse return "";
    return display.formatDate(buf, unix, offset_minutes);
}

fn editingMode(m: *Model, e: *Editing, ev: Event) !Command {
    const k = switch (ev) {
        .key => |k| k,
        // The external editor reports back through an EVENT, not a key: it is the
        // only editor whose Enter happens outside this process.
        .editor_returned => |returned| return editorReturned(m, e, returned),
        else => return sharedEvent(m, ev),
    };
    const f = e.field; // read before anything can retag `m.mode` under `e`
    switch (k) {
        .escape => {
            m.clearMode(); // frees the editor's heap buffer
            m.mode = .{ .field = f }; // back up one level, not all the way out
        },
        .enter => return commitEdit(m, e),
        // Every other key belongs to the editor: it owns its own key map, and
        // `.external` has no in-process buffer to type into.
        else => switch (e.editor) {
            .line => |*le| try le.handle(m.gpa, k),
            .pick => |*pe| pe.handle(k),
            .external => {},
        },
    }
    return .none;
}

// One field in, one `Edit` out — a commit never carries a change the user did not
// make in this editor. The strings it produces still BORROW the editor buffer;
// `ownPatch` copies them out once the edit is known good, so a rejected commit
// costs the live arena nothing.
fn buildPatch(m: *Model, e: *const Editing) error{ BadDate, OutOfMemory }!edit.Patch {
    var p = edit.Patch{};
    switch (e.editor) {
        .pick => |pe| switch (e.field) {
            // `PickEditor.index` is always < `len`, and `len` came from the enum's
            // own field count in `openEditor`, so neither cast can be out of range.
            .status => p.status = .{ .set = @enumFromInt(pe.index) },
            .priority => p.priority = .{ .set = @enumFromInt(pe.index) },
            else => {},
        },
        .line => |le| {
            const typed = le.text();
            switch (e.field) {
                .title => p.title = .{ .set = typed },
                .due => p.due = try parseDateField(m, typed, .due),
                .scheduled => p.scheduled = try parseDateField(m, typed, .scheduled),
                // splitTags allocates only the OUTER slice; the segments still
                // point into `typed` until `ownPatch` runs.
                .tags => p.tags = .{ .set = try edit.splitTags(m.live.allocator(), typed) },
                else => {},
            }
        },
        .external => {},
    }
    return p;
}

// An EMPTY (or whitespace-only) date field clears the date, exactly as typing
// `none` does. `edit.parseDate` deliberately rejects "" and must keep doing so —
// the CLI's `--due ""` is a user error there. In the TUI the field arrives
// prefilled, so deleting its contents is the obvious way to say "no date", and
// reporting that as malformed input would be a dead end: there would be no way to
// clear a date except by knowing the word `none`.
fn parseDateField(m: *const Model, typed: []const u8, kind: edit.DateKind) edit.DateError!edit.DatePatch {
    if (std.mem.trim(u8, typed, " \t").len == 0) return .{ .set = null };
    return edit.parseDate(typed, m.now, kind, m.offset_minutes);
}

// Copy every string the patch borrows from the editor buffer into the LIVE arena.
// Runs only AFTER validation, so a rejected edit allocates nothing; and before the
// editor moves into `in_flight`, so the emitted Command never points at a buffer
// that is about to be freed. `live` is reset by the next task-set swap, which is
// exactly when the server's echo replaces this content anyway.
fn ownPatch(m: *Model, p: *edit.Patch) !void {
    const la = m.live.allocator();
    switch (p.title) {
        .set => |s| p.title = .{ .set = try la.dupe(u8, s) },
        .unchanged => {},
    }
    // The description borrows the shell's $EDITOR buffer, which it frees the
    // moment `update` returns.
    switch (p.description) {
        .set => |s| p.description = .{ .set = try la.dupe(u8, s) },
        .unchanged => {},
    }
    switch (p.tags) {
        .set => |tags| for (tags) |*tag| {
            tag.* = try la.dupe(u8, tag.*);
        },
        .unchanged => {},
    }
}

// Enter in an open editor: build the one-field patch, apply it to the task's
// CURRENT content, validate client-side, and hand the whole result to the shell.
// Nothing is written into `m.tasks` — the server's echo (task 14) is the only
// thing allowed to change what the user sees, so a failed request can never
// leave a value on screen the server never accepted.
fn commitEdit(m: *Model, e: *Editing) !Command {
    // Belt and braces: `fieldMode` already refuses to open an editor while a
    // commit is outstanding, but the one-mutation rule guards memory ownership
    // (the editor `in_flight` holds is the one task 14 restores), not just policy.
    if (try refuseIfBusy(m)) return .none;
    // The external editor commits when it RETURNS (`editor_returned`), not on a
    // key — but the text it returned is retained, so Enter here RETRIES a commit
    // the server rejected. It used to be a silent no-op with no status, which
    // left a failed description edit in a frozen editor with no way forward
    // except Escape, which threw the work away.
    if (e.editor == .external) {
        const retained = e.editor.external orelse {
            try m.setStatus("nothing to save yet — the editor has not returned", .{});
            return .none;
        };
        return commitDescription(m, e, retained);
    }

    // The editor's OWN task, not the cursor's — see `Editing.id`.
    const target = taskById(m, e.id) orelse {
        try m.setStatus("that task no longer exists", .{});
        return .none;
    };

    // Both failure paths below leave `Mode` UNTOUCHED: the editor stays open with
    // the user's text intact, so a typo costs a keystroke and not a retype.
    var patch = buildPatch(m, e) catch |err| switch (err) {
        error.BadDate => {
            try m.setStatus("not a date: {s} (try 2026-08-02, 2026-08-02T14:30, +3d, or empty to clear)", .{e.editor.line.text()});
            return .none;
        },
        else => |leftover| return leftover,
    };

    return finishCommit(m, e, &patch, target);
}

// The tail every commit shares, whichever editor produced the patch: validate,
// take ownership of the borrowed strings, move the editor into `in_flight`, emit.
fn finishCommit(m: *Model, e: *Editing, patch: *edit.Patch, target: Task) !Command {
    // Validate against a preview whose strings still borrow the editor buffer —
    // `validate` only reads, and a rejection then costs nothing to undo.
    edit.validate(edit.applyPatch(target.content, patch.*)) catch |err| switch (err) {
        error.EmptyTitle => {
            try m.setStatus("a title cannot be empty", .{});
            return .none;
        },
    };

    // Known good: copy the borrowed strings out before the buffer moves.
    try ownPatch(m, patch);
    const content = edit.applyPatch(target.content, patch.*);

    // The editor's own target. Already interned (`openEditor`/`restoreEditor`),
    // and the `ids` arena is never reset, so it stays valid for the whole round
    // trip even if the cursor moves on — which is exactly what it must survive.
    const id = e.id;

    // MOVE the editor out of `Mode` into `in_flight` — copy the value, then retag
    // `Mode`. NOT `clearMode`, which would free the very buffer `in_flight` is
    // taking ownership of. `e` dangles from the `m.mode` assignment onward and
    // must not be read again. `restoreEditor` is the mirror of these three lines.
    const f = e.field;
    const moved = e.editor;
    m.mode = .{ .field = f };
    m.in_flight = .{ .commit = .{ .id = id, .field = f, .editor = moved } };

    return .{ .commit = .{
        .id = id,
        .expected_version = target.meta.version,
        .content = content,
    } };
}

// $EDITOR exited. `null` is a cancel — the user quit without saving, so nothing
// is emitted and we step back up to the field.
fn editorReturned(m: *Model, e: *Editing, returned: ?[]const u8) !Command {
    const f = e.field; // read before anything can retag `m.mode` under `e`
    const text = returned orelse {
        m.clearMode(); // frees any previously retained text
        m.mode = .{ .field = f };
        return .none;
    };
    if (try refuseIfBusy(m)) return .none;

    // `text` borrows the shell's buffer, which it frees the moment `update`
    // returns — so OWN it, and own it on the editor rather than in a local. From
    // the assignment below there is exactly one owner and every teardown path
    // (clearMode, clearInFlight, deinit) already reclaims it; a local would be
    // unowned on each of the early returns inside `commitDescription`.
    const owned = try m.gpa.dupe(u8, text);
    e.editor.deinit(m.gpa); // frees the text a previous round trip retained
    e.editor = .{ .external = owned };

    return commitDescription(m, e, owned);
}

// Commit the description held by an `.external` editor — shared by the first
// round trip (`editorReturned`) and by Enter retrying a failed one.
fn commitDescription(m: *Model, e: *Editing, text: []const u8) !Command {
    // The editor's OWN task, not the cursor's — see `Editing.id`. A $EDITOR round
    // trip is the longest window on the branch for the cursor to move.
    const target = taskById(m, e.id) orelse {
        try m.setStatus("that task no longer exists", .{});
        return .none;
    };
    // `text` is the editor's own buffer, which moves into `in_flight` intact;
    // `finishCommit`'s `ownPatch` still copies it into the live arena so the
    // emitted Command does not alias an editor a later event may free.
    var patch = edit.Patch{ .description = .{ .set = text } };
    return finishCommit(m, e, &patch, target);
}

fn dupeStrings(a: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const out = try a.alloc([]const u8, src.len);
    for (src, out) |s, *d| d.* = try a.dupe(u8, s);
    return out;
}

const DAY: i64 = 86400;
const NOW: i64 = 100 * DAY;

// created_at defaults to NOW so ageFactor contributes 0. Pass an older value
// explicitly when a test wants age to count.
fn t(id: []const u8, prio: Priority, status: Status, due: ?i64, kids: []const []const u8) Task {
    return .{
        .id = id,
        .content = .{
            .title = id,
            .priority = prio,
            .status = status,
            .due_at = due,
            .child_ids = @constCast(kids),
        },
        .meta = .{ .created_at = NOW },
    };
}

fn loadInto(m: *Model, tasks: []const Task) !void {
    try m.replaceTasks(tasks);
    try recompute(m);
}

const TestHarness = struct {
    alloc: std.mem.Allocator,
    m: Model,
    last: Command = .none,

    // NOTE: `h` must be declared by the caller and initialised in place; Model
    // must never be copied by value.
    fn setup(h: *TestHarness, alloc: std.mem.Allocator, tasks: []const Task) !void {
        h.* = .{ .alloc = alloc, .m = undefined };
        try h.m.init(alloc, NOW, 0);
        h.last = try update(alloc, &h.m, .{ .tasks_loaded = tasks });
    }
    fn deinit(h: *TestHarness) void {
        h.m.deinit();
    }
    fn key(h: *TestHarness, k: Key) !void {
        h.last = try update(h.alloc, &h.m, .{ .key = k });
    }
    fn send(h: *TestHarness, ev: Event) !void {
        h.last = try update(h.alloc, &h.m, ev);
    }
};

test "a model initialises, accepts a task set, and tears down with no leaks" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    var tasks = [_]Task{t("aaa", .high, .todo, null, &.{})};
    try m.replaceTasks(&tasks);

    try std.testing.expectEqual(@as(usize, 1), m.tasks.len);
    try std.testing.expectEqualStrings("aaa", m.tasks[0].id);
    // The model owns its strings: mutating the source must not affect it.
    tasks[0].content.title = "MUTATED";
    try std.testing.expectEqualStrings("aaa", m.tasks[0].content.title);
}

test "handle_len widens past a colliding id tail, exactly as the CLI does" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    // Never recomputed: the floor, so a model with no data still renders handles.
    try std.testing.expectEqual(@as(usize, 4), m.handle_len);

    var distinct = [_]Task{
        t("AAAAWORK1", .none, .todo, null, &.{}),
        t("AAAARPT01", .none, .todo, null, &.{}),
    };
    try loadInto(&m, &distinct);
    try std.testing.expectEqual(@as(usize, 4), m.handle_len);

    // Both ids end "0001", so a fixed 4 would put the SAME handle on both rows
    // while `seshat show` printed two different ones. That drift is the bug.
    var colliding = [_]Task{
        t("AAAX0001", .none, .todo, null, &.{}),
        t("AAAY0001", .none, .todo, null, &.{}),
    };
    try loadInto(&m, &colliding);
    try std.testing.expectEqual(@as(usize, 5), m.handle_len);
}

test "replaceTasks can be called repeatedly without leaking" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    for (0..20) |i| {
        var tasks = [_]Task{t("aaa", .high, .todo, null, &.{})};
        tasks[0].meta.version = @intCast(i);
        try m.replaceTasks(&tasks);
    }
    try std.testing.expectEqual(@as(u64, 19), m.tasks[0].meta.version);
}

test "internId survives a task-set swap" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    var tasks = [_]Task{t("aaa", .high, .todo, null, &.{})};
    try m.replaceTasks(&tasks);
    const id = try m.internId(m.tasks[0].id);

    var next = [_]Task{t("aaa", .high, .todo, null, &.{})};
    try m.replaceTasks(&next);
    try std.testing.expectEqualStrings("aaa", id); // not a use-after-free
}

test "setStatus replaces the previous message without leaking" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    try m.setStatus("first", .{});
    try m.setStatus("count {d}", .{7});
    try std.testing.expectEqualStrings("count 7", m.status());
}

// `rows`, `scores` and `folds` are the other three gpa-owned allocations `deinit`
// is responsible for, and nothing else in this file populates them — so removing
// any of their frees leaves the rest of the suite green. Populating them through
// the real ledger pipeline also makes the borrowed-id hazard concrete: `Scores`
// keys and `Row.id` point into the live task arena, `folds` keys into the id arena.
test "deinit frees rows, scores and folds" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    var tasks = [_]Task{
        t("root", .high, .todo, NOW - DAY, &.{"kid"}),
        t("kid", .high, .todo, NOW - DAY, &.{}),
    };
    try m.replaceTasks(&tasks);

    try m.folds.put(try m.internId("root"), true);

    const scores = try ledger.computeScores(m.gpa, m.tasks, &m.idx, m.filters, m.now);
    m.scores.deinit();
    m.scores = scores;
    m.rows = try ledger.buildRows(m.gpa, m.tasks[0..1], m.tasks, &m.idx, &m.scores, &m.folds, m.filtering);

    try std.testing.expect(m.rows.len > 0);
    try std.testing.expect(m.scores.count() > 0);
    try std.testing.expect(m.folds.count() > 0);
}

// A real session can quit mid-edit — Esc is not guaranteed to have been pressed
// before the loop exits, and a commit can still be in flight. An editor buffer is
// gpa-allocated and hides inside a union that nothing else in `deinit` inspects,
// so this is the likeliest leak in the struct. Both slots are loaded at once
// because `.commit` deliberately retains the editor a conflict would restore.
test "deinit frees editor buffers left live in mode and in_flight" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);

    m.mode = .{ .editing = .{
        .id = try m.internId("aaa"),
        .field = .title,
        .editor = .{ .line = try editors.LineEditor.init(a, "a heap-allocated draft title") },
    } };
    m.in_flight = .{ .commit = .{
        .id = try m.internId("aaa"),
        .field = .description,
        .editor = .{ .line = try editors.LineEditor.init(a, "a heap-allocated in-flight body") },
    } };

    // No clearMode/clearInFlight: deinit alone must reclaim both buffers, or
    // std.testing.allocator fails this test as a leak.
    m.deinit();
}

test "clearMode and clearInFlight free the editor and reset the slot" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    m.mode = .{ .filter = try editors.LineEditor.init(a, "a heap-allocated filter expression") };
    m.clearMode();
    try std.testing.expect(m.mode == .list);

    m.in_flight = .{ .commit = .{
        .field = .title,
        .id = try m.internId("aaa"),
        .editor = .{ .line = try editors.LineEditor.init(a, "a heap-allocated pending edit") },
    } };
    m.clearInFlight();
    try std.testing.expect(m.in_flight == .none);

    // Clearing twice must not double-free: Editor.deinit retags to `.external`.
    m.clearMode();
    m.clearInFlight();

    // A second editor installed after a clear is still owned and still freed by
    // deinit — the retag must not have made the slot un-ownable.
    m.mode = .{ .add = try editors.LineEditor.init(a, "a heap-allocated new-task title") };
}

test "recompute ranks roots by subtree score and selects the first as cursor" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    var tasks = [_]Task{
        t("calm", .low, .todo, null, &.{}),
        t("quiet", .none, .todo, null, &.{"urgent"}),
        t("urgent", .high, .todo, NOW - DAY, &.{}),
    };
    try loadInto(&m, &tasks);

    // "quiet" scores 0 itself but holds an overdue high child, so it outranks "calm"
    // and auto-expands.
    try std.testing.expectEqualStrings("quiet", m.rows[0].id);
    try std.testing.expectEqualStrings("urgent", m.rows[1].id);
    try std.testing.expectEqualStrings("calm", m.rows[2].id);
    try std.testing.expectEqualStrings("quiet", m.cursor_id.?);
}

test "recompute keeps the cursor on its task across a re-rank" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    var tasks = [_]Task{
        t("aaa", .high, .todo, null, &.{}),
        t("bbb", .low, .todo, null, &.{}),
    };
    try loadInto(&m, &tasks);
    m.cursor_id = try m.internId("bbb");

    // Re-rank with bbb now the more urgent one.
    var next = [_]Task{
        t("aaa", .low, .todo, null, &.{}),
        t("bbb", .high, .todo, null, &.{}),
    };
    try loadInto(&m, &next);
    try std.testing.expectEqualStrings("bbb", m.cursor_id.?);
    try std.testing.expectEqual(@as(usize, 0), m.cursorIndex().?);
}

test "recompute moves the cursor to the NEAREST surviving row, not to row 0" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    var tasks = [_]Task{
        t("a1", .high, .todo, null, &.{}),
        t("a2", .medium, .todo, null, &.{}),
        t("a3", .low, .todo, null, &.{}),
    };
    try loadInto(&m, &tasks);
    m.cursor_id = try m.internId("a2"); // index 1

    var next = [_]Task{
        t("a1", .high, .todo, null, &.{}),
        t("a3", .low, .todo, null, &.{}),
    };
    try loadInto(&m, &next);
    // Index 1 survives as "a3" — NOT "a1", which a naive rows[0] fallback would give.
    try std.testing.expectEqualStrings("a3", m.cursor_id.?);
}

test "recompute clears the cursor when nothing survives" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    var tasks = [_]Task{t("only", .high, .todo, null, &.{})};
    try loadInto(&m, &tasks);
    try loadInto(&m, &[_]Task{});
    try std.testing.expect(m.cursor_id == null);
    try std.testing.expectEqual(@as(usize, 0), m.rows.len);
}

test "recompute keeps scroll_top inside the row list when it shrinks" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    m.viewport = .{ .cols = 80, .rows = 10 };

    var many: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    for (&many, &ids, 0..) |*task_, *idbuf, i| {
        _ = std.fmt.bufPrint(idbuf, "t{d:0>3}", .{i}) catch unreachable;
        task_.* = t(idbuf, .low, .todo, null, &.{});
    }
    try loadInto(&m, &many);
    m.scroll_top = 30;

    try loadInto(&m, many[0..3]);
    try std.testing.expect(m.scroll_top < m.rows.len);
}

// N tasks named t000.. that all tie on urgency, so the id tiebreak makes row i
// always "t{i:0>3}" — which is what lets the scroll tests assert exact indices.
fn fillSeq(tasks: []Task, ids: [][4]u8) void {
    for (tasks, ids, 0..) |*task_, *idbuf, i| {
        _ = std.fmt.bufPrint(idbuf, "t{d:0>3}", .{i}) catch unreachable;
        task_.* = t(idbuf, .low, .todo, null, &.{});
    }
}

// Defect 1. Cyclic data has no roots at all, so buildRows leads with an
// `unreachable_header` at row 0. A fallback that only walks BACKWARD from the
// anchor hits that header, gives up, and leaves the cursor null — permanently,
// because with no cursor_id there is nothing left to re-resolve from — even
// though every remaining row is selectable.
test "recompute selects a task below the anchor when row 0 is an unreachable header" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    var tasks = [_]Task{
        t("x", .none, .todo, null, &.{"y"}),
        t("y", .none, .todo, null, &.{"x"}),
    };
    try loadInto(&m, &tasks);

    try std.testing.expectEqual(ledger.RowKind.unreachable_header, m.rows[0].kind);
    try std.testing.expect(m.rows.len > 1);
    try std.testing.expect(m.cursor_id != null); // not stranded
    try std.testing.expectEqual(@as(usize, 1), m.cursorIndex().?);
}

// Defect 1, second half, plus the `.missing` skip. The anchor lands on a run of
// `.missing` rows: the nearest `.task` is one row FORWARD, while the nearest one
// backward is three rows away. A backward-only scan picks the far one.
test "recompute picks the nearest task row, not the nearest one behind it" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();

    // Both roots tie on urgency, so the id tiebreak orders aroot before zlater.
    var before = [_]Task{
        t("aroot", .none, .todo, null, &.{ "g1", "g2", "g3" }),
        t("g1", .none, .todo, null, &.{}),
        t("g2", .none, .todo, null, &.{}),
        t("g3", .none, .todo, null, &.{}),
        t("zlater", .none, .todo, null, &.{}),
    };
    try m.replaceTasks(&before);
    try m.folds.put(try m.internId("aroot"), true); // force it open; nothing here needs attention
    try recompute(&m);
    m.cursor_id = try m.internId("g3");
    try std.testing.expectEqual(@as(usize, 3), m.cursorIndex().?);

    // The three children vanish but are still referenced, so they become
    // `.missing` rows: [aroot, missing, missing, missing, zlater].
    var after = [_]Task{
        t("aroot", .none, .todo, null, &.{ "g1", "g2", "g3" }),
        t("zlater", .none, .todo, null, &.{}),
    };
    try loadInto(&m, &after);

    try std.testing.expectEqual(@as(usize, 5), m.rows.len);
    try std.testing.expectEqual(ledger.RowKind.missing, m.rows[3].kind);
    // Anchor 3: "zlater" is 1 row away, "aroot" is 3 rows back.
    try std.testing.expectEqualStrings("zlater", m.cursor_id.?);
}

// Defect 2. Zeroing the anchor when the cursor cannot be resolved throws away
// the user's position at the one moment it matters: an empty filtered view has
// no cursor to re-derive it from, so clearing the filter would dump them at the
// top of the list.
test "recompute restores the cursor position after a filter that matched nothing" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    m.viewport = .{ .cols = 80, .rows = 10 }; // 7 ledger rows

    var many: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    fillSeq(&many, &ids);
    try loadInto(&m, &many);

    m.cursor_id = try m.internId("t020");
    try recompute(&m);
    try std.testing.expectEqual(@as(usize, 14), m.scroll_top); // 20 + 1 - 7

    // A filter nothing matches: no rows, so no cursor either.
    m.filters = .{ .tags = &[_][]const u8{"nope"} };
    m.filtering = true;
    try recompute(&m);
    try std.testing.expectEqual(@as(usize, 0), m.rows.len);
    try std.testing.expect(m.cursor_id == null);
    try std.testing.expectEqual(@as(usize, 0), m.scroll_top); // clamped, not 20

    // Clearing it must put the cursor back where it was, not at row 0.
    m.filters = .{};
    m.filtering = false;
    try recompute(&m);
    try std.testing.expectEqualStrings("t020", m.cursor_id.?);
    try std.testing.expectEqual(@as(usize, 14), m.scroll_top);
}

// The brief's shrink test is satisfied by any clamp at all — even by passing a
// cursor index of 0 to ensureVisible. This pins the actual arithmetic: the
// viewport must follow the cursor, using the ledger height (viewport - 3).
test "recompute scrolls the viewport down to the cursor row" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    m.viewport = .{ .cols = 80, .rows = 10 }; // 10 - 3 = 7 ledger rows

    var many: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    fillSeq(&many, &ids);
    try loadInto(&m, &many);
    try std.testing.expectEqual(@as(usize, 0), m.scroll_top);

    m.cursor_id = try m.internId("t035");
    try recompute(&m);
    try std.testing.expectEqual(@as(usize, 35), m.cursorIndex().?);
    try std.testing.expectEqual(@as(usize, 29), m.scroll_top); // 35 + 1 - 7
}

test "enter descends list -> field, escape ascends" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try std.testing.expect(h.m.mode == .list);
    try h.key(.enter);
    try std.testing.expectEqual(FieldId.title, h.m.mode.field);
    try std.testing.expect(h.m.pane_open); // descending opens the pane
    try h.key(.escape);
    try std.testing.expect(h.m.mode == .list);
}

test "up and down walk the field list without wrapping past the ends" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.up);
    try std.testing.expectEqual(FieldId.title, h.m.mode.field);
    try h.key(.down);
    try std.testing.expectEqual(FieldId.description, h.m.mode.field);
    for (0..10) |_| try h.key(.down);
    try std.testing.expectEqual(FieldId.tags, h.m.mode.field);
}

test "enter on an enum field opens a pick editor seeded with the current value" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..3) |_| try h.key(.down); // title -> description -> status -> priority
    try std.testing.expectEqual(FieldId.priority, h.m.mode.field);
    try h.key(.enter);
    try std.testing.expect(h.m.mode.editing.editor == .pick);
    // Priority declaration order is none, low, medium, high => medium is index 2.
    try std.testing.expectEqual(@as(usize, 2), h.m.mode.editing.editor.pick.index);
}

test "enter on the status field seeds the pick from the current status" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .in_progress, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..2) |_| try h.key(.down); // -> status
    try h.key(.enter);
    // Status declaration order is todo, in_progress, done, cancelled => index 1.
    try std.testing.expectEqual(@as(usize, 1), h.m.mode.editing.editor.pick.index);
}

test "enter on a text field opens a line editor prefilled with the value" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("hello", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.enter);
    try std.testing.expectEqualStrings("hello", h.m.mode.editing.editor.line.text());
}

test "escape from an editor returns to the field and frees the editor" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.enter);
    try std.testing.expect(h.m.mode == .editing);
    try h.key(.escape);
    try std.testing.expectEqual(FieldId.title, h.m.mode.field);
}

test "j and k move the cursor, stored by id" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("aaa", .high, .todo, null, &.{}),
        t("bbb", .low, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try std.testing.expectEqualStrings("aaa", h.m.cursor_id.?);
    try h.key(.{ .char = 'j' });
    try std.testing.expectEqualStrings("bbb", h.m.cursor_id.?);
    try h.key(.{ .char = 'j' }); // clamps at the end
    try std.testing.expectEqualStrings("bbb", h.m.cursor_id.?);
    try h.key(.{ .char = 'k' });
    try std.testing.expectEqualStrings("aaa", h.m.cursor_id.?);
}

test "h and l collapse and expand the selected node" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{"kid"}),
        t("kid", .high, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 2), h.m.rows.len); // auto-expanded
    try h.key(.{ .char = 'h' });
    try std.testing.expectEqual(@as(usize, 1), h.m.rows.len);
    try h.key(.{ .char = 'l' });
    try std.testing.expectEqual(@as(usize, 2), h.m.rows.len);
}

test "l on a leaf and h on an already-collapsed node are no-ops" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("leaf", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'l' });
    try h.key(.{ .char = 'h' });
    try std.testing.expectEqual(@as(usize, 1), h.m.rows.len);
    try std.testing.expect(h.last == .none);
}

test "q emits quit" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'q' });
    try std.testing.expect(h.last == .quit);
}

test "resize updates the viewport and re-clamps the scroll offset" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.send(.{ .resize = .{ .cols = 100, .rows = 40 } });
    try std.testing.expectEqual(@as(u16, 40), h.m.viewport.rows);
    try std.testing.expect(h.m.scroll_top < @max(1, h.m.rows.len));
}

// The `.task`-kind skip in `moveCursor` is double-masked: `recompute` self-heals
// a cursor interned from a non-selectable row (it fails `cursorIndex`, gets
// nulled, and `nearestTaskRow` puts it back), so removing the check leaves every
// other test green. It only becomes observable across a run of TWO OR MORE
// consecutive non-`.task` rows, where the self-heal walks the cursor back to
// where it started and `j` silently does nothing. Two dangling children give
// exactly that shape.
test "j jumps over a run of .missing rows to the next task" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("aroot", .low, .todo, null, &.{ "ghost1", "ghost2" }),
        t("zlater", .low, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'l' }); // expand -> two .missing rows appear
    try std.testing.expectEqual(@as(usize, 4), h.m.rows.len);
    try std.testing.expectEqual(ledger.RowKind.missing, h.m.rows[1].kind);
    try std.testing.expectEqual(ledger.RowKind.missing, h.m.rows[2].kind);
    try h.key(.{ .char = 'j' });
    try std.testing.expectEqualStrings("zlater", h.m.cursor_id.?);
    try h.key(.{ .char = 'k' });
    try std.testing.expectEqualStrings("aroot", h.m.cursor_id.?);
}

// Descending needs a task to descend INTO. Without the guard this opens the pane
// on a phantom and leaves `.field` mode with no id for a later commit to target.
test "enter on an empty list does not descend into a phantom task" {
    const a = std.testing.allocator;
    var h: TestHarness = undefined;
    try h.setup(a, &.{});
    defer h.deinit();
    try std.testing.expect(h.m.cursor_id == null);
    try h.key(.enter);
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(!h.m.pane_open);
    try std.testing.expect(h.last == .none);
}

fn manyTasks(buf: []Task, ids: [][4]u8) []Task {
    for (buf, ids, 0..) |*task_, *idbuf, i| {
        _ = std.fmt.bufPrint(idbuf, "t{d:0>3}", .{i}) catch unreachable;
        task_.* = t(idbuf, .low, .todo, null, &.{});
    }
    return buf;
}

test "G jumps to the last row, g to the first" {
    const a = std.testing.allocator;
    var buf: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    var h: TestHarness = undefined;
    try h.setup(a, manyTasks(&buf, &ids));
    defer h.deinit();
    try h.send(.{ .resize = .{ .cols = 80, .rows = 20 } });

    try h.key(.{ .char = 'G' });
    try std.testing.expectEqual(h.m.rows.len - 1, h.m.cursorIndex().?);
    try std.testing.expect(h.m.scroll_top > 0);

    try h.key(.{ .char = 'g' });
    try std.testing.expectEqual(@as(usize, 0), h.m.cursorIndex().?);
    try std.testing.expectEqual(@as(usize, 0), h.m.scroll_top);
}

// Ledger for this setup (viewport rows=20 -> ledger_rows = 20-3 = 17, pane
// closed so nothing eats into it) is all plain `.task` rows, so half a page is
// halfPage(17) = 8. The exact scroll_top values below are ensureVisible's
// arithmetic worked through by hand: they pin `pageBy`'s own `recompute` call,
// which nothing else in this test would trigger — cursorIndex() alone is
// derived straight from cursor_id and would keep passing even if that call
// were deleted (scroll_top would just stay frozen at its previous value).
test "Ctrl-D and Ctrl-U move by half a page, clamp at the ends, and drag the viewport along" {
    const a = std.testing.allocator;
    var buf: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    var h: TestHarness = undefined;
    try h.setup(a, manyTasks(&buf, &ids));
    defer h.deinit();
    try h.send(.{ .resize = .{ .cols = 80, .rows = 20 } });

    const before = h.m.cursorIndex().?;
    try h.key(.ctrl_d);
    try std.testing.expect(h.m.cursorIndex().? > before);
    for (0..20) |_| try h.key(.ctrl_d);
    try std.testing.expectEqual(h.m.rows.len - 1, h.m.cursorIndex().?);
    try std.testing.expectEqual(@as(usize, 23), h.m.scroll_top); // 39 + 1 - 17
    for (0..20) |_| try h.key(.ctrl_u);
    try std.testing.expectEqual(@as(usize, 0), h.m.cursorIndex().?);
    try std.testing.expectEqual(@as(usize, 0), h.m.scroll_top);
}

// `scanTaskRow` is only ever reached today through `pageBy`, whose
// `cursorIndex() orelse return` guard already proves `rows.len > 0`. Pin the
// helper's totality anyway: `.prev` dereferences `rows[i]` before any bounds
// check, so an empty list or an out-of-range start used to panic, while `.next`
// returned null. A later task calling it from a new site would have found that
// the hard way.
test "scanTaskRow is total: empty list and out-of-range start in both directions" {
    const empty: []const ledger.Row = &.{};
    try std.testing.expect(scanTaskRow(empty, 0, .prev) == null);
    try std.testing.expect(scanTaskRow(empty, 0, .next) == null);
    try std.testing.expect(scanTaskRow(empty, 7, .prev) == null);

    const rows = [_]ledger.Row{
        .{ .id = "", .kind = .unreachable_header, .depth = 0, .last_sibling = true, .descendants = 0, .attention = 0, .expanded = true, .dimmed = false },
        .{ .id = "a", .kind = .task, .depth = 0, .last_sibling = true, .descendants = 0, .attention = 0, .expanded = false, .dimmed = false },
    };
    // A start past the end clamps rather than reading out of bounds.
    try std.testing.expectEqual(@as(?usize, 1), scanTaskRow(&rows, 99, .prev));
    try std.testing.expectEqual(@as(?usize, 1), scanTaskRow(&rows, 0, .next));
}

// Defect: `pageBy` used to route its half-page target through `nearestTaskRow`,
// which picks whichever direction is CLOSER — including back the way the
// cursor came. With a long `.missing` run sitting about half a page ahead of
// the cursor, the target lands inside the run and the nearest `.task` row to
// it is the very row the cursor is already on: Ctrl-D would never move.
// `scanTaskRow` fixes this by only ever looking in the direction of travel.
test "Ctrl-D and Ctrl-U scan past a long run of missing rows instead of stalling" {
    const a = std.testing.allocator;
    var kid_bufs: [20][4]u8 = undefined;
    var kid_ids: [20][]const u8 = undefined;
    for (&kid_bufs, &kid_ids, 0..) |*buf, *slice, i| {
        _ = std.fmt.bufPrint(buf, "g{d:0>3}", .{i}) catch unreachable;
        slice.* = buf;
    }
    var tasks = [_]Task{
        t("a", .low, .todo, null, &.{}),
        t("b", .low, .todo, null, &kid_ids), // 20 dangling children -> 20 .missing rows once expanded
        t("c", .low, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.send(.{ .resize = .{ .cols = 80, .rows = 23 } }); // ledger_rows = 20, half = 10

    try h.key(.{ .char = 'j' }); // -> "b"
    try std.testing.expectEqualStrings("b", h.m.cursor_id.?);
    try h.key(.{ .char = 'l' }); // expand -> rows: a, b, 20x missing, c (23 rows)
    try std.testing.expectEqual(@as(usize, 23), h.m.rows.len);
    for (h.m.rows[2..22]) |r| try std.testing.expectEqual(ledger.RowKind.missing, r.kind);

    // Target = 1 + 10 = 11, inside the missing run. The nearest task row to 11
    // is "b" itself (distance 10 vs. 11 to "c") — the stall the old code hit.
    try h.key(.ctrl_d);
    try std.testing.expectEqualStrings("c", h.m.cursor_id.?);

    try h.key(.ctrl_u);
    try std.testing.expectEqualStrings("b", h.m.cursor_id.?);
}

// The Tab-open scroll_top is asserted right after the Tab press with no
// intervening key that itself recomputes — `G` runs first to position the
// cursor and stamp `cursor_anchor`, but its own recompute happens BEFORE the
// pane opens, so it cannot mask Tab's. Deleting Tab's `recompute` call would
// leave scroll_top frozen at G's value (23) instead of following the layout
// change to 29, then frozen at 29 instead of settling back to 23 on close.
test "Tab toggles the detail pane and re-clamps the viewport" {
    const a = std.testing.allocator;
    var buf: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    var h: TestHarness = undefined;
    try h.setup(a, manyTasks(&buf, &ids));
    defer h.deinit();
    try h.send(.{ .resize = .{ .cols = 80, .rows = 20 } }); // ledger_rows = 17 closed, 11 open

    try h.key(.{ .char = 'G' }); // cursor -> last row, scroll_top = 39+1-17 = 23
    try std.testing.expectEqual(@as(usize, 23), h.m.scroll_top);

    try std.testing.expect(!h.m.pane_open);
    try h.key(.tab);
    try std.testing.expect(h.m.pane_open);
    // Layout shrinks to 11 ledger rows; ensureVisible(39, 40, 11, 23) = 39+1-11 = 29.
    try std.testing.expectEqual(@as(usize, 29), h.m.scroll_top);

    try h.key(.tab);
    try std.testing.expect(!h.m.pane_open);
    // Layout grows back to 17; ensureVisible(39, 40, 17, 29) clamps top to
    // max_top = 40-17 = 23 before the cursor check, landing back at 23.
    try std.testing.expectEqual(@as(usize, 23), h.m.scroll_top);
}

test "the viewport keys are inert while a field is focused" {
    const a = std.testing.allocator;
    var buf: [40]Task = undefined;
    var ids: [40][4]u8 = undefined;
    var h: TestHarness = undefined;
    try h.setup(a, manyTasks(&buf, &ids));
    defer h.deinit();
    try h.key(.enter); // -> .field
    const cursor = h.m.cursor_id.?;
    try h.key(.{ .char = 'G' });
    try std.testing.expectEqualStrings(cursor, h.m.cursor_id.?);
}

// The previous task deliberately decided Escape does NOT clear pane_open — it is
// a user-owned toggle that Enter force-opens; clearing it on Escape would close a
// pane the user had opened themselves. Tab is the independent toggle, so this is
// the natural place to pin that decision before it regresses silently.
test "escape does not clear a pane the user opened with Tab" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.tab);
    try std.testing.expect(h.m.pane_open);
    try h.key(.enter); // -> .field
    try h.key(.escape); // -> .list
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(h.m.pane_open); // still open: escape is not a pane toggle
}

test "committing a pick emits one Command.commit with exactly one field changed" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    tasks[0].meta.version = 7;
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.enter);
    for (0..3) |_| try h.key(.down); // -> priority
    try h.key(.enter); // pick opens at index 2 (medium)
    try h.key(.down); // -> high
    try h.key(.enter); // commit

    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("a", h.last.commit.id);
    try std.testing.expectEqual(@as(u64, 7), h.last.commit.expected_version);
    try std.testing.expectEqual(Priority.high, h.last.commit.content.priority);
    try std.testing.expectEqualStrings("a", h.last.commit.content.title); // untouched
    try std.testing.expectEqual(Status.todo, h.last.commit.content.status);
    try std.testing.expect(h.m.in_flight == .commit);
    // Mode leaves .editing — the editor was MOVED into in_flight.
    try std.testing.expectEqual(FieldId.priority, h.m.mode.field);
    // No optimistic write.
    try std.testing.expectEqual(Priority.medium, h.m.tasks[0].content.priority);
}

test "committing a date parses with the configured offset" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    h.m.offset_minutes = 180;

    try h.key(.enter);
    for (0..4) |_| try h.key(.down); // -> due
    try h.key(.enter);
    for ("2026-08-02") |c| try h.key(.{ .char = c });
    try h.key(.enter);

    try std.testing.expect(h.last == .commit);
    // Local end-of-day at +03:00, stored as UTC.
    // 1785628800 == 2026-08-02T00:00:00Z (verified: `date -u -d @1785628800`).
    const day_start: i64 = 1785628800;
    try std.testing.expectEqual(@as(?i64, day_start + 86399 - 180 * 60), h.last.commit.content.due_at);
}

test "a bad date keeps the editor open with the text intact and emits no command" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..4) |_| try h.key(.down);
    try h.key(.enter);
    for ("nonsense") |c| try h.key(.{ .char = c });
    try h.key(.enter);

    try std.testing.expect(h.last == .none);
    try std.testing.expect(h.m.mode == .editing);
    try std.testing.expectEqualStrings("nonsense", h.m.mode.editing.editor.line.text());
    try std.testing.expect(h.m.status().len > 0);
}

test "an empty title is refused client-side" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("abcdefgh", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.enter);
    for (0..8) |_| try h.key(.backspace);
    try h.key(.enter);
    try std.testing.expect(h.last == .none);
    try std.testing.expect(h.m.mode == .editing);
}

test "committing tags splits on commas and survives the editor being freed" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..6) |_| try h.key(.down); // -> tags
    try h.key(.enter);
    for ("ops,urgent") |c| try h.key(.{ .char = c });
    try h.key(.enter);

    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqual(@as(usize, 2), h.last.commit.content.tags.len);
    try std.testing.expectEqualStrings("ops", h.last.commit.content.tags[0]);
    try std.testing.expectEqualStrings("urgent", h.last.commit.content.tags[1]);
}

test "a second mutation while one is in flight is refused" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..3) |_| try h.key(.down);
    try h.key(.enter);
    try h.key(.down);
    try h.key(.enter); // in flight
    try std.testing.expect(h.m.in_flight == .commit);

    try h.key(.escape);
    try h.key(.{ .char = ' ' });
    try std.testing.expect(h.last == .none);
    try std.testing.expect(h.m.status().len > 0);
}

test "editing the description emits open_editor rather than a commit" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.down); // -> description
    try h.key(.enter);
    try std.testing.expect(h.last == .open_editor);
    try std.testing.expectEqualStrings("a", h.last.open_editor.id);
    try std.testing.expect(h.m.mode.editing.editor == .external);
}

// Clearing a date must be reachable by DELETING the field's contents. Routing an
// empty buffer through `edit.parseDate` reports it as malformed ("not a date: ")
// and leaves the user with no way to clear a due date short of knowing the magic
// word `none` — a dead end, not just an ugly message.
test "emptying a date field clears the date rather than failing to parse" {
    const a = std.testing.allocator;
    // A buffer the user blanked, and one left holding only whitespace.
    for ([_][]const u8{ "", "   " }) |typed| {
        var tasks = [_]Task{t("a", .medium, .todo, NOW + DAY, &.{})};
        var h: TestHarness = undefined;
        try h.setup(a, &tasks);
        defer h.deinit();
        try std.testing.expect(h.m.tasks[0].content.due_at != null); // there IS one to clear

        try h.key(.enter);
        for (0..4) |_| try h.key(.down); // -> due
        try h.key(.enter); // prefilled with the formatted date
        for (0..32) |_| try h.key(.backspace); // backspace at the start is a no-op
        for (typed) |c| try h.key(.{ .char = c });
        try h.key(.enter);

        try std.testing.expect(h.last == .commit);
        try std.testing.expectEqual(@as(?i64, null), h.last.commit.content.due_at);
        // A clear, not a silent no-op: the editor really did commit and move on.
        try std.testing.expect(h.m.in_flight == .commit);
    }
}

// True when `s` lies anywhere inside `buf`'s bytes — i.e. `s` was never copied
// out of it.
fn aliases(s: []const u8, buf: []const u8) bool {
    const p = @intFromPtr(s.ptr);
    return p >= @intFromPtr(buf.ptr) and p < @intFromPtr(buf.ptr) + buf.len;
}

// The brief's tags test reads `h.last` while the editor is still ALIVE (it was
// moved into `in_flight`, not freed), so it passes byte-for-byte even when the
// segments still point straight into that buffer — `splitTags` allocates only
// the outer slice. Asserting non-aliasing is what actually pins the dupe, and it
// is deterministic where a free-then-read would depend on allocator internals.
test "committed tag text is copied out of the editor buffer, not aliased into it" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..6) |_| try h.key(.down); // -> tags
    try h.key(.enter);
    for ("ops,urgent") |c| try h.key(.{ .char = c });
    try h.key(.enter);

    const typed = h.m.in_flight.commit.editor.line.text();
    for (h.last.commit.content.tags) |tag| try std.testing.expect(!aliases(tag, typed));
}

// The title path has no brief test that commits at all (the empty-title one is
// refused before a command exists), so both halves are pinned here: the typed
// text reaches the command, and it is a copy rather than a view of the editor.
test "committing a title sends the typed text, copied out of the editor buffer" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("ab", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.enter); // line editor, prefilled "ab", cursor at the end
    for ("cd") |c| try h.key(.{ .char = c });
    try h.key(.enter);

    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("abcd", h.last.commit.content.title);
    const typed = h.m.in_flight.commit.editor.line.text();
    try std.testing.expectEqualStrings("abcd", typed);
    try std.testing.expect(!aliases(h.last.commit.content.title, typed));
}

// `in_flight` holds the editor a failed commit has to restore (task 14), so
// `Mode` must not acquire a SECOND one meanwhile — otherwise that restore either
// leaks the newer editor or clobbers the user's newer text. Refusing to open one
// is what makes "exactly one live editor" an invariant rather than a coincidence.
test "a field cannot be opened for editing while a commit is in flight" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    for (0..3) |_| try h.key(.down);
    try h.key(.enter);
    try h.key(.down);
    try h.key(.enter); // commit -> in flight, mode back to .field
    try std.testing.expect(h.m.in_flight == .commit);

    try h.key(.enter); // would open a second editor
    try std.testing.expect(h.last == .none);
    try std.testing.expectEqual(FieldId.priority, h.m.mode.field); // still .field
    try std.testing.expect(h.m.status().len > 0);
}

fn commitPriorityHigh(h: *TestHarness) !void {
    try h.key(.enter);
    for (0..3) |_| try h.key(.down);
    try h.key(.enter);
    try h.key(.down);
    try h.key(.enter);
}

test "commit_ok applies the server's authoritative task and clears in_flight" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try commitPriorityHigh(&h);

    var echoed = [_]Task{t("a", .high, .todo, null, &.{})};
    echoed[0].meta.version = 8;
    try h.send(.{ .commit_ok = &echoed });

    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expectEqual(Priority.high, h.m.tasks[0].content.priority);
    try std.testing.expectEqual(@as(u64, 8), h.m.tasks[0].meta.version);
    try std.testing.expectEqual(FieldId.priority, h.m.mode.field);
}

test "request_failed on a commit reopens the editor with the typed value intact" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try commitPriorityHigh(&h);

    try h.send(.{ .request_failed = "connection reset" });

    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expect(h.m.mode == .editing);
    try std.testing.expectEqual(@as(usize, 3), h.m.mode.editing.editor.pick.index); // "high"
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "connection reset") != null);
    try std.testing.expectEqual(Priority.medium, h.m.tasks[0].content.priority); // never optimistic
}

test "conflict ALSO reopens the editor and applies the server's version" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    tasks[0].meta.version = 7;
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try commitPriorityHigh(&h);

    var fresh = [_]Task{t("a", .low, .todo, null, &.{})};
    fresh[0].meta.version = 9;
    try h.send(.{ .conflict = &fresh });

    try std.testing.expect(h.m.mode == .editing); // not discarded
    try std.testing.expectEqual(@as(usize, 3), h.m.mode.editing.editor.pick.index);
    try std.testing.expectEqual(Priority.low, h.m.tasks[0].content.priority); // server wins
    try std.testing.expectEqual(@as(u64, 9), h.m.tasks[0].meta.version);
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "changed on the server") != null);
}

// FINAL REVIEW, finding 1 (CRITICAL). `.conflict` restores the editor and THEN
// merges + recomputes — and `recompute` re-resolves the cursor, moving it off the
// conflicting task the moment that task stops matching the active filter. The
// reapplied commit must still target the task the editor was OPENED on; targeting
// the cursor writes the user's text onto a task they never touched, at that task's
// own version, so the server accepts it.
test "a conflict under a filter that then excludes the task reapplies to THAT task" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("AAA1", .high, .todo, null, &.{}),
        t("BBB2", .medium, .todo, null, &.{}),
    };
    tasks[0].meta.version = 3;
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    // `status:todo` matches both — for now.
    try h.key(.{ .char = '/' });
    for ("status:todo") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expect(h.m.filtering);
    try std.testing.expectEqualStrings("AAA1", h.m.cursor_id.?);

    // Retitle AAA1 to "AAAZ" and commit.
    try h.key(.enter); // .field title
    try h.key(.enter); // line editor, prefilled "AAA1"
    try h.key(.backspace);
    try h.key(.{ .char = 'Z' });
    try h.key(.enter);
    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("AAA1", h.last.commit.id);

    // 409: the server's AAA1 is now `.done`, so it drops out of `status:todo`
    // and its row disappears — which is what moves the cursor to BBB2.
    var fresh = [_]Task{t("AAA1", .high, .done, null, &.{})};
    fresh[0].meta.version = 9;
    try h.send(.{ .conflict = &fresh });
    try std.testing.expect(h.m.mode == .editing);
    try std.testing.expectEqualStrings("AAAZ", h.m.mode.editing.editor.line.text());

    // "press enter to reapply" — onto AAA1, at AAA1's version.
    try h.key(.enter);
    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("AAA1", h.last.commit.id);
    try std.testing.expectEqualStrings("AAAZ", h.last.commit.content.title);
    try std.testing.expectEqual(@as(u64, 9), h.last.commit.expected_version);
    // …and BBB2 is untouched: nothing was ever written optimistically.
    try std.testing.expectEqualStrings("BBB2", h.m.idx.by_id.get("BBB2").?.content.title);
}

// The other half of finding 1. The cursor also moves ON PURPOSE: nothing stops
// the user escaping to the list and walking away while a commit is out. What
// `restoreEditor` hands back must be the id the REQUEST was for, which is the one
// piece of information the restore used to drop on the floor.
test "a conflict restores the editor onto its own task after the cursor moved away" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("AAA1", .high, .todo, null, &.{}),
        t("BBB2", .medium, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try std.testing.expectEqualStrings("AAA1", h.m.cursor_id.?);

    try h.key(.enter); // .field title
    try h.key(.enter); // line editor on AAA1, prefilled "AAA1"
    try h.key(.backspace);
    try h.key(.{ .char = 'Z' });
    try h.key(.enter); // commit AAA1
    try std.testing.expectEqualStrings("AAA1", h.m.in_flight.commit.id);

    // The user walks away while the request is still out.
    try h.key(.escape);
    try h.key(.{ .char = 'j' });
    try std.testing.expectEqualStrings("BBB2", h.m.cursor_id.?);

    var fresh = [_]Task{t("AAA1", .high, .todo, null, &.{})};
    fresh[0].meta.version = 9;
    try h.send(.{ .conflict = &fresh });
    try std.testing.expect(h.m.mode == .editing);
    try std.testing.expectEqualStrings("AAA1", h.m.mode.editing.id);

    try h.key(.enter);
    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("AAA1", h.last.commit.id);
    try std.testing.expectEqualStrings("AAAZ", h.last.commit.content.title);
    try std.testing.expectEqual(@as(u64, 9), h.last.commit.expected_version);
}

// FINAL REVIEW, finding 3 (IMPORTANT). `.field` survives its task being FILTERED
// away — `modeAnchor` only clears a mode when the anchored task leaves the Index,
// and a task that merely stops matching is still in it — so `recompute` nulls
// `cursor_id` underneath a live `.field`. Enter must not then install an editor it
// has no task to open: the `.description` case returned `.none`, so `$EDITOR`
// never ran, and the pane sat on "editing in $EDITOR…" forever.
test "Enter in .field with no resolvable cursor refuses instead of opening a phantom editor" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.{ .char = '/' });
    for ("status:todo") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try h.key(.enter); // descend: .field title
    try h.key(.down); // .field description
    try std.testing.expectEqual(FieldId.description, h.m.mode.field);

    // A refresh lands with the task now `.done`: still in the Index, so the mode
    // survives, but it no longer matches `status:todo`, so there are no rows.
    var fresh = [_]Task{t("a", .medium, .done, null, &.{})};
    try h.send(.{ .tasks_loaded = &fresh });
    try std.testing.expect(h.m.mode == .field);
    try std.testing.expect(h.m.cursor_id == null);
    try std.testing.expectEqual(@as(usize, 0), h.m.rows.len);

    try h.key(.enter);
    try std.testing.expect(h.last == .none);
    try std.testing.expect(h.m.mode == .field); // NOT parked in an editor
    try std.testing.expect(h.m.status().len > 0);
}

test "editor_returned null is a cancel and emits nothing" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.down);
    try h.key(.enter);
    try h.send(.{ .editor_returned = null });
    try std.testing.expect(h.last == .none);
    try std.testing.expectEqual(FieldId.description, h.m.mode.field);
}

test "editor_returned text commits the description" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.down);
    try h.key(.enter);
    try h.send(.{ .editor_returned = "a new description" });
    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("a new description", h.last.commit.content.description);
}

test "a failed INITIAL load sets load_failed; R retries and clears it" {
    const a = std.testing.allocator;
    var m: Model = undefined;
    try m.init(a, NOW, 0);
    defer m.deinit();
    m.in_flight = .refresh;

    _ = try update(a, &m, .{ .request_failed = "server down" });
    try std.testing.expect(m.load_failed);
    try std.testing.expect(m.in_flight == .none);
    try std.testing.expect(std.mem.indexOf(u8, m.status(), "server down") != null);

    const cmd = try update(a, &m, .{ .key = .{ .char = 'R' } });
    try std.testing.expect(cmd == .fetch);

    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    _ = try update(a, &m, .{ .tasks_loaded = &tasks });
    try std.testing.expect(!m.load_failed);
}

test "a failed REFRESH keeps the existing data and does not set load_failed" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'R' });
    try h.send(.{ .request_failed = "server down" });

    try std.testing.expect(!h.m.load_failed); // we still have data
    try std.testing.expectEqual(@as(usize, 1), h.m.tasks.len);
    try std.testing.expect(h.m.status().len > 0);
}

// The brief's commit_ok/conflict tests both use a ONE-task set, where merging by
// id and wholesale-replacing with the echo are indistinguishable — and the server
// echoes only the tasks it wrote. Replacing wholesale would therefore delete
// every task the user did not just edit. Ids of differing lengths also vary the
// task set's SHAPE across the swap, so a surviving id that dangled into the old
// arena cannot read back correct by landing at the same address.
test "commit_ok merges the echo by id instead of replacing the whole task set" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("aa", .medium, .todo, null, &.{}),
        t("bbbbbbbb", .low, .todo, null, &.{}),
        t("ccc", .none, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try commitPriorityHigh(&h); // cursor is on "aa" (highest urgency)
    try std.testing.expectEqualStrings("aa", h.m.in_flight.commit.id);

    var echoed = [_]Task{t("aa", .high, .todo, null, &.{})};
    try h.send(.{ .commit_ok = &echoed });

    try std.testing.expectEqual(@as(usize, 3), h.m.tasks.len);
    try std.testing.expectEqual(Priority.high, h.m.idx.by_id.get("aa").?.content.priority);
    try std.testing.expectEqual(Priority.low, h.m.idx.by_id.get("bbbbbbbb").?.content.priority);
    try std.testing.expectEqual(Priority.none, h.m.idx.by_id.get("ccc").?.content.priority);
    // The interned cursor id still reads correctly after the swap.
    try std.testing.expectEqualStrings("aa", h.m.cursor_id.?);
}

// The `.create` branch of `request_failed` has no key path to reach it until the
// `a` key exists, so it is driven directly here — otherwise its "keep Mode.add
// and its text" rule ships with zero coverage and could be a bare `clearMode`.
test "request_failed on a create keeps the add-mode text the user typed" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    h.m.mode = .{ .add = try editors.LineEditor.init(a, "a half-typed new task") };
    h.m.in_flight = .{ .create = .{ .title = try h.m.internId("a half-typed new task") } };

    try h.send(.{ .request_failed = "connection reset" });

    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expect(h.m.mode == .add);
    try std.testing.expectEqualStrings("a half-typed new task", h.m.mode.add.text());
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "connection reset") != null);
}

// Both of the brief's restore tests use a PICK editor, which owns no heap memory
// at all — the move back out of `in_flight` could leak or double-free a buffer
// and they would still pass byte-for-byte. A LINE editor is where the ownership
// is real, so this is the test that actually exercises the handoff: the buffer
// must arrive intact, still owned (typing into it must work), and still freed by
// deinit.
test "a failed commit hands a line editor's heap buffer back intact and still owned" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("ab", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.enter); // title line editor, prefilled "ab"
    for ("cd") |c| try h.key(.{ .char = c });
    try h.key(.enter); // commit -> the editor MOVES into in_flight

    try h.send(.{ .request_failed = "connection reset" });

    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expect(h.m.mode == .editing);
    try std.testing.expectEqualStrings("abcd", h.m.mode.editing.editor.line.text());
    try std.testing.expectEqualStrings("ab", h.m.tasks[0].content.title); // never optimistic
    // Still writable, and re-committable: a stale copy would strand the append.
    try h.key(.{ .char = 'e' });
    try std.testing.expectEqualStrings("abcde", h.m.mode.editing.editor.line.text());
    try h.key(.enter);
    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("abcde", h.last.commit.content.title);
}

// The description is the one field edited OUT of process, so it used to be the
// one field where a failed commit lost the work outright: the editor carried no
// text, Enter on it was a silent no-op with no status, and Escape+re-enter
// reseeded $EDITOR from the task's OLD description. `.external` now owns the
// returned text, which makes "a dropped connection never costs a retype" true
// here too. The source buffer is overwritten right after it is handed over,
// because the shell frees its own buffer the moment `update` returns.
test "a failed description commit retains the returned text and enter retries it" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.down); // -> description
    try h.key(.enter); // -> .open_editor, editor is .external with nothing retained
    try std.testing.expect(h.m.mode.editing.editor.external == null);

    var from_shell = "a long body typed in $EDITOR".*;
    try h.send(.{ .editor_returned = &from_shell });
    @memset(from_shell[0..], 'X'); // the shell's buffer is gone the instant update returns
    try std.testing.expect(h.last == .commit);

    try h.send(.{ .request_failed = "connection reset" });
    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expect(h.m.mode == .editing);
    // The work survives, in a buffer the model owns.
    try std.testing.expectEqualStrings("a long body typed in $EDITOR", h.m.mode.editing.editor.external.?);
    try std.testing.expectEqualStrings("", h.m.tasks[0].content.description); // never optimistic

    // Enter RETRIES from the retained text instead of being a silent no-op.
    try h.key(.enter);
    try std.testing.expect(h.last == .commit);
    try std.testing.expectEqualStrings("a long body typed in $EDITOR", h.last.commit.content.description);
    try std.testing.expect(h.m.in_flight == .commit);
}

// `tasks_loaded` clears `in_flight` only when the slot is `.refresh`. A blanket
// clear there would FREE the editor an outstanding `.commit` still owes back,
// and the model would have nothing to restore when that commit fails. No value
// assertion on the refresh itself can see that (the freed union reads correctly),
// so this drives the failure through to the restore and then writes to the buffer.
test "a refresh landing mid-commit leaves the in-flight editor untouched" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("ab", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.enter); // title line editor, prefilled "ab"
    for ("cd") |c| try h.key(.{ .char = c });
    try h.key(.enter); // commit -> the editor moves into in_flight
    try std.testing.expect(h.m.in_flight == .commit);

    var refreshed = [_]Task{t("ab", .low, .todo, null, &.{})};
    try h.send(.{ .tasks_loaded = &refreshed });
    try std.testing.expect(h.m.in_flight == .commit); // NOT cancelled
    try std.testing.expectEqualStrings("abcd", h.m.in_flight.commit.editor.line.text());

    try h.send(.{ .request_failed = "connection reset" });
    try std.testing.expectEqualStrings("abcd", h.m.mode.editing.editor.line.text());
    try h.key(.{ .char = 'e' }); // still genuinely owned, not a freed copy
    try std.testing.expectEqualStrings("abcde", h.m.mode.editing.editor.line.text());
}

// `.conflict` restores the editor out of a `.commit` slot — but any OTHER slot
// must still be emptied, or the model stays "busy" forever and refuses every
// later mutation. Unreachable until deletes are wired (tasks 15/18), which is
// exactly why it needs pinning now rather than after it goes live.
test "conflict clears an in-flight slot that carries no editor" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    h.m.in_flight = .{ .delete = .{ .id = try h.m.internId("a") } };

    var fresh = [_]Task{t("a", .low, .todo, null, &.{})};
    try h.send(.{ .conflict = &fresh });

    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expectEqual(Priority.low, h.m.tasks[0].content.priority);
    // Still busy would refuse this outright.
    try h.key(.{ .char = 'R' });
    try std.testing.expect(h.last == .fetch);
}

// The mirror of the `tasks_loaded` scoping: a `commit_ok` answers the COMMIT
// slot, so clearing unconditionally would silently cancel a refresh the shell
// still has outstanding.
test "commit_ok leaves an in-flight slot it is not the answer to" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'R' });
    try std.testing.expect(h.m.in_flight == .refresh);

    var echoed = [_]Task{t("a", .high, .todo, null, &.{})};
    try h.send(.{ .commit_ok = &echoed });

    try std.testing.expect(h.m.in_flight == .refresh);
    try std.testing.expectEqual(Priority.high, h.m.tasks[0].content.priority);
}

test "space cycles every one of the four statuses" {
    const a = std.testing.allocator;
    const cases = [_]struct { from: Status, to: Status }{
        .{ .from = .todo, .to = .done },
        .{ .from = .in_progress, .to = .done },
        .{ .from = .done, .to = .todo },
        .{ .from = .cancelled, .to = .todo },
    };
    for (cases) |c| {
        var tasks = [_]Task{t("a", .medium, c.from, null, &.{})};
        var h: TestHarness = undefined;
        try h.setup(a, &tasks);
        defer h.deinit();
        try h.key(.{ .char = ' ' });
        try std.testing.expect(h.last == .commit);
        try std.testing.expectEqual(c.to, h.last.commit.content.status);
    }
}

test "x opens a confirm reporting how many children get promoted; n cancels" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{ "k1", "k2" }),
        t("k1", .none, .todo, null, &.{}),
        t("k2", .none, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'x' });
    try std.testing.expect(h.m.mode == .confirm_delete);
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "2 subtasks") != null);
    try h.key(.{ .char = 'n' });
    try std.testing.expect(h.last == .none);
    try std.testing.expect(h.m.mode == .list);
}

test "the promote count is recomputed at confirm time, not at prompt time" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{"k1"}),
        t("k1", .none, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'x' });

    // A refresh lands while the prompt is open. The cursor's task still exists,
    // so .confirm_delete survives.
    var refreshed = [_]Task{
        t("root", .none, .todo, null, &.{ "k1", "k2" }),
        t("k1", .none, .todo, null, &.{}),
        t("k2", .none, .todo, null, &.{}),
    };
    try h.send(.{ .tasks_loaded = &refreshed });
    try std.testing.expect(h.m.mode == .confirm_delete);

    try h.key(.{ .char = 'y' });
    try std.testing.expect(h.last == .delete);
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "2 subtasks") != null);
}

test "delete_ok forces a full refetch" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .none, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'x' });
    try h.key(.{ .char = 'y' });
    try h.send(.delete_ok);
    try std.testing.expect(h.last == .fetch);
}

test "a adds a root task with default fields and lands focus on priority" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("existing", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'a' });
    for ("new thing") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expect(h.last == .create);
    try std.testing.expectEqualStrings("new thing", h.last.create.title);
    try std.testing.expectEqual(Status.todo, h.last.create.status);
    try std.testing.expectEqual(Priority.none, h.last.create.priority);
    try std.testing.expectEqual(@as(usize, 0), h.last.create.child_ids.len);
    try std.testing.expectEqual(@as(usize, 0), h.last.create.tags.len);

    const created = t("newid", .none, .todo, null, &.{});
    try h.send(.{ .create_ok = created });
    try std.testing.expectEqualStrings("newid", h.m.cursor_id.?);
    try std.testing.expect(h.m.pane_open);
    try std.testing.expectEqual(FieldId.priority, h.m.mode.field);
}

test "a with an empty title is refused and keeps the prompt open" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("x", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'a' });
    try h.key(.enter);
    try std.testing.expect(h.last == .none);
    try std.testing.expect(h.m.mode == .add);
}

test "add failure keeps the typed title" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("x", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'a' });
    for ("keepme") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try h.send(.{ .request_failed = "boom" });
    try std.testing.expect(h.m.mode == .add);
    try std.testing.expectEqualStrings("keepme", h.m.mode.add.text());
}

test "/ applies a filter, records the expression, and rejects a bad one in place" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("hit", .none, .todo, null, &.{}),
        t("miss", .none, .todo, null, &.{}),
    };
    tasks[0].content.tags = @constCast(&[_][]const u8{"ops"});
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.{ .char = '/' });
    for ("bogus") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expect(h.m.mode == .filter);
    try std.testing.expect(h.m.status().len > 0);

    for (0..5) |_| try h.key(.backspace);
    for ("tag:ops") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(h.m.filtering);
    try std.testing.expectEqualStrings("tag:ops", h.m.filter_expr);
    try std.testing.expectEqual(@as(usize, 1), h.m.rows.len);
    try std.testing.expectEqualStrings("hit", h.m.rows[0].id);
}

test "escape clears an active filter from list mode" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("hit", .none, .todo, null, &.{}),
        t("miss", .none, .todo, null, &.{}),
    };
    tasks[0].content.tags = @constCast(&[_][]const u8{"ops"});
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = '/' });
    for ("tag:ops") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try h.key(.escape);
    try std.testing.expect(!h.m.filtering);
    try std.testing.expectEqual(@as(usize, 2), h.m.rows.len);
}

test "escape leaves the filter and add prompts without applying them" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = '/' });
    for ("tag:ops") |c| try h.key(.{ .char = c });
    try h.key(.escape);
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(!h.m.filtering);

    try h.key(.{ .char = 'a' });
    for ("nope") |c| try h.key(.{ .char = c });
    try h.key(.escape);
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(h.last == .none);
}

test "a refresh that removes the selected task returns to list mode" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("gone", .high, .todo, null, &.{}),
        t("stays", .low, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try std.testing.expect(h.m.mode == .field);

    var after = [_]Task{t("stays", .low, .todo, null, &.{})};
    try h.send(.{ .tasks_loaded = &after });
    try std.testing.expectEqualStrings("stays", h.m.cursor_id.?);
    try std.testing.expect(h.m.mode == .list);
}

test "a refresh that keeps the selected task preserves the mode" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("stays", .high, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.enter);
    try h.key(.down); // .field = description

    var again = [_]Task{t("stays", .high, .todo, null, &.{})};
    try h.send(.{ .tasks_loaded = &again });
    try std.testing.expectEqual(FieldId.description, h.m.mode.field);
}

test "R emits fetch and is refused while a mutation is in flight" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'R' });
    try std.testing.expect(h.last == .fetch);

    try commitPriorityHigh(&h);
    try h.key(.escape);
    try h.key(.{ .char = 'R' });
    try std.testing.expect(h.last == .none);
}

// Three tasks, shaped so a leading FILLER task's id length varies: `keep`'s and
// `kid`'s bytes therefore land at a different offset inside the task arena on
// every cycle. `buf` must outlive the returned array (it holds the filler id).
fn shiftingSet(buf: []u8, out: *[3]Task, cycle: usize) []Task {
    const n = (cycle * 2) % buf.len + 1; // 1..buf.len bytes, changing every cycle
    @memset(buf[0..n], 'f');
    out.* = .{
        t(buf[0..n], .none, .todo, null, &.{}),
        t("keep", .none, .todo, null, &.{"kid"}),
        t("kid", .high, .todo, null, &.{}),
    };
    return out;
}

// Step 5's lifetime test, STRENGTHENED. The plan's version reloads the same task
// set twenty times — and `replaceTasks` resets its arenas with `.retain_capacity`,
// so every id re-lands at the identical address and a dangling pointer reads back
// correct purely by luck. A 50-cycle version of that passed on this branch with a
// deliberately non-interned fold key planted in it. What makes it decisive is
// changing the task set's SHAPE between cycles, so the offsets actually move —
// and dereferencing every retained id each iteration, comparing BYTES rather than
// merely asserting non-null.
test "repeated refresh cycles leak nothing and keep interned ids valid" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("keep", .none, .todo, null, &.{"kid"}),
        t("kid", .high, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.{ .char = 'h' }); // an explicit fold, keyed by interned id
    try h.key(.enter); // a live Mode.field

    var filler: [40]u8 = undefined;
    var fresh: [3]Task = undefined;
    for (0..20) |i| {
        try h.send(.{ .tasks_loaded = shiftingSet(&filler, &fresh, i) });

        // Every stored id, DEREFERENCED and byte-compared.
        try std.testing.expectEqualStrings("keep", h.m.cursor_id.?);
        var it = h.m.folds.iterator();
        var folds_seen: usize = 0;
        while (it.next()) |kv| {
            try std.testing.expectEqualStrings("keep", kv.key_ptr.*);
            folds_seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), folds_seen);
        try std.testing.expect(h.m.folds.get("keep") != null);
        try std.testing.expectEqual(FieldId.title, h.m.mode.field);
    }
}

// The other half of the same hazard. `Mode.confirm_delete` carries an id of its
// own, and it is the one Mode a refresh deliberately PRESERVES — so it is held
// across arbitrarily many task-set swaps, which makes it the id most likely to
// dangle if it were ever stored straight off `m.tasks[i].id`. Same shape-changing
// cycle, dereferenced every iteration, then actually confirmed at the end.
test "an open delete prompt keeps its id valid across shape-changing refreshes" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("keep", .none, .todo, null, &.{"kid"}),
        t("kid", .high, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'x' });
    try std.testing.expect(h.m.mode == .confirm_delete);

    var filler: [40]u8 = undefined;
    var fresh: [3]Task = undefined;
    for (0..20) |i| {
        try h.send(.{ .tasks_loaded = shiftingSet(&filler, &fresh, i) });
        try std.testing.expect(h.m.mode == .confirm_delete);
        try std.testing.expectEqualStrings("keep", h.m.mode.confirm_delete.id);
        try std.testing.expectEqualStrings("keep", h.m.cursor_id.?);
    }

    try h.key(.{ .char = 'y' });
    try std.testing.expect(h.last == .delete);
    try std.testing.expectEqualStrings("keep", h.last.delete);
    try std.testing.expectEqualStrings("keep", h.m.in_flight.delete.id);
}

// `m.filters` points at tag/status slices built from a `filterspec.Parsed` whose
// tag strings were subslices of the filter prompt's EDITOR BUFFER — freed the
// instant the prompt closes — and it is re-read by every later `recompute`. Both
// hazards at once: the editor is long gone, and the task set is swapped
// (shape-changing) underneath a live filter twenty times.
test "an active filter survives the editor closing and repeated task-set swaps" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("keep", .none, .todo, null, &.{}),
        t("kid", .high, .todo, null, &.{}),
    };
    tasks[0].content.tags = @constCast(&[_][]const u8{"ops"});
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.{ .char = '/' });
    for ("tag:ops") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expect(h.m.mode == .list); // the editor buffer is freed here
    try std.testing.expectEqual(@as(usize, 1), h.m.rows.len);

    var filler: [40]u8 = undefined;
    var fresh: [3]Task = undefined;
    for (0..20) |i| {
        var set = shiftingSet(&filler, &fresh, i);
        set[1].content.tags = @constCast(&[_][]const u8{"ops"});
        try h.send(.{ .tasks_loaded = set });

        // Read the stored filter back byte-for-byte, and prove it is still the
        // one being APPLIED: of the three roots only "keep" carries the tag, and
        // it brings its one child along, so the filler must be gone.
        try std.testing.expectEqualStrings("tag:ops", h.m.filter_expr);
        try std.testing.expectEqual(@as(usize, 1), h.m.filters.tags.len);
        try std.testing.expectEqualStrings("ops", h.m.filters.tags[0]);
        try std.testing.expectEqual(@as(usize, 2), h.m.rows.len);
        try std.testing.expectEqualStrings("keep", h.m.rows[0].id);
        try std.testing.expectEqualStrings("kid", h.m.rows[1].id);
    }

    try h.key(.escape);
    try std.testing.expect(!h.m.filtering);
    try std.testing.expectEqual(@as(usize, 3), h.m.rows.len);
}

// A status filter exercises the OTHER slice on `m.filters` — `[]Status`, which is
// a plain value copy rather than a deep string copy, so it fails differently.
test "a status filter is applied and survives a task-set swap" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("open", .none, .todo, null, &.{}),
        t("shut", .none, .done, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = '/' });
    for ("status:done") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expectEqual(@as(usize, 1), h.m.filters.statuses.len);
    try std.testing.expectEqual(Status.done, h.m.filters.statuses[0]);
    try std.testing.expectEqual(@as(usize, 1), h.m.rows.len);
    try std.testing.expectEqualStrings("shut", h.m.rows[0].id);

    var again = [_]Task{
        t("open", .none, .todo, null, &.{}),
        t("shut", .none, .done, null, &.{}),
    };
    try h.send(.{ .tasks_loaded = &again });
    try std.testing.expectEqual(Status.done, h.m.filters.statuses[0]);
    try std.testing.expectEqual(@as(usize, 1), h.m.rows.len);
}

// `openEditor` used to be the ONLY thing that could put an `Editor` into `Mode`,
// so "exactly one live editor" rested on one guard in `fieldMode`. `a` and `/`
// now build editors too, and `in_flight.commit` may already own the one a failed
// commit has to hand back — a prompt installed alongside it would either leak or
// be clobbered by that restore. `x` is guarded for the plainer reason that a
// delete must not be started while another mutation is outstanding.
test "the add, filter and delete keys are all refused while a commit is in flight" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try commitPriorityHigh(&h);
    try h.key(.escape); // back to .list, commit still outstanding
    try std.testing.expect(h.m.in_flight == .commit);

    for ([_]u21{ 'a', '/', 'x', ' ' }) |c| {
        try h.key(.{ .char = c });
        try std.testing.expect(h.m.mode == .list); // no second editor, no prompt
        try std.testing.expect(h.last == .none);
        try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "still saving") != null);
    }
    // The editor the commit owns is still intact and still restorable.
    try h.send(.{ .request_failed = "connection reset" });
    try std.testing.expect(h.m.mode == .editing);
    try std.testing.expectEqual(@as(usize, 3), h.m.mode.editing.editor.pick.index);
}

// The status cycle commits with NO editor, so `request_failed` must not hand one
// back: reopening `.editing` on an empty `.external` drops the user into an
// editor whose only reply is "nothing to save yet". It has to land back in the
// list, with the slot empty and the next press still working.
test "a failed status cycle returns to the list rather than opening an empty editor" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .todo, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = ' ' });
    try std.testing.expect(h.m.in_flight == .commit);

    try h.send(.{ .request_failed = "connection reset" });
    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "connection reset") != null);
    try std.testing.expectEqual(Status.todo, h.m.tasks[0].content.status); // never optimistic

    // A jammed slot would refuse this outright.
    try h.key(.{ .char = ' ' });
    try std.testing.expect(h.last == .commit);
}

// The same slot on the success path: `commit_ok` must empty it (and free nothing
// it does not own), and the mode must not have wandered off the list.
test "a status cycle that succeeds clears the slot and stays in list mode" {
    const a = std.testing.allocator;
    var tasks = [_]Task{t("a", .medium, .in_progress, null, &.{})};
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = ' ' });
    try std.testing.expect(h.m.mode == .list);

    var echoed = [_]Task{t("a", .medium, .done, null, &.{})};
    try h.send(.{ .commit_ok = &echoed });
    try std.testing.expect(h.m.in_flight == .none);
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expectEqual(Status.done, h.m.tasks[0].content.status);
}

// A background refresh must never throw away text the user is in the middle of
// typing — it belongs to the user, not to the task set. The `tasks_loaded` mode
// rule keys off the mode's ANCHOR task, and `.add`/`.filter` anchor to none, so
// a refresh cannot reach them however the cursor moves. (Nor may it free their
// editor while the model still points at it.)
test "a refresh does not close the add or filter prompt" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("gone", .high, .todo, null, &.{}),
        t("stays", .low, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();

    try h.key(.{ .char = 'a' });
    for ("half typed") |c| try h.key(.{ .char = c });
    // The refresh even removes the task the cursor was on.
    var after = [_]Task{t("stays", .low, .todo, null, &.{})};
    try h.send(.{ .tasks_loaded = &after });
    try std.testing.expect(h.m.mode == .add);
    try std.testing.expectEqualStrings("half typed", h.m.mode.add.text());
    try h.key(.{ .char = '!' }); // still owned and writable, not a freed copy
    try std.testing.expectEqualStrings("half typed!", h.m.mode.add.text());
    try h.key(.escape);

    try h.key(.{ .char = '/' });
    for ("tag:ops") |c| try h.key(.{ .char = c });
    var after2 = [_]Task{t("stays", .low, .todo, null, &.{})};
    try h.send(.{ .tasks_loaded = &after2 });
    try std.testing.expect(h.m.mode == .filter);
    try std.testing.expectEqualStrings("tag:ops", h.m.mode.filter.text());
}

// The count must reflect what can actually be promoted. A child id nothing
// resolves to is not a task, so nothing promotes it — and reporting it would tell
// the user two subtasks are about to move when only one exists.
test "the promote count ignores dangling child ids" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{ "real", "ghost" }),
        t("real", .none, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'x' });
    try std.testing.expect(std.mem.indexOf(u8, h.m.status(), "1 subtasks") != null);
}

// An emptied filter prompt is the plainest way to say "no filter" — routing it
// through `filterspec.parse` as a zero-expression list would leave `filtering`
// true with nothing to match on, and the header claiming a filter that is not
// there.
test "enter on an emptied filter prompt clears the filter" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("hit", .none, .todo, null, &.{}),
        t("miss", .none, .todo, null, &.{}),
    };
    tasks[0].content.tags = @constCast(&[_][]const u8{"ops"});
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = '/' });
    for ("tag:ops") |c| try h.key(.{ .char = c });
    try h.key(.enter);
    try std.testing.expect(h.m.filtering);

    try h.key(.{ .char = '/' });
    try h.key(.enter); // nothing typed
    try std.testing.expect(h.m.mode == .list);
    try std.testing.expect(!h.m.filtering);
    try std.testing.expectEqualStrings("", h.m.filter_expr);
    try std.testing.expectEqual(@as(usize, 2), h.m.rows.len);
}

// The confirm prompt must not act on any key but y/n/escape. Falling through to
// the list key map would make `x` re-prompt, `q` quit mid-confirmation, and — the
// dangerous one — `j`/`k` move the cursor away from the task the prompt names,
// so `y` would delete a task the user is no longer looking at.
test "the delete confirm swallows every key that is not y, n or escape" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("aaa", .high, .todo, null, &.{}),
        t("bbb", .low, .todo, null, &.{}),
    };
    var h: TestHarness = undefined;
    try h.setup(a, &tasks);
    defer h.deinit();
    try h.key(.{ .char = 'x' });
    for ([_]Key{ .{ .char = 'j' }, .{ .char = 'q' }, .{ .char = 'x' }, .down, .enter, .tab }) |k| {
        try h.key(k);
        try std.testing.expect(h.m.mode == .confirm_delete);
        try std.testing.expect(h.last == .none);
    }
    try std.testing.expectEqualStrings("aaa", h.m.cursor_id.?); // never moved
    try h.key(.{ .char = 'y' });
    try std.testing.expectEqualStrings("aaa", h.last.delete);
}
