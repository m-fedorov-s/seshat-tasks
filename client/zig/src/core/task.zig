const std = @import("std");

pub const Status = enum {
    todo,
    in_progress,
    done,
    cancelled,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Status {
        const s = try std.json.innerParse([]const u8, allocator, source, options);
        return std.meta.stringToEnum(Status, s) orelse .todo;
    }
};

pub const Priority = enum {
    none,
    low,
    medium,
    high,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Priority {
        const s = try std.json.innerParse([]const u8, allocator, source, options);
        return std.meta.stringToEnum(Priority, s) orelse .none;
    }
};

pub const Content = struct {
    title: []const u8,
    description: []const u8 = "",
    status: Status = .todo,
    priority: Priority = .none,
    child_ids: [][]const u8 = &.{},
    tags: [][]const u8 = &.{},
    due_at: ?i64 = null,
    scheduled_at: ?i64 = null,
};

pub const Meta = struct {
    created_at: i64 = 0,
    updated_at: i64 = 0,
    completed_at: ?i64 = null,
    version: u64 = 0,
};

pub const Task = struct {
    id: []const u8,
    content: Content,
    meta: Meta,
};

test "task round trips through json" {
    const a = std.testing.allocator;
    const json =
        \\{"id":"01ABC","content":{"title":"t","description":"","status":"in_progress","priority":"high","child_ids":["x"],"tags":["a"],"due_at":5,"scheduled_at":null},"meta":{"created_at":1,"updated_at":2,"completed_at":null,"version":3}}
    ;
    const parsed = try std.json.parseFromSlice(Task, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    const t = parsed.value;
    try std.testing.expectEqualStrings("01ABC", t.id);
    try std.testing.expect(t.content.status == .in_progress);
    try std.testing.expect(t.content.priority == .high);
    try std.testing.expectEqual(@as(usize, 1), t.content.child_ids.len);
    try std.testing.expectEqual(@as(u64, 3), t.meta.version);
    try std.testing.expectEqual(@as(?i64, 5), t.content.due_at);
}

test "unknown enum falls back" {
    const a = std.testing.allocator;
    const json =
        \\{"id":"x","content":{"title":"t","status":"snoozed","priority":"critical","child_ids":[],"tags":[]},"meta":{"created_at":0,"updated_at":0,"version":1}}
    ;
    const parsed = try std.json.parseFromSlice(Task, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.content.status == .todo);
    try std.testing.expect(parsed.value.content.priority == .none);
}
