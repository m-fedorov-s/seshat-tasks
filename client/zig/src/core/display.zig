const std = @import("std");
const task = @import("task.zig");
const Status = task.Status;
const Priority = task.Priority;

pub fn statusGlyph(s: Status) []const u8 {
    return switch (s) {
        .todo => "○",
        .in_progress => "◐",
        .done => "✓",
        .cancelled => "✗",
    };
}

pub fn priorityLabel(p: Priority) []const u8 {
    return @tagName(p);
}

// Truncate to at most `max_cols` Unicode codepoints, never splitting a codepoint.
// (Codepoint count, not grapheme width — wide chars may still misalign; documented v1 limit.)
pub fn truncate(s: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return s; // 0 = no width budget -> don't truncate (avoid blanking titles)
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

// Format a unix-seconds timestamp as YYYY-MM-DD in the local offset (minutes east
// of UTC), returning a slice of `buf`. Instants that fall before the epoch in local
// terms clamp to 1970-01-01.
pub fn formatDate(buf: []u8, unix_seconds: i64, offset_minutes: i32) []const u8 {
    const local = unix_seconds + @as(i64, offset_minutes) * 60;
    const secs: u64 = if (local < 0) 0 else @intCast(local);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    }) catch buf[0..0];
}

pub const DueWording = union(enum) {
    due: struct { text: []const u8, days: i64 },
    overdue: struct { text: []const u8, days: i64 },
};

// Wording only — no styling. `buf` must be at least 64 bytes.
pub fn dueWording(buf: []u8, due_at: i64, now: i64, completed: bool, offset_minutes: i32) DueWording {
    var date_buf: [16]u8 = undefined;
    const date_str = formatDate(&date_buf, due_at, offset_minutes);
    if (due_at < now and !completed) {
        const days = @divTrunc(now - due_at, 86400);
        const text = std.fmt.bufPrint(buf, "⚠ OVERDUE ({d}d, due {s})", .{ days, date_str }) catch buf[0..0];
        return .{ .overdue = .{ .text = text, .days = days } };
    }
    // Days until due (may be negative for a completed, past-due task).
    const days = @divTrunc(due_at - now, 86400);
    const text = std.fmt.bufPrint(buf, "due {s}", .{date_str}) catch buf[0..0];
    return .{ .due = .{ .text = text, .days = days } };
}

// "#<tail>" — the last `len` characters of `id`, lower-cased — with no styling.
// Callers wrap it in whatever their medium uses for "dim". `buf` must hold
// len + 1 bytes; a shorter buf truncates rather than erroring.
pub fn handleText(buf: []u8, id: []const u8, len: usize) []const u8 {
    if (buf.len == 0) return buf[0..0];
    buf[0] = '#';
    var n: usize = 1;
    for (id[id.len -| len ..]) |c| {
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

// A semantic style, independent of how it is emitted. formatter.zig maps this to
// SGR escape codes; the TUI maps it to a vaxis.Style. Adding a variant here is how
// the two renderers stay in agreement.
pub const Style = enum { normal, dim, overdue, prio_high, prio_medium, prio_low };

pub fn priorityStyle(p: Priority) Style {
    return switch (p) {
        .high => .prio_high,
        .medium => .prio_medium,
        .low => .prio_low,
        .none => .normal,
    };
}

// Whether a status counts as "finished" for dimming/sinking purposes.
pub fn isCompleted(s: Status) bool {
    return s == .done or s == .cancelled;
}

pub fn taskStyle(status: Status, priority: Priority) Style {
    if (isCompleted(status)) return .dim;
    return priorityStyle(priority);
}

// The style a due/overdue wording should render in. Split from `dueWording` itself
// so a caller can compute the wording once and derive both the text and the style
// from the same result.
pub fn dueStyle(w: DueWording) Style {
    return switch (w) {
        .overdue => .overdue,
        .due => .normal,
    };
}

test "statusGlyph covers every status" {
    try std.testing.expectEqualStrings("○", statusGlyph(.todo));
    try std.testing.expectEqualStrings("◐", statusGlyph(.in_progress));
    try std.testing.expectEqualStrings("✓", statusGlyph(.done));
    try std.testing.expectEqualStrings("✗", statusGlyph(.cancelled));
}

test "priorityLabel matches the tag names the CLI already prints" {
    try std.testing.expectEqualStrings("none", priorityLabel(.none));
    try std.testing.expectEqualStrings("low", priorityLabel(.low));
    try std.testing.expectEqualStrings("medium", priorityLabel(.medium));
    try std.testing.expectEqualStrings("high", priorityLabel(.high));
}

test "truncate is codepoint-safe and never splits a multi-byte character" {
    try std.testing.expectEqualStrings("abc", truncate("abc", 10));
    try std.testing.expectEqualStrings("ab", truncate("abcdef", 2));
    // 'é' is two bytes; truncating to 1 column must not emit half of it.
    const s = "é" ++ "x";
    const got = truncate(s, 1);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqualStrings("é", got);
    // "héllo" where é is 2 bytes; truncating to 3 codepoints yields exactly "hél".
    const s2 = "h\u{00e9}llo";
    try std.testing.expectEqualStrings("h\u{00e9}l", truncate(s2, 3));
    // fits-entirely returns the whole string
    try std.testing.expectEqualStrings(s2, truncate(s2, 99));
    // 0 = no budget -> full string (not blank)
    try std.testing.expectEqualStrings(s2, truncate(s2, 0));
}

test "formatDate renders in the local offset" {
    var buf: [16]u8 = undefined;
    const utc: i64 = 1785708000; // 2026-08-02T22:00:00Z
    try std.testing.expectEqualStrings("2026-08-02", formatDate(&buf, utc, 0));
    try std.testing.expectEqualStrings("2026-08-03", formatDate(&buf, utc, 180));
}

test "handleText returns an unstyled #tail, lower-cased" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#abcd", handleText(&buf, "01JROOTA0000000000000ABCD", 4));
}

test "handleText clamps a len longer than the id" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#ab", handleText(&buf, "ab", 8));
}

test "dueWording renders a future date plainly" {
    var buf: [64]u8 = undefined;
    const due: i64 = 1785708000;
    switch (dueWording(&buf, due, due - 86400, false, 0)) {
        .due => |d| try std.testing.expectEqualStrings("due 2026-08-02", d.text),
        .overdue => return error.TestUnexpectedResult,
    }
}

test "dueWording's due arm carries the days until due" {
    var buf: [64]u8 = undefined;
    const due: i64 = 1785708000;
    switch (dueWording(&buf, due, due - 2 * 86400, false, 0)) {
        .due => |d| try std.testing.expectEqual(@as(i64, 2), d.days),
        .overdue => return error.TestUnexpectedResult,
    }
}

test "dueWording renders an overdue date with a day count" {
    var buf: [64]u8 = undefined;
    const due: i64 = 1785708000;
    switch (dueWording(&buf, due, due + 3 * 86400, false, 0)) {
        .due => return error.TestUnexpectedResult,
        .overdue => |o| {
            try std.testing.expectEqual(@as(i64, 3), o.days);
            try std.testing.expectEqualStrings("⚠ OVERDUE (3d, due 2026-08-02)", o.text);
        },
    }
}

test "dueWording never reports a completed task as overdue" {
    var buf: [64]u8 = undefined;
    const due: i64 = 1785708000;
    switch (dueWording(&buf, due, due + 3 * 86400, true, 0)) {
        .due => |d| try std.testing.expectEqualStrings("due 2026-08-02", d.text),
        .overdue => return error.TestUnexpectedResult,
    }
}

test "dueWording renders the date in the local offset" {
    var buf: [64]u8 = undefined;
    const due: i64 = 1785708000;
    switch (dueWording(&buf, due, due - 86400, false, 180)) {
        .due => |d| try std.testing.expectEqualStrings("due 2026-08-03", d.text),
        .overdue => return error.TestUnexpectedResult,
    }
}

test "priorityStyle maps each priority" {
    try std.testing.expectEqual(Style.prio_high, priorityStyle(.high));
    try std.testing.expectEqual(Style.prio_medium, priorityStyle(.medium));
    try std.testing.expectEqual(Style.prio_low, priorityStyle(.low));
    try std.testing.expectEqual(Style.normal, priorityStyle(.none));
}

test "taskStyle dims a completed task regardless of priority" {
    try std.testing.expectEqual(Style.dim, taskStyle(.done, .high));
    try std.testing.expectEqual(Style.dim, taskStyle(.cancelled, .high));
    try std.testing.expectEqual(Style.prio_high, taskStyle(.todo, .high));
    try std.testing.expectEqual(Style.normal, taskStyle(.in_progress, .none));
}

test "isCompleted is true only for done/cancelled" {
    try std.testing.expect(isCompleted(.done));
    try std.testing.expect(isCompleted(.cancelled));
    try std.testing.expect(!isCompleted(.todo));
    try std.testing.expect(!isCompleted(.in_progress));
}

test "dueStyle maps overdue to .overdue and due to .normal" {
    var buf: [64]u8 = undefined;
    const due: i64 = 1785708000;
    try std.testing.expectEqual(Style.overdue, dueStyle(dueWording(&buf, due, due + 3 * 86400, false, 0)));
    try std.testing.expectEqual(Style.normal, dueStyle(dueWording(&buf, due, due - 86400, false, 0)));
}
