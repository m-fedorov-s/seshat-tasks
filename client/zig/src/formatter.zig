const std = @import("std");
const Task = @import("core/task.zig").Task;
const taskmod = @import("core/task.zig");
const Status = taskmod.Status;
const Priority = taskmod.Priority;

pub const ColorMode = enum { on, off, auto };

pub const RenderOptions = struct {
    color: ColorMode = .auto,
    show_tags: bool,
    show_dates: bool,
    show_description: bool,
    show_id: bool,
    show_children: bool,
    width: usize,

    pub fn compact() RenderOptions {
        return .{
            .show_tags = false,
            .show_dates = false,
            .show_description = false,
            .show_id = false,
            .show_children = true,
            .width = 120,
        };
    }

    pub fn detailed() RenderOptions {
        return .{
            .show_tags = true,
            .show_dates = true,
            .show_description = true,
            .show_id = true,
            .show_children = true,
            .width = 120,
        };
    }
};

// SGR escapes (16-color). Empty strings when color is disabled.
const Sgr = struct {
    reset: []const u8,
    faint: []const u8,
    high: []const u8,
    medium: []const u8,
    low: []const u8,
    overdue: []const u8,

    fn make(enabled: bool) Sgr {
        if (!enabled) return .{ .reset = "", .faint = "", .high = "", .medium = "", .low = "", .overdue = "" };
        return .{
            .reset = "\x1b[0m",
            .faint = "\x1b[2m",
            .high = "\x1b[31m", // red
            .medium = "\x1b[33m", // yellow
            .low = "\x1b[34m", // blue
            .overdue = "\x1b[1;31m", // bold red
        };
    }

    fn priority(self: Sgr, p: Priority) []const u8 {
        return switch (p) {
            .high => self.high,
            .medium => self.medium,
            .low => self.low,
            .none => "",
        };
    }
};

fn statusGlyph(s: Status) []const u8 {
    return switch (s) {
        .todo => "○",
        .in_progress => "◐",
        .done => "✓",
        .cancelled => "✗",
    };
}

fn shortId(id: []const u8) []const u8 {
    return id[0..@min(@as(usize, 7), id.len)];
}

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

test "render options constructors differ as specified" {
    const c = RenderOptions.compact();
    try std.testing.expect(!c.show_id);
    try std.testing.expect(c.show_children);
    try std.testing.expect(!c.show_dates);

    const d = RenderOptions.detailed();
    try std.testing.expect(d.show_id);
    try std.testing.expect(d.show_dates);
    try std.testing.expect(d.show_tags);
}
