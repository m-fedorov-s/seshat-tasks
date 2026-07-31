//! The TUI's pure state: types, memory ownership, and nothing else. No I/O, and
//! it never imports vaxis — the shell (task 18) owns the terminal, this owns the
//! bytes. `update` and key handling arrive in later tasks.
const std = @import("std");
const taskmod = @import("../core/task.zig");
const Task = taskmod.Task;
const Content = taskmod.Content;
const Priority = taskmod.Priority;
const Status = taskmod.Status;
const view = @import("../core/view.zig");
const ledger = @import("ledger.zig");
const editors = @import("editors.zig");

pub const Key = editors.Key;
pub const Viewport = struct { cols: u16 = 80, rows: u16 = 24 };

pub const FieldId = enum { title, description, status, priority, due, scheduled, tags };

pub const Editor = union(enum) {
    line: editors.LineEditor,
    pick: editors.PickEditor,
    external,

    pub fn deinit(self: *Editor, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .line => |*le| le.deinit(gpa),
            .pick, .external => {},
        }
        self.* = .external;
    }
};

pub const Mode = union(enum) {
    list,
    field: FieldId,
    editing: struct { field: FieldId, editor: Editor },
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
    // Interned ids: cursor, fold keys, and every id held in Mode/InFlight. Must
    // outlive task-set swaps, so it is a THIRD arena, never reset during a session.
    ids: *std.heap.ArenaAllocator,

    tasks: []Task = &.{},
    idx: view.Index = undefined,
    idx_built: bool = false,
    scores: ledger.Scores,
    rows: []ledger.Row = &.{},
    folds: ledger.Folds,

    cursor_id: ?[]const u8 = null,
    // The cursor's last known ROW INDEX. Never a source of truth for what is
    // selected — `cursor_id` is — only the anchor `recompute` falls back to when
    // the selected task has vanished, so the cursor drops to its old neighbour
    // instead of jumping to the top. It has to be a stored field because
    // `replaceTasks` retires `rows` (their ids point into the arena it is about
    // to reset), so by the time `recompute` runs there is no row list left to
    // derive the old position from. Written in exactly two places: snapshotted
    // at the end of `replaceTasks`'s teardown, and refreshed at the end of
    // `recompute`.
    cursor_anchor: usize = 0,
    filters: view.Filters = .{},
    filter_expr: []const u8 = "", // interned; drives the header and empty state
    filtering: bool = false,
    strategy: view.Strategy = .urgency,
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
        m.cursor_id = if (m.rows.len == 0)
            null
        else blk: {
            var i = @min(old_index, m.rows.len - 1);
            // Skip non-task rows (a header or a missing child cannot be selected).
            while (i > 0 and m.rows[i].kind != .task) i -= 1;
            if (m.rows[i].kind != .task) break :blk null;
            // Must be interned: `Row.id` borrows from the live task arena, which
            // the next replaceTasks resets.
            break :blk try m.internId(m.rows[i].id);
        };
    }

    m.cursor_anchor = m.cursorIndex() orelse 0;
    const layout = ledger.layoutFor(m.viewport.rows -| 3, m.pane_open); // 3 = header + 2 rules
    m.scroll_top = ledger.ensureVisible(m.cursor_anchor, m.rows.len, layout.ledger_rows, m.scroll_top);
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
