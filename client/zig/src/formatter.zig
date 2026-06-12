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
//
// Immediate children only — grandchildren are NOT expanded (a child with its own
// children is annotated with `(+n)` instead). This caps output depth at 1.
//
// Color contract: this is a pure renderer with no TTY detection. The caller must
// pre-resolve `opts.color` to `.on` or `.off`; `.auto` is treated as "not on"
// (no color). main.zig resolves `.auto` from isatty/NO_COLOR before calling here.
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
    try out.writeAll(truncateTitle(t.content.title, opts.width));

    // (+n) marker for an immediate child that itself has children.
    // Raw child_ids count — may include dangling/missing ids (server is authoritative).
    if (depth > 0 and t.content.child_ids.len > 0) {
        try out.print(" (+{d})", .{t.content.child_ids.len});
    }

    // A non-overdue date inherits the row's current color; only overdue dates get
    // their own escape (sgr.overdue) and an explicit reset.
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

test "render: color-on emits SGR escapes" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "hi000001", .content = .{ .title = "Important", .status = .todo, .priority = .high }, .meta = .{} },
    };
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();

    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    var opts = RenderOptions.compact();
    opts.color = .on;

    try render(&buf.writer, opts, 0, &tasks, &idx);
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null); // an SGR escape is present
    try std.testing.expect(std.mem.indexOf(u8, out, "Important") != null);
}

// Truncate to at most `max_cols` Unicode codepoints, never splitting a codepoint.
// (Codepoint count, not grapheme width — wide chars may still misalign; documented v1 limit.)
pub fn truncateTitle(s: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (cols + 1 > max_cols) return s[0..i];
        i += len;
        cols += 1;
    }
    return s;
}

pub fn renderJson(out: *std.Io.Writer, tasks: []const Task) !void {
    var w = std.json.Stringify{ .writer = out, .options = .{} };
    try w.write(tasks);
    try out.writeAll("\n");
}

test "truncateTitle never splits a UTF-8 codepoint" {
    // "héllo" where é is 2 bytes; truncating to 3 display cols must not cut mid-codepoint.
    const s = "h\u{00e9}llo";
    const out = truncateTitle(s, 3);
    // valid UTF-8 prefix, length <= original
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(out.len <= s.len);
}

test "renderJson emits a Task array" {
    const a = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = "x", .content = .{ .title = "t" }, .meta = .{ .version = 1 } },
    };
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try renderJson(&buf.writer, &tasks);
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"x\"") != null);
    try std.testing.expect(out[0] == '[');
}
