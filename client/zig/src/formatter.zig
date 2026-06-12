const std = @import("std");
const Task = @import("core/task.zig").Task;

pub fn formatTasksJson(allocator: std.mem.Allocator, tasks: []const Task, max_lines: u32) ![]const u8 {
    const limit = if (tasks.len > max_lines) max_lines else tasks.len;
    const display_tasks = tasks[0..limit];

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var stringifier = std.json.Stringify{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringifier.write(display_tasks);
    return aw.toOwnedSlice();
}

test "formatTasksJson" {
    const allocator = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = try allocator.dupe(u8, "1"), .title = try allocator.dupe(u8, "task1"), .priority = 1, .status = .todo },
        .{ .id = try allocator.dupe(u8, "2"), .title = try allocator.dupe(u8, "task2"), .priority = 2, .status = .done },
    };
    defer {
        for (tasks) |t| t.deinit(allocator);
    }

    const json = try formatTasksJson(allocator, &tasks, 1);
    defer allocator.free(json);

    // Verify it contains task1 but not task2 due to max_lines=1
    try std.testing.expect(std.mem.indexOf(u8, json, "task1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "task2") == null);
}
