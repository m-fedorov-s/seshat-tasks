const std = @import("std");
const taskmod = @import("../core/task.zig");
const Task = taskmod.Task;
const Priority = taskmod.Priority;
const Status = taskmod.Status;
const view = @import("../core/view.zig");

pub const Score = struct {
    own: i64, // view.urgency(t, now)
    sub: i64, // max(own, max over children of sub)
    attention: u32, // needsAttention descendants, EXCLUDING t itself
    descendants: u32, // total descendants, EXCLUDING t itself
    all_complete: bool, // t and every descendant are done/cancelled
    matches: bool, // t or some descendant passes the filters
    self_matches: bool, // t itself passes the filters
};

// Keys borrow the `id` slices out of the `tasks` passed to `computeScores` — `Scores`
// does not own them. A `Scores` map must not outlive (or be held across a swap of) the
// task slice it was built from.
pub const Scores = std.StringHashMap(Score);

const DAY_SECS: i64 = 86400;

// The fold predicate. The 3-day threshold deliberately reuses view.dueFactor's bucket
// boundary so the ledger's "soon" and the urgency score's "soon" cannot drift.
pub fn needsAttention(task_: Task, now: i64) bool {
    if (task_.content.status == .done or task_.content.status == .cancelled) return false;
    if (task_.content.priority == .high) return true;
    const due = task_.content.due_at orelse return false;
    return due - now <= 3 * DAY_SECS;
}

pub fn computeScores(
    allocator: std.mem.Allocator,
    tasks: []const Task,
    idx: *const view.Index,
    f: view.Filters,
    now: i64,
) !Scores {
    var scores = Scores.init(allocator);
    errdefer scores.deinit();
    var on_path = std.StringHashMap(void).init(allocator);
    defer on_path.deinit();
    for (tasks) |task_| _ = try walk(task_, idx, f, now, &scores, &on_path);
    return scores;
}

fn walk(
    task_: Task,
    idx: *const view.Index,
    f: view.Filters,
    now: i64,
    scores: *Scores,
    on_path: *std.StringHashMap(void),
) !Score {
    if (scores.get(task_.id)) |memo| return memo;
    const self_m = view.matchesSelf(task_, f, now);
    if (on_path.contains(task_.id)) {
        // Back-edge: task_ is already an ancestor on the current walk. Contribute
        // nothing and stop recursing — `on_path` alone is what guarantees
        // termination. This makes every score inside a cycle approximate (an
        // undercount of `sub`/`attention`/`descendants`, since the closing edge's
        // contribution is dropped), not exact. That is accepted: the server
        // rejects cycles on every mutation and on data-file load (see
        // server/validate.go), so cyclic data cannot arise from a well-behaved
        // server. This branch exists only so malformed data degrades gracefully
        // (terminates with approximate numbers) instead of recursing forever.
        return .{
            .own = 0,
            .sub = 0,
            .attention = 0,
            .descendants = 0,
            .all_complete = true,
            .matches = false,
            .self_matches = self_m,
        };
    }
    try on_path.put(task_.id, {});
    defer _ = on_path.remove(task_.id);

    const own = view.urgency(task_, now);
    const self_complete = task_.content.status == .done or task_.content.status == .cancelled;
    var s = Score{
        .own = own,
        .sub = own,
        .attention = 0,
        .descendants = 0,
        .all_complete = self_complete,
        .matches = self_m,
        .self_matches = self_m,
    };
    for (task_.content.child_ids) |cid| {
        const child = idx.by_id.get(cid) orelse continue;
        const cs = try walk(child, idx, f, now, scores, on_path);
        if (cs.sub > s.sub) s.sub = cs.sub;
        s.attention += cs.attention + @intFromBool(needsAttention(child, now));
        s.descendants += cs.descendants + 1;
        if (!cs.all_complete) s.all_complete = false;
        if (cs.matches) s.matches = true;
    }
    try scores.put(task_.id, s);
    return s;
}

pub const RowKind = enum { task, missing, unreachable_header };
pub const Row = struct {
    id: []const u8, // for .missing this is the dangling child id
    kind: RowKind = .task,
    depth: u16,
    last_sibling: bool,
    descendants: u32,
    attention: u32,
    expanded: bool,
    dimmed: bool,
};

pub const Folds = std.StringHashMap(bool); // explicit user state; absent => auto

pub fn isExpanded(id: []const u8, s: Score, folds: *const Folds) bool {
    if (folds.get(id)) |explicit| return explicit;
    return s.attention > 0;
}

// Marks `task_` and everything structurally reachable from it (following
// child_ids, cycle-guarded by the `reachable` set itself as memoisation) —
// deliberately blind to fold state. This is NOT the same thing as the set of
// rows `emit` actually renders: `emit` stops descending once it hits a
// collapsed node, so a collapsed node's children would look "unreachable" if
// the unreachable-safety-net pass below used emit's own bookkeeping. Folding
// a node must never make its children look structurally lost.
fn markReachable(task_: Task, idx: *const view.Index, reachable: *std.StringHashMap(void)) !void {
    if (reachable.contains(task_.id)) return;
    try reachable.put(task_.id, {});
    for (task_.content.child_ids) |cid| {
        if (idx.by_id.get(cid)) |child| try markReachable(child, idx, reachable);
    }
}

pub fn buildRows(
    allocator: std.mem.Allocator,
    roots: []const Task,
    all_tasks: []const Task,
    idx: *const view.Index,
    scores: *const Scores,
    folds: *const Folds,
    filtering: bool,
) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    errdefer out.deinit(allocator);

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();
    for (roots) |r| try markReachable(r, idx, &reachable);

    var path = std.StringHashMap(void).init(allocator);
    defer path.deinit();
    var rendered = std.StringHashMap(void).init(allocator);
    defer rendered.deinit();

    for (roots) |r| try emit(allocator, r, idx, scores, folds, filtering, 0, true, &out, &path, &rendered);

    // Spec §4.6: anything fetched but not reachable from a rendered root must be
    // surfaced, or a cycle would make tasks silently invisible. Skip anything
    // already structurally `reachable` (even if folding kept it off-screen) and
    // anything this pass has already emitted itself (e.g. a task reached while
    // walking a previously-encountered unreachable component).
    var unreachable_first = true;
    for (all_tasks) |task_| {
        if (reachable.contains(task_.id) or rendered.contains(task_.id)) continue;
        if (unreachable_first) {
            try out.append(allocator, .{
                .id = "", .kind = .unreachable_header, .depth = 0, .last_sibling = true,
                .descendants = 0, .attention = 0, .expanded = true, .dimmed = false,
            });
            unreachable_first = false;
        }
        try emit(allocator, task_, idx, scores, folds, filtering, 1, true, &out, &path, &rendered);
    }
    return out.toOwnedSlice(allocator);
}

fn emit(
    allocator: std.mem.Allocator,
    task_: Task,
    idx: *const view.Index,
    scores: *const Scores,
    folds: *const Folds,
    filtering: bool,
    depth: u16,
    last: bool,
    out: *std.ArrayList(Row),
    path: *std.StringHashMap(void),
    rendered: *std.StringHashMap(void),
) !void {
    if (path.contains(task_.id)) return; // cycle guard
    try path.put(task_.id, {});
    defer _ = path.remove(task_.id);
    try rendered.put(task_.id, {});

    const s = scores.get(task_.id) orelse Score{
        .own = 0, .sub = 0, .attention = 0, .descendants = 0,
        .all_complete = false, .matches = true, .self_matches = true,
    };
    const expanded = isExpanded(task_.id, s, folds);
    try out.append(allocator, .{
        .id = task_.id,
        .kind = .task,
        .depth = depth,
        .last_sibling = last,
        .descendants = s.descendants,
        .attention = s.attention,
        .expanded = expanded,
        .dimmed = filtering and !s.self_matches,
    });
    if (!expanded) return;

    const kids = task_.content.child_ids;
    for (kids, 0..) |cid, i| {
        const is_last = i == kids.len - 1;
        if (idx.by_id.get(cid)) |child| {
            try emit(allocator, child, idx, scores, folds, filtering, depth + 1, is_last, out, path, rendered);
        } else {
            try out.append(allocator, .{
                .id = cid, .kind = .missing, .depth = depth + 1, .last_sibling = is_last,
                .descendants = 0, .attention = 0, .expanded = false, .dimmed = false,
            });
        }
    }
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

test "needsAttention: overdue, due soon, or high priority" {
    try std.testing.expect(needsAttention(t("a", .none, .todo, NOW - DAY, &.{}), NOW)); // overdue
    try std.testing.expect(needsAttention(t("b", .none, .todo, NOW + 2 * DAY, &.{}), NOW)); // due soon
    try std.testing.expect(needsAttention(t("c", .high, .todo, null, &.{}), NOW)); // high
    try std.testing.expect(!needsAttention(t("d", .medium, .todo, NOW + 30 * DAY, &.{}), NOW));
    try std.testing.expect(!needsAttention(t("e", .high, .done, NOW - DAY, &.{}), NOW)); // completed
}

test "computeScores: sub is the subtree max; attention and descendants exclude the node" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{"kid"}),
        t("kid", .high, .todo, NOW - DAY, &.{}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var s = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer s.deinit();

    const root = s.get("root").?;
    const kid = s.get("kid").?;
    try std.testing.expectEqual(@as(i64, 0), root.own); // none/undated/fresh
    try std.testing.expectEqual(kid.own, root.sub);
    try std.testing.expectEqual(@as(u32, 1), root.attention);
    try std.testing.expectEqual(@as(u32, 1), root.descendants);
    try std.testing.expectEqual(@as(u32, 0), kid.attention);
    try std.testing.expectEqual(@as(u32, 0), kid.descendants);
}

test "computeScores: descendants counts the whole subtree, not immediate children" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{"mid"}),
        t("mid", .none, .todo, null, &.{"leaf"}),
        t("leaf", .none, .todo, null, &.{}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var s = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 2), s.get("root").?.descendants);
}

test "computeScores: all_complete is true only when the whole subtree is finished" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("p", .none, .done, null, &.{"live"}),
        t("live", .high, .todo, NOW - DAY, &.{}),
        t("q", .none, .done, null, &.{"alsodone"}),
        t("alsodone", .none, .cancelled, null, &.{}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var s = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer s.deinit();

    try std.testing.expect(!s.get("p").?.all_complete);
    try std.testing.expect(s.get("q").?.all_complete);
}

test "computeScores: matches includes descendants, self_matches does not" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{"kid"}),
        t("kid", .none, .todo, null, &.{}),
    };
    tasks[1].content.tags = @constCast(&[_][]const u8{"ops"});
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var s = try computeScores(a, &tasks, &idx, .{ .tags = &[_][]const u8{"ops"} }, NOW);
    defer s.deinit();

    try std.testing.expect(s.get("root").?.matches); // via descendant
    try std.testing.expect(!s.get("root").?.self_matches); // but not itself
    try std.testing.expect(s.get("kid").?.self_matches);
}

test "computeScores terminates on a 2-node cycle and memoises every member" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("x", .none, .todo, null, &.{"y"}),
        t("y", .none, .todo, null, &.{"x"}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var s = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer s.deinit();
    try std.testing.expect(s.get("x") != null);
    try std.testing.expect(s.get("y") != null);
}

test "computeScores terminates on a 3-node cycle and memoises every member" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("x", .none, .todo, null, &.{"y"}),
        t("y", .none, .todo, null, &.{"z"}),
        t("z", .none, .todo, null, &.{"x"}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var s = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer s.deinit();
    try std.testing.expect(s.get("x") != null);
    try std.testing.expect(s.get("y") != null);
    try std.testing.expect(s.get("z") != null);
}

fn scoreWith(attention: u32) Score {
    return .{ .own = 0, .sub = 0, .attention = attention, .descendants = 0,
              .all_complete = false, .matches = true, .self_matches = true };
}

test "isExpanded: auto-expands exactly when a descendant needs attention" {
    var folds = Folds.init(std.testing.allocator);
    defer folds.deinit();
    try std.testing.expect(isExpanded("a", scoreWith(1), &folds));
    try std.testing.expect(!isExpanded("b", scoreWith(0), &folds));
}

test "isExpanded: the tie case the first design got wrong" {
    // High + overdue parent with a high + overdue child: own == sub. The old
    // `sub > own` rule collapsed this and hid the most important row.
    var folds = Folds.init(std.testing.allocator);
    defer folds.deinit();
    const tie = Score{ .own = 15, .sub = 15, .attention = 1, .descendants = 1,
                       .all_complete = false, .matches = true, .self_matches = true };
    try std.testing.expect(isExpanded("p", tie, &folds));
}

test "isExpanded: does NOT over-expand on a merely-dated child" {
    // The old rule expanded any zero-urgency parent with any scoring child,
    // degenerating the tree into an indented flat list.
    var folds = Folds.init(std.testing.allocator);
    defer folds.deinit();
    const mild = Score{ .own = 0, .sub = 1, .attention = 0, .descendants = 1,
                        .all_complete = false, .matches = true, .self_matches = true };
    try std.testing.expect(!isExpanded("r", mild, &folds));
}

test "isExpanded: an explicit fold always wins over the auto rule" {
    var folds = Folds.init(std.testing.allocator);
    defer folds.deinit();
    try folds.put("a", false);
    try std.testing.expect(!isExpanded("a", scoreWith(2), &folds));
    try folds.put("b", true);
    try std.testing.expect(isExpanded("b", scoreWith(0), &folds));
}

test "buildRows: depth, last_sibling and the collapsed subtree" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{ "k1", "k2" }),
        t("k1", .none, .todo, null, &.{}),
        t("k2", .none, .todo, null, &.{}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var scores = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer scores.deinit();
    var folds = Folds.init(a);
    defer folds.deinit();

    const collapsed = try buildRows(a, tasks[0..1], &tasks, &idx, &scores, &folds, false);
    defer a.free(collapsed);
    try std.testing.expectEqual(@as(usize, 1), collapsed.len);
    try std.testing.expectEqual(@as(u32, 2), collapsed[0].descendants);
    try std.testing.expect(!collapsed[0].expanded);

    try folds.put("root", true);
    const rows = try buildRows(a, tasks[0..1], &tasks, &idx, &scores, &folds, false);
    defer a.free(rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(u16, 0), rows[0].depth);
    try std.testing.expectEqual(@as(u16, 1), rows[1].depth);
    try std.testing.expect(!rows[1].last_sibling);
    try std.testing.expect(rows[2].last_sibling);
}

test "buildRows: dims a row that did not itself match the filter" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("root", .none, .todo, null, &.{"kid"}),
        t("kid", .none, .todo, null, &.{}),
    };
    tasks[1].content.tags = @constCast(&[_][]const u8{"ops"});
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    const f = view.Filters{ .tags = &[_][]const u8{"ops"} };
    var scores = try computeScores(a, &tasks, &idx, f, NOW);
    defer scores.deinit();
    var folds = Folds.init(a);
    defer folds.deinit();
    try folds.put("root", true);

    const rows = try buildRows(a, tasks[0..1], &tasks, &idx, &scores, &folds, true);
    defer a.free(rows);
    try std.testing.expect(rows[0].dimmed);   // context only
    try std.testing.expect(!rows[1].dimmed);  // the actual hit
}

test "buildRows: a dangling child id becomes a .missing row" {
    const a = std.testing.allocator;
    var tasks = [_]Task{ t("root", .none, .todo, null, &.{"ghost"}) };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var scores = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer scores.deinit();
    var folds = Folds.init(a);
    defer folds.deinit();
    try folds.put("root", true);

    const rows = try buildRows(a, tasks[0..1], &tasks, &idx, &scores, &folds, false);
    defer a.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(RowKind.missing, rows[1].kind);
    try std.testing.expectEqualStrings("ghost", rows[1].id);
}

test "buildRows: tasks unreachable from any root are surfaced under a header" {
    const a = std.testing.allocator;
    // x<->y is a cycle: neither is a root, so neither appears in `roots`.
    var tasks = [_]Task{
        t("r", .none, .todo, null, &.{}),
        t("x", .none, .todo, null, &.{"y"}),
        t("y", .none, .todo, null, &.{"x"}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var scores = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer scores.deinit();
    var folds = Folds.init(a);
    defer folds.deinit();

    const rows = try buildRows(a, tasks[0..1], &tasks, &idx, &scores, &folds, false);
    defer a.free(rows);
    // r, then the header, then x and y in some order.
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqual(RowKind.unreachable_header, rows[1].kind);
    try std.testing.expectEqual(RowKind.task, rows[2].kind);
    try std.testing.expectEqual(RowKind.task, rows[3].kind);
}

test "buildRows terminates on a cycle reachable from a root" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        t("r", .none, .todo, null, &.{"x"}),
        t("x", .none, .todo, null, &.{"y"}),
        t("y", .none, .todo, null, &.{"x"}),
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var scores = try computeScores(a, &tasks, &idx, .{}, NOW);
    defer scores.deinit();
    var folds = Folds.init(a);
    defer folds.deinit();
    try folds.put("r", true);
    try folds.put("x", true);
    try folds.put("y", true);

    const rows = try buildRows(a, tasks[0..1], &tasks, &idx, &scores, &folds, false);
    defer a.free(rows);
    try std.testing.expect(rows.len < 100); // the assertion is that it returns
}
