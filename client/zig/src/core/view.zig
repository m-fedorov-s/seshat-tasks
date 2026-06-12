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
