const std = @import("std");
const Task = @import("core/task.zig").Task;

// Renders the forest as indented lines. Roots = tasks not referenced by any
// task's child_ids. Each line: "<indent>[status] (priority) title".
pub fn render(allocator: std.mem.Allocator, out: *std.Io.Writer, tasks: []const Task) !void {
    var by_id = std.StringHashMap(Task).init(allocator);
    defer by_id.deinit();
    var referenced = std.StringHashMap(void).init(allocator);
    defer referenced.deinit();
    for (tasks) |t| {
        try by_id.put(t.id, t);
        for (t.content.child_ids) |c| try referenced.put(c, {});
    }
    for (tasks) |t| {
        if (referenced.contains(t.id)) continue;
        try renderTask(out, by_id, t, 0);
    }
}

fn renderTask(out: *std.Io.Writer, by_id: std.StringHashMap(Task), t: Task, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.writeAll("  ");
    try out.print("[{s}] ({s}) {s}\n", .{ @tagName(t.content.status), @tagName(t.content.priority), t.content.title });
    for (t.content.child_ids) |cid| {
        if (by_id.get(cid)) |child| try renderTask(out, by_id, child, depth + 1);
    }
}
