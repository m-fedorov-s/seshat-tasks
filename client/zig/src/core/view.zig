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
        var by_id = std.StringHashMap(Task).init(allocator);
        var referenced = std.StringHashMap(void).init(allocator);
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

fn passes(t: Task, idx: *const Index, f: Filters, now: i64) bool {
    if (f.roots_only and !idx.isRoot(t.id)) return false;
    if (f.tags.len != 0 and !hasAllTags(t, f.tags)) return false;
    if (f.statuses.len != 0 and !statusInSet(t.content.status, f.statuses)) return false;
    if (f.overdue and !isOverdue(t, now)) return false;
    return true;
}

// Returns a newly-allocated slice of the tasks that pass all filters.
// Caller owns the slice (free with allocator.free); the Task values are shallow
// copies referencing the original (arena-backed) string data.
pub fn select(allocator: std.mem.Allocator, tasks: []const Task, idx: *const Index, f: Filters, now: i64) ![]Task {
    var list: std.ArrayList(Task) = .empty;
    errdefer list.deinit(allocator);
    for (tasks) |t| {
        if (passes(t, idx, f, now)) try list.append(allocator, t);
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
