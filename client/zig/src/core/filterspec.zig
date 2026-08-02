const std = @import("std");
const taskmod = @import("task.zig");

pub const ParseError = error{ BadFilter, OutOfMemory };

pub const Parsed = struct {
    tags: [][]const u8,
    statuses: []taskmod.Status,
    overdue: bool,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.tags);
        allocator.free(self.statuses);
    }
};

/// Parses `--filter` expressions (`tag:NAME`, `status:S1,S2`, `overdue`) into their
/// parsed pieces. AND-combines repeated expressions. Never prints — every error path
/// returns `error.BadFilter`. Does NOT know about `--open` or `--flat`; the caller is
/// responsible for merging those in (see `main.zig`'s `runShow`).
pub fn parse(allocator: std.mem.Allocator, exprs: []const []const u8) ParseError!Parsed {
    var tag_list = std.ArrayList([]const u8).empty;
    errdefer tag_list.deinit(allocator);
    var status_list = std.ArrayList(taskmod.Status).empty;
    errdefer status_list.deinit(allocator);
    var overdue = false;

    for (exprs) |expr| {
        if (std.mem.startsWith(u8, expr, "tag:")) {
            const name = expr["tag:".len..];
            if (name.len == 0) return error.BadFilter;
            try tag_list.append(allocator, name);
        } else if (std.mem.startsWith(u8, expr, "status:")) {
            const list = expr["status:".len..];
            if (list.len == 0) return error.BadFilter;
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |s| {
                const st = std.meta.stringToEnum(taskmod.Status, s) orelse return error.BadFilter;
                try status_list.append(allocator, st);
            }
        } else if (std.mem.eql(u8, expr, "overdue")) {
            overdue = true;
        } else {
            return error.BadFilter;
        }
    }

    return .{
        .tags = try tag_list.toOwnedSlice(allocator),
        .statuses = try status_list.toOwnedSlice(allocator),
        .overdue = overdue,
    };
}

test "parse handles each filter form" {
    const a = std.testing.allocator;
    const f = try parse(a, &[_][]const u8{"tag:work"});
    defer f.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), f.tags.len);
    try std.testing.expectEqualStrings("work", f.tags[0]);

    const g = try parse(a, &[_][]const u8{"status:todo,in_progress"});
    defer g.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), g.statuses.len);
    try std.testing.expectEqual(taskmod.Status.todo, g.statuses[0]);
    try std.testing.expectEqual(taskmod.Status.in_progress, g.statuses[1]);

    const h = try parse(a, &[_][]const u8{"overdue"});
    defer h.deinit(a);
    try std.testing.expect(h.overdue);
}

test "parse AND-combines repeated expressions" {
    const a = std.testing.allocator;
    const f = try parse(a, &[_][]const u8{ "tag:work", "tag:urgent", "overdue" });
    defer f.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), f.tags.len);
    try std.testing.expect(f.overdue);
}

test "parse rejects malformed expressions without printing or leaking" {
    const a = std.testing.allocator;
    const bad = [_][]const u8{ "tag:", "status:", "status:nope", "nonsense", "tag" };
    for (bad) |s| {
        try std.testing.expectError(error.BadFilter, parse(a, &[_][]const u8{s}));
    }
    // A malformed expression AFTER a valid one must not leak the valid one.
    try std.testing.expectError(error.BadFilter, parse(a, &[_][]const u8{ "tag:work", "nonsense" }));
}
