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

pub const Scores = std.StringHashMap(Score);

const DAY_SECS: i64 = 86400;

// The fold predicate. The 3-day threshold deliberately reuses dueFactor's bucket
// (view.zig:164) so the ledger's "soon" and the urgency score's "soon" cannot drift.
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
    var truncated = std.StringHashMap(void).init(allocator);
    defer truncated.deinit();
    for (tasks) |task_| _ = try walk(task_, idx, f, now, &scores, &on_path, &truncated);
    return scores;
}

fn walk(
    task_: Task,
    idx: *const view.Index,
    f: view.Filters,
    now: i64,
    scores: *Scores,
    on_path: *std.StringHashMap(void),
    truncated: *std.StringHashMap(void),
) !Score {
    if (scores.get(task_.id)) |memo| return memo;
    const self_m = view.matchesSelf(task_, f, now);
    if (on_path.contains(task_.id)) {
        // Cycle: contribute nothing, and remember that this result was truncated
        // so we do not memoise a wrong total for the ancestor that hit it.
        try truncated.put(task_.id, {});
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
    var saw_truncation = false;
    for (task_.content.child_ids) |cid| {
        const child = idx.by_id.get(cid) orelse continue;
        const cs = try walk(child, idx, f, now, scores, on_path, truncated);
        if (truncated.contains(child.id)) saw_truncation = true;
        if (cs.sub > s.sub) s.sub = cs.sub;
        s.attention += cs.attention + @intFromBool(needsAttention(child, now));
        s.descendants += cs.descendants + 1;
        if (!cs.all_complete) s.all_complete = false;
        if (cs.matches) s.matches = true;
    }
    // Only memoise a total computed from complete subtrees.
    if (!saw_truncation) try scores.put(task_.id, s);
    return s;
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

test "computeScores terminates on a cycle" {
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
}
