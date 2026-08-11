const std = @import("std");
const Task = @import("core/task.zig").Task;

const fixtures_dir = "../../schema/fixtures";

fn loadAndParse(a: std.mem.Allocator, io: std.Io, name: []const u8) !std.json.Parsed(Task) {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ fixtures_dir, name });
    defer a.free(path);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024));
    defer a.free(body);
    return std.json.parseFromSlice(Task, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "valid fixtures parse" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const names = [_][]const u8{ "minimal.json", "full.json", "forest.json", "optional-absent.json", "unicode.json" };
    for (names) |name| {
        const parsed = try loadAndParse(a, io, name);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.id.len > 0);
    }
}

test "unknown fields tolerated" {
    const a = std.testing.allocator;
    const parsed = try loadAndParse(a, std.testing.io, "unknown-fields.json");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("future", parsed.value.content.title);
}

test "unknown enum falls back" {
    const a = std.testing.allocator;
    const parsed = try loadAndParse(a, std.testing.io, "unknown-enum.json");
    defer parsed.deinit();
    try std.testing.expect(parsed.value.content.status == .todo);
    try std.testing.expect(parsed.value.content.priority == .none);
}
