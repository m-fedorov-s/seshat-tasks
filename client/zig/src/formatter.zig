const std = @import("std");
const taskmod = @import("core/task.zig");
const Task = taskmod.Task;
const view = @import("core/view.zig");
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
            .none => "", // no priority color
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
    return id[0..@min(7, id.len)];
}

// Render the already-selected, already-ranked top-level list. `idx` is the full
// index over every fetched task, used to look up immediate children.
pub fn render(out: *std.Io.Writer, opts: RenderOptions, now: i64, toplevel: []const Task, idx: *const view.Index) !void {
    const sgr = Sgr.make(opts.color == .on);
    for (toplevel) |t| {
        try renderRow(out, opts, sgr, now, t, 0, false);
        if (opts.show_children) {
            for (t.content.child_ids) |cid| {
                if (idx.by_id.get(cid)) |child| {
                    try renderRow(out, opts, sgr, now, child, 1, isCompleted(child));
                } else {
                    try out.print("  └─ {s}[missing: {s}]{s}\n", .{ sgr.faint, shortId(cid), sgr.reset });
                }
            }
        }
    }
}

fn isCompleted(t: Task) bool {
    return t.content.status == .done or t.content.status == .cancelled;
}

fn renderRow(out: *std.Io.Writer, opts: RenderOptions, sgr: Sgr, now: i64, t: Task, depth: usize, dim: bool) !void {
    if (depth > 0) try out.writeAll("  └─ ");

    const open = if (dim) sgr.faint else sgr.priority(t.content.priority);
    try out.print("{s}{s} ", .{ open, statusGlyph(t.content.status) });

    if (opts.show_id) try out.print("{s} ", .{shortId(t.id)});
    try out.writeAll(t.content.title);

    // (+n) marker for an immediate child that itself has children
    if (depth > 0 and t.content.child_ids.len > 0) {
        try out.print(" (+{d})", .{t.content.child_ids.len});
    }

    if (opts.show_dates) {
        if (t.content.due_at) |due| {
            const overdue = due < now and !isCompleted(t);
            const col = if (overdue) sgr.overdue else "";
            try out.print(" {s}due:{d}{s}", .{ col, due, if (overdue) sgr.reset else "" });
        }
    }
    if (opts.show_tags and t.content.tags.len > 0) {
        try out.writeAll(" [");
        for (t.content.tags, 0..) |tag, k| {
            if (k != 0) try out.writeAll(",");
            try out.writeAll(tag);
        }
        try out.writeAll("]");
    }
    if (opts.show_description and t.content.description.len > 0) {
        try out.print(" — {s}", .{t.content.description});
    }

    try out.print("{s}\n", .{sgr.reset});
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

test "render: forest with immediate children, dim done child, missing marker, (+n)" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "root0001", .content = .{ .title = "Root", .status = .todo }, .meta = .{} },
        .{ .id = "kidAAAAA", .content = .{ .title = "Kid A", .status = .todo }, .meta = .{} },
        .{ .id = "kidBBBBB", .content = .{ .title = "Kid B", .status = .done }, .meta = .{} },
        .{ .id = "gkid0001", .content = .{ .title = "Grandkid", .status = .todo }, .meta = .{} },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{ "kidAAAAA", "kidBBBBB", "ghost999" });
    tasks[1].content.child_ids = @constCast(&[_][]const u8{"gkid0001"}); // Kid A has 1 child -> (+1)

    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();

    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    var opts = RenderOptions.compact();
    opts.color = .off;

    const top = [_]Task{tasks[0]};
    try render(&buf.writer, opts, 0, &top, &idx);
    const out = buf.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "Root") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Kid A (+1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Kid B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[missing: ghost99]") != null);
    // Grandkid must NOT appear (immediate children only)
    try std.testing.expect(std.mem.indexOf(u8, out, "Grandkid") == null);
}
