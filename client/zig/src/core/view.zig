const std = @import("std");
const taskmod = @import("task.zig");
const Task = taskmod.Task;
const Status = taskmod.Status;

pub const Strategy = enum { priority, due, title, created, urgency };

// Index over a task set: id -> Task, plus the set of ids referenced as some
// task's child. A "root" is a task whose id is NOT in `referenced`.
pub const Index = struct {
    by_id: std.StringHashMap(Task),
    referenced: std.StringHashMap(void),

    pub fn build(allocator: std.mem.Allocator, tasks: []const Task) !Index {
        // The errdefers matter for non-arena callers: tui/model.zig's replaceTasks
        // builds the Index from the long-lived gpa (a managed StringHashMap stores
        // its allocator, so an arena-backed one would die with the arena). Every
        // earlier caller passed an arena that swallowed a partial build; this one
        // would leak both maps on an OOM partway through.
        var by_id = std.StringHashMap(Task).init(allocator);
        errdefer by_id.deinit();
        var referenced = std.StringHashMap(void).init(allocator);
        errdefer referenced.deinit();
        for (tasks) |t| {
            try by_id.put(t.id, t);
            for (t.content.child_ids) |c| try referenced.put(c, {});
        }
        return .{ .by_id = by_id, .referenced = referenced };
    }

    pub fn deinit(self: *Index) void {
        self.by_id.deinit();
        self.referenced.deinit();
    }

    pub fn isRoot(self: *const Index, id: []const u8) bool {
        return !self.referenced.contains(id);
    }
};

test "index identifies roots" {
    const a = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "root", .content = .{ .title = "r", .child_ids = @constCast(&[_][]const u8{"kid"}) }, .meta = .{} },
        .{ .id = "kid", .content = .{ .title = "k" }, .meta = .{} },
    };
    var idx = try Index.build(a, &tasks);
    defer idx.deinit();
    try std.testing.expect(idx.isRoot("root"));
    try std.testing.expect(!idx.isRoot("kid"));
}

pub const Filters = struct {
    roots_only: bool = true,
    tags: []const []const u8 = &.{},
    statuses: []const Status = &.{},
    overdue: bool = false,
};

test "select applies AND-combined filters over the top level" {
    const a = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "a", .content = .{ .title = "a", .status = .todo, .tags = @constCast(&[_][]const u8{"work"}), .due_at = 50 }, .meta = .{ .created_at = 1 } },
        .{ .id = "b", .content = .{ .title = "b", .status = .done, .tags = @constCast(&[_][]const u8{"work"}) }, .meta = .{ .created_at = 2 } },
        .{ .id = "c", .content = .{ .title = "c", .status = .todo }, .meta = .{ .created_at = 3 } },
        .{ .id = "kid", .content = .{ .title = "k", .status = .todo, .tags = @constCast(&[_][]const u8{"work"}) }, .meta = .{ .created_at = 4 } },
    };
    // make "kid" a child of "a"
    var tasks_mut = tasks;
    tasks_mut[0].content.child_ids = @constCast(&[_][]const u8{"kid"});

    var idx = try Index.build(a, &tasks_mut);
    defer idx.deinit();

    // forest + tag:work + status todo  => only "a" (b is done, c lacks tag, kid is not a root)
    const now: i64 = 100;
    const sel = try select(a, &tasks_mut, &idx, .{
        .roots_only = true,
        .tags = &[_][]const u8{"work"},
        .statuses = &[_]Status{.todo},
    }, now);
    defer a.free(sel);
    try std.testing.expectEqual(@as(usize, 1), sel.len);
    try std.testing.expectEqualStrings("a", sel[0].id);

    // overdue: due_at 50 < now 100 and todo => "a" is overdue
    const od = try select(a, &tasks_mut, &idx, .{ .overdue = true }, now);
    defer a.free(od);
    try std.testing.expectEqual(@as(usize, 1), od.len);
    try std.testing.expectEqualStrings("a", od[0].id);
}

test "select surfaces a root whose descendant matches the tag filter" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "root", .content = .{ .title = "untagged root", .status = .todo }, .meta = .{ .created_at = 1 } },
        .{ .id = "kid", .content = .{ .title = "ops kid", .status = .todo, .tags = @constCast(&[_][]const u8{"ops"}) }, .meta = .{ .created_at = 2 } },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"kid"});

    var idx = try Index.build(a, &tasks);
    defer idx.deinit();

    const sel = try select(a, &tasks, &idx, .{ .roots_only = true, .tags = &[_][]const u8{"ops"} }, 100);
    defer a.free(sel);

    try std.testing.expectEqual(@as(usize, 1), sel.len);
    try std.testing.expectEqualStrings("root", sel[0].id);
}

test "select surfaces a root whose descendant is overdue" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "root", .content = .{ .title = "root", .status = .todo }, .meta = .{ .created_at = 1 } },
        .{ .id = "kid", .content = .{ .title = "kid", .status = .todo, .due_at = 50 }, .meta = .{ .created_at = 2 } },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"kid"});
    var idx = try Index.build(a, &tasks);
    defer idx.deinit();

    const sel = try select(a, &tasks, &idx, .{ .roots_only = true, .overdue = true }, 100);
    defer a.free(sel);
    try std.testing.expectEqual(@as(usize, 1), sel.len);
    try std.testing.expectEqualStrings("root", sel[0].id);
}

test "select still drops a root with no match anywhere in its subtree" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "root", .content = .{ .title = "root", .status = .todo }, .meta = .{ .created_at = 1 } },
        .{ .id = "kid", .content = .{ .title = "kid", .status = .todo }, .meta = .{ .created_at = 2 } },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"kid"});
    var idx = try Index.build(a, &tasks);
    defer idx.deinit();

    const sel = try select(a, &tasks, &idx, .{ .roots_only = true, .tags = &[_][]const u8{"ops"} }, 100);
    defer a.free(sel);
    try std.testing.expectEqual(@as(usize, 0), sel.len);
}

test "subtree matching terminates on a cycle below a real root" {
    const a = std.testing.allocator;
    // `r` IS a root; x<->y is a cycle inside its subtree. Without `r` the cycle
    // members are never roots, subtreeMatches is never called, and the test is vacuous.
    var tasks = [_]Task{
        .{ .id = "r", .content = .{ .title = "r", .status = .todo }, .meta = .{ .created_at = 1 } },
        .{ .id = "x", .content = .{ .title = "x", .status = .todo }, .meta = .{ .created_at = 2 } },
        .{ .id = "y", .content = .{ .title = "y", .status = .todo, .tags = @constCast(&[_][]const u8{"ops"}) }, .meta = .{ .created_at = 3 } },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"x"});
    tasks[1].content.child_ids = @constCast(&[_][]const u8{"y"});
    tasks[2].content.child_ids = @constCast(&[_][]const u8{"x"});
    var idx = try Index.build(a, &tasks);
    defer idx.deinit();

    const sel = try select(a, &tasks, &idx, .{ .roots_only = true, .tags = &[_][]const u8{"ops"} }, 100);
    defer a.free(sel);
    // Terminates AND finds the tagged node through the cycle.
    try std.testing.expectEqual(@as(usize, 1), sel.len);
    try std.testing.expectEqualStrings("r", sel[0].id);
}

test "subtree matching terminates on a cycle with no match anywhere" {
    // Unlike the cycle test above, nothing here matches the filter, so
    // subtreeMatches cannot short-circuit on a self-match — it is forced to
    // walk the full cycle (including the x<->y back-edge) and the cycle guard
    // is the only thing that stops it from recursing forever.
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "r", .content = .{ .title = "r", .status = .todo }, .meta = .{ .created_at = 1 } },
        .{ .id = "x", .content = .{ .title = "x", .status = .todo }, .meta = .{ .created_at = 2 } },
        .{ .id = "y", .content = .{ .title = "y", .status = .todo }, .meta = .{ .created_at = 3 } },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"x"});
    tasks[1].content.child_ids = @constCast(&[_][]const u8{"y"});
    tasks[2].content.child_ids = @constCast(&[_][]const u8{"x"});
    var idx = try Index.build(a, &tasks);
    defer idx.deinit();

    const sel = try select(a, &tasks, &idx, .{ .roots_only = true, .tags = &[_][]const u8{"ops"} }, 100);
    defer a.free(sel);
    // Terminates without a match anywhere in the cycle.
    try std.testing.expectEqual(@as(usize, 0), sel.len);
}

fn hasAllTags(t: Task, tags: []const []const u8) bool {
    for (tags) |want| {
        var found = false;
        for (t.content.tags) |have| {
            if (std.mem.eql(u8, want, have)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn statusInSet(s: Status, set: []const Status) bool {
    for (set) |x| if (x == s) return true;
    return false;
}

fn isOverdue(t: Task, now: i64) bool {
    const due = t.content.due_at orelse return false;
    if (t.content.status == .done or t.content.status == .cancelled) return false;
    return due < now;
}

// The per-task filter predicate. No roots_only handling — that is select's job.
pub fn matchesSelf(t: Task, f: Filters, now: i64) bool {
    if (f.tags.len != 0 and !hasAllTags(t, f.tags)) return false;
    if (f.statuses.len != 0 and !statusInSet(t.content.status, f.statuses)) return false;
    if (f.overdue and !isOverdue(t, now)) return false;
    return true;
}

fn subtreeMatches(
    t: Task,
    idx: *const Index,
    f: Filters,
    now: i64,
    seen: *std.StringHashMap(void),
) !bool {
    if (seen.contains(t.id)) return false; // cycle guard
    try seen.put(t.id, {});
    if (matchesSelf(t, f, now)) return true;
    for (t.content.child_ids) |cid| {
        const child = idx.by_id.get(cid) orelse continue;
        if (try subtreeMatches(child, idx, f, now, seen)) return true;
    }
    return false;
}

// Returns a newly-allocated slice of the tasks that pass all filters.
// Caller owns the slice (free with allocator.free); the Task values are shallow
// copies referencing the original (arena-backed) string data.
//
// When f.roots_only is set, a root is kept iff it or anything in its subtree
// matches (so a matching descendant is never silently erased). When false
// (the CLI's --flat path), the per-task predicate applies directly with no
// subtree walk.
pub fn select(allocator: std.mem.Allocator, tasks: []const Task, idx: *const Index, f: Filters, now: i64) ![]Task {
    var list: std.ArrayList(Task) = .empty;
    errdefer list.deinit(allocator);
    if (f.roots_only) {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (tasks) |t| {
            if (!idx.isRoot(t.id)) continue;
            seen.clearRetainingCapacity();
            if (try subtreeMatches(t, idx, f, now, &seen)) try list.append(allocator, t);
        }
    } else {
        for (tasks) |t| {
            if (matchesSelf(t, f, now)) try list.append(allocator, t);
        }
    }
    return list.toOwnedSlice(allocator);
}

test "urgency score: priority + due + age, completed sinks to zero" {
    const week: i64 = 7 * 24 * 3600;
    const now: i64 = 100 * week;

    // high priority, overdue, ~2 weeks old
    const a = Task{ .id = "a", .content = .{ .title = "a", .priority = .high, .due_at = now - 10 }, .meta = .{ .created_at = now - 2 * week } };
    // none priority, no due, fresh
    const b = Task{ .id = "b", .content = .{ .title = "b" }, .meta = .{ .created_at = now } };
    // high priority but done
    const c = Task{ .id = "c", .content = .{ .title = "c", .priority = .high, .status = .done, .due_at = now - 10 }, .meta = .{ .created_at = now - 2 * week } };

    try std.testing.expectEqual(@as(i64, 5 + 8 + 2), urgency(a, now)); // 5 prio + 8 overdue + 2 age
    try std.testing.expectEqual(@as(i64, 0), urgency(b, now));
    try std.testing.expectEqual(@as(i64, 0), urgency(c, now)); // done -> 0
}

const DAY: i64 = 24 * 3600;
const WEEK: i64 = 7 * DAY;

fn priorityWeight(p: taskmod.Priority) i64 {
    return switch (p) {
        .none => 0,
        .low => 1,
        .medium => 3,
        .high => 5,
    };
}

fn dueFactor(t: Task, now: i64) i64 {
    const due = t.content.due_at orelse return 0;
    const delta = due - now; // negative => overdue
    if (delta < 0) return 8;
    if (delta <= 1 * DAY) return 6;
    if (delta <= 3 * DAY) return 4;
    if (delta <= 7 * DAY) return 2;
    return 0;
}

fn ageFactor(t: Task, now: i64) i64 {
    const age = now - t.meta.created_at;
    if (age <= 0) return 0;
    const weeks = @divFloor(age, WEEK);
    return @min(weeks, 4);
}

pub fn urgency(t: Task, now: i64) i64 {
    if (t.content.status == .done or t.content.status == .cancelled) return 0;
    return priorityWeight(t.content.priority) + dueFactor(t, now) + ageFactor(t, now);
}

test "rank: priority strategy with completed sink and stable tiebreak" {
    const now: i64 = 1000;
    var tasks = [_]Task{
        .{ .id = "z", .content = .{ .title = "z", .priority = .low }, .meta = .{ .created_at = 1 } },
        .{ .id = "d", .content = .{ .title = "d", .priority = .high, .status = .done }, .meta = .{ .created_at = 2 } },
        .{ .id = "h1", .content = .{ .title = "h1", .priority = .high }, .meta = .{ .created_at = 5 } },
        .{ .id = "h2", .content = .{ .title = "h2", .priority = .high }, .meta = .{ .created_at = 3 } },
    };
    rank(&tasks, .priority, now);
    // high tasks first, tie broken by created_at asc (h2 before h1), then low, done sinks last
    try std.testing.expectEqualStrings("h2", tasks[0].id);
    try std.testing.expectEqualStrings("h1", tasks[1].id);
    try std.testing.expectEqualStrings("z", tasks[2].id);
    try std.testing.expectEqualStrings("d", tasks[3].id);
}

test "rank: title strategy is case-insensitive" {
    const now: i64 = 0;
    var tasks = [_]Task{
        .{ .id = "1", .content = .{ .title = "banana" }, .meta = .{} },
        .{ .id = "2", .content = .{ .title = "Apple" }, .meta = .{} },
    };
    rank(&tasks, .title, now);
    try std.testing.expectEqualStrings("Apple", tasks[0].content.title);
}

fn isCompleted(t: Task) bool {
    return t.content.status == .done or t.content.status == .cancelled;
}

const RankCtx = struct { strategy: Strategy, now: i64 };

// Returns null when a and b are equal on the strategy key.
fn strategyDiffers(ctx: RankCtx, a: Task, b: Task) ?bool {
    return switch (ctx.strategy) {
        .priority => blk: {
            const pa = priorityWeight(a.content.priority);
            const pb = priorityWeight(b.content.priority);
            if (pa != pb) break :blk pa > pb; // higher priority first
            break :blk null;
        },
        .urgency => blk: {
            const ua = urgency(a, ctx.now);
            const ub = urgency(b, ctx.now);
            if (ua != ub) break :blk ua > ub; // higher urgency first
            break :blk null;
        },
        .due => blk: {
            // undated sinks; otherwise soonest (smallest due_at) first
            const da = a.content.due_at;
            const db = b.content.due_at;
            if (da == null and db == null) break :blk null;
            if (da == null) break :blk false; // a undated -> after b
            if (db == null) break :blk true; // b undated -> a first
            if (da.? != db.?) break :blk da.? < db.?;
            break :blk null;
        },
        .title => blk: {
            const ord = std.ascii.orderIgnoreCase(a.content.title, b.content.title);
            if (ord != .eq) break :blk ord == .lt;
            break :blk null;
        },
        .created => blk: {
            // newest first (larger created_at sorts earlier)
            if (a.meta.created_at != b.meta.created_at) break :blk a.meta.created_at > b.meta.created_at;
            break :blk null;
        },
    };
}

// true if a should sort before b.
fn lessThan(ctx: RankCtx, a: Task, b: Task) bool {
    // 1. completed always sinks
    const ca = isCompleted(a);
    const cb = isCompleted(b);
    if (ca != cb) return !ca; // non-completed (false) comes first

    // 2. strategy key
    if (strategyDiffers(ctx, a, b)) |ord| return ord;

    // stable tiebreak: oldest first, then id ascending (ids are unique -> total order)
    if (a.meta.created_at != b.meta.created_at) return a.meta.created_at < b.meta.created_at;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

pub fn rank(tasks: []Task, strategy: Strategy, now: i64) void {
    // lessThan is a strict total order (the created_at,id tiebreak resolves all
    // ties), so stability is irrelevant; use the faster unstable sort.
    std.mem.sortUnstable(Task, tasks, RankCtx{ .strategy = strategy, .now = now }, lessThan);
}

const Ranked = struct { t: Task, score: i64, complete: bool };

fn rankedLessThan(ctx: RankCtx, a: Ranked, b: Ranked) bool {
    if (a.complete != b.complete) return !a.complete;
    switch (ctx.strategy) {
        .urgency => if (a.score != b.score) return a.score > b.score,
        else => if (strategyDiffers(ctx, a.t, b.t)) |ord| return ord,
    }
    if (a.t.meta.created_at != b.t.meta.created_at) return a.t.meta.created_at < b.t.meta.created_at;
    return std.mem.order(u8, a.t.id, b.t.id) == .lt;
}

// tasks.len == scores.len == all_complete.len. Sorts `tasks` in place.
pub fn rankByScore(
    allocator: std.mem.Allocator,
    tasks: []Task,
    scores: []const i64,
    all_complete: []const bool,
    strategy: Strategy,
    now: i64,
) !void {
    std.debug.assert(tasks.len == scores.len and tasks.len == all_complete.len);
    const pairs = try allocator.alloc(Ranked, tasks.len);
    defer allocator.free(pairs);
    for (tasks, scores, all_complete, 0..) |task_, s, c, i| pairs[i] = .{ .t = task_, .score = s, .complete = c };
    std.mem.sortUnstable(Ranked, pairs, RankCtx{ .strategy = strategy, .now = now }, rankedLessThan);
    for (pairs, 0..) |p, i| tasks[i] = p.t;
}

test "rank: due strategy sorts soonest first and sinks undated" {
    const now: i64 = 0;
    var tasks = [_]Task{
        .{ .id = "undated", .content = .{ .title = "u" }, .meta = .{ .created_at = 1 } },
        .{ .id = "late", .content = .{ .title = "l", .due_at = 500 }, .meta = .{ .created_at = 2 } },
        .{ .id = "soon", .content = .{ .title = "s", .due_at = 100 }, .meta = .{ .created_at = 3 } },
    };
    rank(&tasks, .due, now);
    try std.testing.expectEqualStrings("soon", tasks[0].id);
    try std.testing.expectEqualStrings("late", tasks[1].id);
    try std.testing.expectEqualStrings("undated", tasks[2].id);
}

test "rankByScore orders by the injected score, not the task's own urgency" {
    const a = std.testing.allocator;
    const now: i64 = 1000;
    var tasks = [_]Task{
        // created_at ordering is DELIBERATELY opposite the score ordering, so a
        // stub that ignores `scores` and falls through to the tiebreak fails.
        .{ .id = "a", .content = .{ .title = "a" }, .meta = .{ .created_at = 9 } },
        .{ .id = "b", .content = .{ .title = "b" }, .meta = .{ .created_at = 1 } },
    };
    const scores = [_]i64{ 20, 5 };
    const complete = [_]bool{ false, false };
    try rankByScore(a, &tasks, &scores, &complete, .urgency, now);
    try std.testing.expectEqualStrings("a", tasks[0].id);
}

test "rankByScore sinks on all_complete, not on the task's own status" {
    const a = std.testing.allocator;
    const now: i64 = 1000;
    var tasks = [_]Task{
        .{ .id = "donep", .content = .{ .title = "done parent", .status = .done }, .meta = .{ .created_at = 1 } },
        .{ .id = "live", .content = .{ .title = "live", .priority = .low }, .meta = .{ .created_at = 2 } },
    };
    // The done parent has a live overdue child, so its subtree is NOT complete.
    const scores = [_]i64{ 13, 1 };
    const complete = [_]bool{ false, false };
    try rankByScore(a, &tasks, &scores, &complete, .urgency, now);
    try std.testing.expectEqualStrings("donep", tasks[0].id);
}

test "rankByScore sinks a fully-complete subtree whose own status is live" {
    const a = std.testing.allocator;
    const now: i64 = 1000;
    var tasks = [_]Task{
        // NOT .done — so a stub using the existing own-status sink fails here.
        .{ .id = "allDone", .content = .{ .title = "all done", .priority = .high }, .meta = .{ .created_at = 1 } },
        .{ .id = "live", .content = .{ .title = "live", .priority = .low }, .meta = .{ .created_at = 2 } },
    };
    const scores = [_]i64{ 5, 1 };
    const complete = [_]bool{ true, false };
    try rankByScore(a, &tasks, &scores, &complete, .urgency, now);
    try std.testing.expectEqualStrings("live", tasks[0].id);
}

test "rank still behaves exactly as before" {
    const now: i64 = 1000;
    var tasks = [_]Task{
        .{ .id = "z", .content = .{ .title = "z", .priority = .low }, .meta = .{ .created_at = 1 } },
        .{ .id = "d", .content = .{ .title = "d", .priority = .high, .status = .done }, .meta = .{ .created_at = 2 } },
        .{ .id = "h1", .content = .{ .title = "h1", .priority = .high }, .meta = .{ .created_at = 5 } },
        .{ .id = "h2", .content = .{ .title = "h2", .priority = .high }, .meta = .{ .created_at = 3 } },
    };
    rank(&tasks, .priority, now);
    try std.testing.expectEqualStrings("h2", tasks[0].id);
    try std.testing.expectEqualStrings("h1", tasks[1].id);
    try std.testing.expectEqualStrings("z", tasks[2].id);
    try std.testing.expectEqualStrings("d", tasks[3].id);
}

pub const ResolveError = error{ NoSuchId, AmbiguousId };

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    const tail = haystack[haystack.len - suffix.len ..];
    for (tail, suffix) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// Resolve a task by a tail/suffix of its id (case-insensitive). A leading '#' is
// tolerated. A full id is its own suffix. Empty (or just '#') -> NoSuchId.
pub fn resolve(tasks: []const Task, query: []const u8) ResolveError!Task {
    var q = query;
    if (q.len > 0 and q[0] == '#') q = q[1..];
    if (q.len == 0) return error.NoSuchId;
    var match: ?Task = null;
    for (tasks) |t| {
        if (endsWithIgnoreCase(t.id, q)) {
            if (match != null) return error.AmbiguousId;
            match = t;
        }
    }
    return match orelse error.NoSuchId;
}

// Smallest suffix length in [4, 26] at which all ids have a distinct tail.
// PRECONDITION: callers pass uppercase ULIDs — raw-tail uniqueness then equals
// case-insensitive uniqueness (resolve lower-cases). Intentionally naive O(26*n).
pub fn minUniqueSuffixLen(allocator: std.mem.Allocator, ids: []const []const u8) !usize {
    if (ids.len <= 1) return 4;
    var len: usize = 4;
    while (len <= 26) : (len += 1) {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var collision = false;
        for (ids) |id| {
            const tail = id[id.len -| len ..];
            const gop = try seen.getOrPut(tail);
            if (gop.found_existing) {
                collision = true;
                break;
            }
        }
        if (!collision) return len;
    }
    return 26; // pathological: ids non-unique even at full length (duplicate ids)
}

test "resolve matches by id suffix, case-insensitive, # tolerated" {
    const tasks = [_]Task{
        .{ .id = "01HZZ0000000000000000RPT01", .content = .{ .title = "a" }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000DONE1", .content = .{ .title = "b" }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000WORK1", .content = .{ .title = "c" }, .meta = .{} },
    };
    try std.testing.expectEqualStrings("01HZZ0000000000000000RPT01", (try resolve(&tasks, "rpt01")).id);
    try std.testing.expectEqualStrings("01HZZ0000000000000000RPT01", (try resolve(&tasks, "#RPT01")).id); // # + case
    try std.testing.expectEqualStrings("01HZZ0000000000000000WORK1", (try resolve(&tasks, "k1")).id); // short unique tail
    try std.testing.expectEqualStrings("01HZZ0000000000000000DONE1", (try resolve(&tasks, "01HZZ0000000000000000DONE1")).id); // full id is its own suffix
    try std.testing.expectError(error.AmbiguousId, resolve(&tasks, "1")); // all three end in "1"
    try std.testing.expectError(error.NoSuchId, resolve(&tasks, "zzz"));
    try std.testing.expectError(error.NoSuchId, resolve(&tasks, ""));
    try std.testing.expectError(error.NoSuchId, resolve(&tasks, "#"));
}

test "minUniqueSuffixLen widens past collisions, floor 4" {
    const a = std.testing.allocator;
    const ids1 = [_][]const u8{ "AAAAWORK1", "AAAARPT01", "AAAADONE1" }; // distinct at 4
    try std.testing.expectEqual(@as(usize, 4), try minUniqueSuffixLen(a, &ids1));
    const ids2 = [_][]const u8{ "AAAX0001", "AAAY0001" }; // share last 4 "0001", differ at 5
    try std.testing.expectEqual(@as(usize, 5), try minUniqueSuffixLen(a, &ids2));
    const ids3 = [_][]const u8{"AAAAAAAA"}; // 0/1 ids -> floor 4
    try std.testing.expectEqual(@as(usize, 4), try minUniqueSuffixLen(a, &ids3));
}

test "minUniqueSuffixLen: duplicate ids fall back to 26" {
    const a = std.testing.allocator;
    const dup = [_][]const u8{ "01HZZ0000000000000000WORK1", "01HZZ0000000000000000WORK1" };
    try std.testing.expectEqual(@as(usize, 26), try minUniqueSuffixLen(a, &dup));
}
