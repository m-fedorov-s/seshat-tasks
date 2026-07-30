const std = @import("std");
const taskmod = @import("core/task.zig");
const Task = taskmod.Task;
const view = @import("core/view.zig");
const Status = taskmod.Status;
const Priority = taskmod.Priority;
const display = @import("core/display.zig");

pub const ColorMode = enum { on, off, auto };

pub const Layout = enum { compact, detailed };

pub const RenderOptions = struct {
    color: ColorMode = .auto,
    show_tags: bool,
    show_dates: bool,
    show_description: bool,
    show_id: bool,
    show_children: bool,
    width: usize,
    layout: Layout,
    handle_len: usize,
    offset_minutes: i32 = 0,

    pub fn compact() RenderOptions {
        return .{
            .show_tags = false,
            .show_dates = false,
            .show_description = false,
            .show_id = false,
            .show_children = true,
            .width = 120,
            .layout = .compact,
            .handle_len = 4,
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
            .layout = .detailed,
            .handle_len = 4,
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

// Write a dim "#<tail>" handle: last `len` chars of id, lower-cased. Emits its own
// reset so the handle is dim regardless of the surrounding row color.
fn writeHandle(out: *std.Io.Writer, sgr: Sgr, id: []const u8, len: usize) !void {
    var hbuf: [64]u8 = undefined;
    try out.print("{s}{s}{s}{s}", .{ sgr.reset, sgr.faint, display.handleText(&hbuf, id, len), sgr.reset });
}

// Render the already-selected, already-ranked top-level list. `idx` is the full
// index over every fetched task, used to look up immediate children.
//
// Color contract: this is a pure renderer with no TTY detection. The caller must
// pre-resolve `opts.color` to `.on` or `.off`; `.auto` is treated as "not on"
// (no color). main.zig resolves `.auto` from isatty/NO_COLOR before calling here.
pub fn render(out: *std.Io.Writer, opts: RenderOptions, now: i64, toplevel: []const Task, idx: *const view.Index) !void {
    const sgr = Sgr.make(opts.color == .on);
    switch (opts.layout) {
        .compact => {
            for (toplevel) |t| {
                // Root line: <glyph> <title> #<tail>
                const root_col = sgr.priority(t.content.priority);
                try out.print("{s}{s} {s}", .{ root_col, display.statusGlyph(t.content.status), display.truncate(t.content.title, opts.width) });
                try out.writeAll(" ");
                try writeHandle(out, sgr, t.id, opts.handle_len);
                try out.writeAll("\n");

                if (opts.show_children) {
                    const children = t.content.child_ids;
                    const n = children.len;
                    for (children, 0..) |cid, i| {
                        const is_last = (i == n - 1);
                        const connector = if (is_last) "└─" else "├─";
                        if (idx.by_id.get(cid)) |child| {
                            const dim = isCompleted(child);
                            const child_col = if (dim) sgr.faint else sgr.priority(child.content.priority);
                            try out.print("  {s} {s}{s} {s}", .{ connector, child_col, display.statusGlyph(child.content.status), display.truncate(child.content.title, opts.width) });
                            try out.writeAll(" ");
                            try writeHandle(out, sgr, child.id, opts.handle_len);
                            try out.writeAll("\n");
                        } else {
                            // Dangling child id
                            var hbuf: [64]u8 = undefined;
                            try out.print("  {s} {s}[missing: {s}]{s}\n", .{
                                connector, sgr.faint, display.handleText(&hbuf, cid, opts.handle_len), sgr.reset,
                            });
                        }
                    }
                }
            }
        },
        .detailed => {
            for (toplevel) |t| {
                // Root header line: {open}{glyph}  {title} #handle\n
                const root_col = if (isCompleted(t)) sgr.faint else sgr.priority(t.content.priority);
                try out.print("{s}{s}  {s}", .{ root_col, display.statusGlyph(t.content.status), display.truncate(t.content.title, opts.width) });
                try out.writeAll(" ");
                try writeHandle(out, sgr, t.id, opts.handle_len);
                try out.writeAll("\n");

                // Root meta line (3-space indent)
                try writeMetaLine(out, sgr, "   ", t, now, opts.offset_minutes);

                // Root description (if any)
                if (opts.show_description and t.content.description.len > 0) {
                    try out.print("   {s}{s}{s}\n", .{ sgr.faint, display.truncate(t.content.description, opts.width), sgr.reset });
                }

                // Children
                if (opts.show_children) {
                    const children = t.content.child_ids;
                    const n = children.len;
                    for (children, 0..) |cid, i| {
                        const is_last = (i == n - 1);
                        const connector = if (is_last) "└─ " else "├─ ";

                        // Spacer line before every child (including last)
                        try out.writeAll("   │\n");

                        if (idx.by_id.get(cid)) |child| {
                            const dim = isCompleted(child);
                            const child_col = if (dim) sgr.faint else sgr.priority(child.content.priority);
                            try out.print("   {s}{s}{s}  {s}", .{ connector, child_col, display.statusGlyph(child.content.status), display.truncate(child.content.title, opts.width) });
                            try out.writeAll(" ");
                            try writeHandle(out, sgr, child.id, opts.handle_len);
                            try out.writeAll("\n");

                            // Child meta/description prefix:
                            //   non-last: "   │     " (3 spaces + │ + 5 spaces = 9 chars)
                            //   last:     "         " (9 spaces)
                            const child_prefix = if (!is_last) "   │     " else "         ";
                            try writeMetaLine(out, sgr, child_prefix, child, now, opts.offset_minutes);

                            // Child description
                            if (opts.show_description and child.content.description.len > 0) {
                                try out.print("{s}{s}{s}{s}\n", .{ child_prefix, sgr.faint, display.truncate(child.content.description, opts.width), sgr.reset });
                            }
                        } else {
                            // Dangling child id
                            var hbuf: [64]u8 = undefined;
                            try out.print("   {s}{s}[missing: {s}]{s}\n", .{
                                connector, sgr.faint, display.handleText(&hbuf, cid, opts.handle_len), sgr.reset,
                            });
                        }
                    }
                }

                // Trailing blank line after each top-level block
                try out.writeAll("\n");
            }
        },
    }
}

// Writes a full meta line ("<prefix><faint>part · part…<reset>\n") for `t`, or
// nothing at all if `t` has no meta parts. `prefix` is the indent/gutter string
// (e.g. "   " for a root, "   │     "/"         " for a child). Single source of
// truth for which parts exist — no separate emptiness predicate to keep in sync.
fn writeMetaLine(out: *std.Io.Writer, sgr: Sgr, prefix: []const u8, t: Task, now: i64, offset_minutes: i32) !void {
    var started = false;

    // Ensures the prefix + dim wrapper is emitted exactly once, before the first part,
    // and a " · " separator before every subsequent part.
    const beginPart = struct {
        fn f(o: *std.Io.Writer, s: Sgr, pfx: []const u8, st: *bool) !void {
            if (!st.*) {
                try o.writeAll(pfx);
                try o.writeAll(s.faint);
                st.* = true;
            } else {
                try o.writeAll(" · ");
            }
        }
    }.f;

    // 1. Priority word (omit if .none)
    if (t.content.priority != .none) {
        try beginPart(out, sgr, prefix, &started);
        try out.writeAll(display.priorityLabel(t.content.priority));
    }

    // 2. Due date
    if (t.content.due_at) |due| {
        try beginPart(out, sgr, prefix, &started);
        var word_buf: [64]u8 = undefined;
        switch (display.dueWording(&word_buf, due, now, isCompleted(t), offset_minutes)) {
            .overdue => |o| {
                try out.print("{s}{s}{s}", .{ sgr.overdue, o.text, sgr.reset });
                // After the overdue token, surrounding faint was interrupted; restore it.
                if (sgr.faint.len > 0) try out.writeAll(sgr.faint);
            },
            .due => |s| try out.writeAll(s),
        }
    }

    // 3. Scheduled date
    if (t.content.scheduled_at) |sched| {
        try beginPart(out, sgr, prefix, &started);
        var date_buf: [16]u8 = undefined;
        const date_str = display.formatDate(&date_buf, sched, offset_minutes);
        try out.print("sched {s}", .{date_str});
    }

    // 4. Tags
    if (t.content.tags.len > 0) {
        try beginPart(out, sgr, prefix, &started);
        for (t.content.tags, 0..) |tag, ti| {
            if (ti > 0) try out.writeAll(" ");
            try out.print("#{s}", .{tag});
        }
    }

    // 5. Subtasks count
    if (t.content.child_ids.len > 0) {
        try beginPart(out, sgr, prefix, &started);
        try out.print("{d} subtasks", .{t.content.child_ids.len});
    }

    if (started) {
        try out.writeAll(sgr.reset);
        try out.writeAll("\n");
    }
}


fn isCompleted(t: Task) bool {
    return t.content.status == .done or t.content.status == .cancelled;
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

pub fn renderJson(out: *std.Io.Writer, tasks: []const Task) !void {
    var w = std.json.Stringify{ .writer = out, .options = .{} };
    try w.write(tasks);
    try out.writeAll("\n");
}

test "truncateTitle never splits a UTF-8 codepoint" {
    // "héllo" where é is 2 bytes; truncating to 3 codepoints yields exactly "hél".
    const s = "h\u{00e9}llo";
    const out = display.truncate(s, 3);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqualStrings("h\u{00e9}l", out);
    // fits-entirely returns the whole string
    try std.testing.expectEqualStrings(s, display.truncate(s, 99));
    // 0 = no budget -> full string (not blank)
    try std.testing.expectEqualStrings(s, display.truncate(s, 0));
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

test "formatDate renders YYYY-MM-DD" {
    var buf: [16]u8 = undefined;
    // 2021-01-01T00:00:00Z = 1609459200
    try std.testing.expectEqualStrings("2021-01-01", display.formatDate(&buf, 1609459200, 0));
    // 1970-01-01
    try std.testing.expectEqualStrings("1970-01-01", display.formatDate(&buf, 0, 0));
}

test "formatDate renders in the configured local offset" {
    var buf: [16]u8 = undefined;
    // 2026-08-02 22:00:00 UTC is 2026-08-03 01:00 local at +03:00.
    const utc: i64 = 1785708000; // 2026-08-02T22:00:00Z
    try std.testing.expectEqualStrings("2026-08-02", display.formatDate(&buf, utc, 0));
    try std.testing.expectEqualStrings("2026-08-03", display.formatDate(&buf, utc, 180));
    // ...and 2026-08-02 17:00 local at -05:00, still the 2nd.
    try std.testing.expectEqualStrings("2026-08-02", display.formatDate(&buf, utc, -300));
}

test "formatDate clamps a pre-epoch local instant to 1970-01-01" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", display.formatDate(&buf, 0, -300));
}

test "render threads the offset all the way to the meta line" {
    // Without this, dropping either writeMetaLine call site still passes every
    // formatDate unit test.
    const a = std.testing.allocator;
    // Parent: 2026-08-02T22:00:00Z -> 2026-08-03 local at +03:00.
    const parent_due: i64 = 1785708000;
    // Child: 2026-07-30T22:00:00Z -> 2026-07-31 local at +03:00. A distinct date
    // from the parent's so the child assertion can't pass on the parent's output.
    const child_due: i64 = 1785448800;
    var tasks = [_]Task{
        .{
            .id = "01JTESTA0000000000000ABCD",
            .content = .{ .title = "x", .status = .todo, .due_at = parent_due },
            .meta = .{ .created_at = 1 },
        },
        .{
            .id = "01JTESTB0000000000000EFGH",
            .content = .{ .title = "child", .status = .todo, .due_at = child_due },
            .meta = .{ .created_at = 1 },
        },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"01JTESTB0000000000000EFGH"});
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var opts = RenderOptions.detailed();
    opts.color = .off;
    opts.offset_minutes = 180;
    const top = [_]Task{tasks[0]};
    try render(&w, opts, 1785708000 - 86400, &top, &idx);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "due 2026-08-03") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "due 2026-07-31") != null);
}

test "compact color: row color spans glyph+title; done child dimmed" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "01HZZ0000000000000000WORK1", .content = .{ .title = "Work", .status = .in_progress, .priority = .high }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000DONE1", .content = .{ .title = "Done item", .status = .done }, .meta = .{} },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{"01HZZ0000000000000000DONE1"});
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    var opts = RenderOptions.compact();
    opts.color = .on;
    opts.handle_len = 4;
    const top = [_]Task{tasks[0]};
    try render(&buf.writer, opts, 0, &top, &idx);
    const out = buf.written();
    // high-priority row: red opens immediately before glyph, title follows with NO reset between
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[31m◐ Work") != null);
    // done child: faint opens before its glyph+title
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2m✓ Done item") != null);
}

test "compact: oneline, trailing #handle, mixed tree connectors" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "01HZZ0000000000000000WORK1", .content = .{ .title = "Work", .status = .in_progress, .priority = .high }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000RPT01", .content = .{ .title = "Write report", .status = .todo }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000DONE1", .content = .{ .title = "Done item", .status = .done }, .meta = .{} },
    };
    // two real children + one dangling id (GHOST, not in the set) as the last child
    tasks[0].content.child_ids = @constCast(&[_][]const u8{ "01HZZ0000000000000000RPT01", "01HZZ0000000000000000DONE1", "01HZZ0000000000000000GHOST" });
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    var opts = RenderOptions.compact();
    opts.color = .off;
    opts.handle_len = 4;
    const top = [_]Task{tasks[0]};
    try render(&buf.writer, opts, 0, &top, &idx);
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "◐ Work #ork1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "├─ ○ Write report #pt01") != null); // non-last child
    try std.testing.expect(std.mem.indexOf(u8, out, "├─ ✓ Done item #one1") != null);     // now non-last
    try std.testing.expect(std.mem.indexOf(u8, out, "└─ [missing: #host]") != null);       // dangling, last
}

test "detailed: git-log block, priority word, # tags, overdue, gutter rail" {
    const a = std.testing.allocator;
    const day: i64 = 86400;
    const now: i64 = 3 * day; // 1970-01-04
    var tasks = [_]Task{
        .{ .id = "01HZZ0000000000000000WORK1", .content = .{ .title = "Work", .status = .in_progress, .priority = .high }, .meta = .{} }, // no tags -> "high · 2 subtasks"
        .{ .id = "01HZZ0000000000000000RPT01", .content = .{ .title = "Write report", .status = .todo, .priority = .medium, .due_at = 10 * day, .scheduled_at = 2 * day, .tags = @constCast(&[_][]const u8{"work"}) }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000DONE1", .content = .{ .title = "Done item", .status = .done, .priority = .low }, .meta = .{} },
        .{ .id = "01HZZ0000000000000000TAX01", .content = .{ .title = "Tax", .status = .todo, .priority = .high, .due_at = 0, .tags = @constCast(&[_][]const u8{"urgent"}) }, .meta = .{} },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{ "01HZZ0000000000000000RPT01", "01HZZ0000000000000000DONE1" });
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    var opts = RenderOptions.detailed();
    opts.color = .off;
    opts.handle_len = 4;
    const top = [_]Task{ tasks[0], tasks[3] };
    try render(&buf.writer, opts, now, &top, &idx);
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "◐  Work #ork1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "high · 2 subtasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "medium · due 1970-01-11 · sched 1970-01-03 · #work") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "├─ ○  Write report #pt01") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "└─ ✓  Done item #one1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "low") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "high · ⚠ OVERDUE (3d, due 1970-01-01) · #urgent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null); // no-color: no escapes
}

test "detailed: exact block layout (rails, indentation, spacers)" {
    const a = std.testing.allocator;
    var tasks = [_]Task{
        .{ .id = "0000000000000000000000WRK1", .content = .{ .title = "Work", .status = .in_progress, .priority = .high }, .meta = .{} },
        .{ .id = "0000000000000000000000TSK1", .content = .{ .title = "Write A", .status = .todo, .priority = .medium, .tags = @constCast(&[_][]const u8{"work"}) }, .meta = .{} },
        .{ .id = "0000000000000000000000DNE1", .content = .{ .title = "Done B", .status = .done, .priority = .low }, .meta = .{} },
    };
    tasks[0].content.child_ids = @constCast(&[_][]const u8{ "0000000000000000000000TSK1", "0000000000000000000000DNE1" });
    var idx = try view.Index.build(a, &tasks);
    defer idx.deinit();
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    var opts = RenderOptions.detailed();
    opts.color = .off;
    opts.handle_len = 4;
    const top = [_]Task{tasks[0]};
    try render(&buf.writer, opts, 0, &top, &idx);
    try std.testing.expectEqualStrings(
        "◐  Work #wrk1\n" ++
        "   high · 2 subtasks\n" ++
        "   │\n" ++
        "   ├─ ○  Write A #tsk1\n" ++
        "   │     medium · #work\n" ++
        "   │\n" ++
        "   └─ ✓  Done B #dne1\n" ++
        "         low\n" ++
        "\n",
        buf.written(),
    );
}

