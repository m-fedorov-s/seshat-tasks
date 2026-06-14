const std = @import("std");
const epoch = std.time.epoch;
const task = @import("task.zig");
const args = @import("args.zig");

pub const Status = task.Status;
pub const Priority = task.Priority;
pub const Content = task.Content;

const secs_per_day: i64 = 86400;

// One uniform per-field shape: "leave it" vs "set to this value".
pub fn Edit(comptime T: type) type {
    return union(enum) { unchanged, set: T };
}
// Nullable date fields: `.set = null` means "clear".
pub const DatePatch = Edit(?i64);
pub const DateKind = enum { due, scheduled };

pub const DateError = error{BadDate};

fn isUnchanged(comptime T: type, e: Edit(T)) bool {
    return switch (e) {
        .unchanged => true,
        .set => false,
    };
}

fn pick(comptime T: type, e: Edit(T), base: T) T {
    return switch (e) {
        .unchanged => base,
        .set => |v| v,
    };
}

const Ymd = struct { y: u16, m: u8, d: u8 };

// Days from 1970-01-01 (UTC) to y-m-d. Validates ranges. Proleptic Gregorian.
fn ymdToEpochDay(y: u16, m: u8, d: u8) DateError!i64 {
    if (y < epoch.epoch_year or m < 1 or m > 12) return error.BadDate;
    const month: epoch.Month = @enumFromInt(m);
    if (d < 1 or d > epoch.getDaysInMonth(y, month)) return error.BadDate;
    var days: i64 = 0;
    var yr: u16 = epoch.epoch_year;
    while (yr < y) : (yr += 1) days += epoch.getDaysInYear(yr);
    var mo: u8 = 1;
    while (mo < m) : (mo += 1) days += epoch.getDaysInMonth(y, @enumFromInt(mo));
    days += @as(i64, d) - 1;
    return days;
}

// Inverse: epoch-day (>= 0) -> calendar Y/M/D (UTC).
fn epochDayToYmd(day: i64) Ymd {
    std.debug.assert(day >= 0); // callers pass non-negative epoch days; @intCast to u47 would trap otherwise
    const ed = epoch.EpochDay{ .day = @intCast(day) };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{ .y = yd.year, .m = md.month.numeric(), .d = md.day_index + 1 };
}

fn timeOfDay(kind: DateKind) i64 {
    return switch (kind) {
        .due => 86399, // 23:59:59
        .scheduled => 0, // 00:00:00
    };
}

fn parseUint(comptime T: type, s: []const u8) DateError!T {
    // parseUnsigned (not parseInt) so a leading '+'/'-' is rejected, not silently stripped.
    return std.fmt.parseUnsigned(T, s, 10) catch error.BadDate;
}

fn mulChecked(a: i64, b: i64) DateError!i64 {
    return std.math.mul(i64, a, b) catch error.BadDate;
}
fn addChecked(a: i64, b: i64) DateError!i64 {
    return std.math.add(i64, a, b) catch error.BadDate;
}

// "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM" (UTC).
fn parseAbsolute(s: []const u8, kind: DateKind) DateError!DatePatch {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.BadDate;
    const y = try parseUint(u16, s[0..4]);
    const m = try parseUint(u8, s[5..7]);
    const d = try parseUint(u8, s[8..10]);
    const day = try ymdToEpochDay(y, m, d);
    var secs = day * secs_per_day;
    if (s.len == 10) {
        secs += timeOfDay(kind);
    } else {
        if (s.len != 16 or s[10] != 'T' or s[13] != ':') return error.BadDate;
        const hh = try parseUint(u8, s[11..13]);
        const mm = try parseUint(u8, s[14..16]);
        if (hh > 23 or mm > 59) return error.BadDate;
        secs += @as(i64, hh) * 3600 + @as(i64, mm) * 60;
    }
    return .{ .set = secs };
}

// "+Nd" / "+Nw" / "+Nm" relative to `now` (UTC), at this kind's time-of-day.
fn parseRelative(s: []const u8, now: i64, kind: DateKind) DateError!DatePatch {
    if (s.len < 2) return error.BadDate;
    const unit = s[s.len - 1];
    const n = std.fmt.parseInt(i64, s[0 .. s.len - 1], 10) catch return error.BadDate;
    if (n < 0) return error.BadDate;

    const today_day = @divFloor(now, secs_per_day);
    const base = today_day * secs_per_day + timeOfDay(kind);

    switch (unit) {
        'd' => return .{ .set = try addChecked(base, try mulChecked(n, secs_per_day)) },
        'w' => return .{ .set = try addChecked(base, try mulChecked(n, 7 * secs_per_day)) },
        'm' => {
            const ymd = epochDayToYmd(today_day);
            const total = @as(i64, ymd.m - 1) + n;
            const ny = @as(i64, ymd.y) + @divFloor(total, 12);
            const nm = @mod(total, 12) + 1;
            if (ny < epoch.epoch_year or ny > 9999) return error.BadDate;
            const ny16: u16 = @intCast(ny);
            const nm8: u8 = @intCast(nm);
            const dim = epoch.getDaysInMonth(ny16, @enumFromInt(nm8));
            const nd: u8 = if (ymd.d > dim) dim else ymd.d;
            const new_day = try ymdToEpochDay(ny16, nm8, nd);
            return .{ .set = new_day * secs_per_day + timeOfDay(kind) };
        },
        else => return error.BadDate,
    }
}

pub fn parseDate(input: []const u8, now: i64, kind: DateKind) DateError!DatePatch {
    if (std.mem.eql(u8, input, "none")) return .{ .set = null };
    if (input.len >= 1 and input[0] == '+') return parseRelative(input[1..], now, kind);
    return parseAbsolute(input, kind);
}

pub const Patch = struct {
    title: Edit([]const u8) = .unchanged,
    description: Edit([]const u8) = .unchanged,
    status: Edit(Status) = .unchanged,
    priority: Edit(Priority) = .unchanged,
    tags: Edit([][]const u8) = .unchanged, // .set with empty slice = cleared
    due: DatePatch = .unchanged, // .set = null = cleared
    scheduled: DatePatch = .unchanged,

    pub fn isEmpty(self: Patch) bool {
        return isUnchanged([]const u8, self.title) and
            isUnchanged([]const u8, self.description) and
            isUnchanged(Status, self.status) and
            isUnchanged(Priority, self.priority) and
            isUnchanged([][]const u8, self.tags) and
            isUnchanged(?i64, self.due) and
            isUnchanged(?i64, self.scheduled);
    }
};

pub fn applyPatch(base: Content, p: Patch) Content {
    return .{
        .title = pick([]const u8, p.title, base.title),
        .description = pick([]const u8, p.description, base.description),
        .status = pick(Status, p.status, base.status),
        .priority = pick(Priority, p.priority, base.priority),
        .child_ids = base.child_ids, // hierarchy is never patched here
        .tags = pick([][]const u8, p.tags, base.tags),
        .due_at = pick(?i64, p.due, base.due_at),
        .scheduled_at = pick(?i64, p.scheduled, base.scheduled_at),
    };
}

pub const ValidationError = error{EmptyTitle};
pub fn validate(c: Content) ValidationError!void {
    if (c.title.len == 0) return error.EmptyTitle;
}

test "ymdToEpochDay matches known epoch days" {
    try std.testing.expectEqual(@as(i64, 0), try ymdToEpochDay(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 31), try ymdToEpochDay(1970, 2, 1));
    // 2026-06-14: verified via `date -u -d 2026-06-14 +%s` / 86400 = 20618
    try std.testing.expectEqual(@as(i64, 20618), try ymdToEpochDay(2026, 6, 14));
    // leap day exists
    try std.testing.expectEqual(@as(i64, 19782), try ymdToEpochDay(2024, 2, 29));
    // invalid: Feb 29 on a non-leap year
    try std.testing.expectError(error.BadDate, ymdToEpochDay(2025, 2, 29));
    try std.testing.expectError(error.BadDate, ymdToEpochDay(2026, 13, 1));
    try std.testing.expectError(error.BadDate, ymdToEpochDay(2026, 0, 1));
    try std.testing.expectError(error.BadDate, ymdToEpochDay(1969, 1, 1));
}

test "epochDayToYmd round-trips ymdToEpochDay" {
    const cases = [_]Ymd{
        .{ .y = 1970, .m = 1, .d = 1 },
        .{ .y = 2026, .m = 6, .d = 14 },
        .{ .y = 2024, .m = 2, .d = 29 },
        .{ .y = 2099, .m = 12, .d = 31 },
    };
    for (cases) |c| {
        const day = try ymdToEpochDay(c.y, c.m, c.d);
        const back = epochDayToYmd(day);
        try std.testing.expectEqual(c.y, back.y);
        try std.testing.expectEqual(c.m, back.m);
        try std.testing.expectEqual(c.d, back.d);
    }
}

test "parseDate: none clears" {
    const r = try parseDate("none", 0, .due);
    try std.testing.expect(switch (r) {
        .set => |v| v == null,
        else => false,
    });
}

test "parseDate: date-only is end-of-day for due, start-of-day for scheduled" {
    // 2026-06-14 = epoch day 20618 -> 20618*86400 = 1781395200
    const start: i64 = 1781395200;
    const due = try parseDate("2026-06-14", 0, .due);
    const sched = try parseDate("2026-06-14", 0, .scheduled);
    try std.testing.expectEqual(@as(?i64, start + 86399), due.set);
    try std.testing.expectEqual(@as(?i64, start), sched.set);
}

test "parseDate: due-today is NOT before a mid-day now" {
    const start: i64 = 1781395200; // 2026-06-14 00:00 UTC
    const now: i64 = start + 12 * 3600; // noon
    const due = try parseDate("2026-06-14", now, .due);
    try std.testing.expect(due.set.? >= now); // would be overdue if midnight
}

test "parseDate: explicit time ignores kind" {
    const start: i64 = 1781395200;
    const a = try parseDate("2026-06-14T13:30", 0, .due);
    const b = try parseDate("2026-06-14T13:30", 0, .scheduled);
    try std.testing.expectEqual(@as(?i64, start + 13 * 3600 + 30 * 60), a.set);
    try std.testing.expectEqual(a.set, b.set);
}

test "parseDate: relative offsets from today" {
    const start: i64 = 1781395200; // 2026-06-14
    const now: i64 = start + 9 * 3600; // any time today
    try std.testing.expectEqual(@as(?i64, start + 86399), (try parseDate("+0d", now, .due)).set);
    try std.testing.expectEqual(@as(?i64, start + 86399 + 86400), (try parseDate("+1d", now, .due)).set);
    try std.testing.expectEqual(@as(?i64, start + 14 * 86400), (try parseDate("+2w", now, .scheduled)).set);
}

test "parseDate: +Nm clamps to month end" {
    // 2026-01-31 = epoch day 20484 -> *86400 = 1769817600
    const jan31: i64 = 1769817600;
    // +1m -> 2026-02-28 (2026 not leap) end-of-day
    const r = try parseDate("+1m", jan31, .due);
    // 2026-02-28 = epoch day 20512 -> *86400 = 1772236800, +86399
    try std.testing.expectEqual(@as(?i64, 1772236800 + 86399), r.set);
}

test "parseDate: rejects garbage" {
    try std.testing.expectError(error.BadDate, parseDate("", 0, .due));
    try std.testing.expectError(error.BadDate, parseDate("2026/06/14", 0, .due));
    try std.testing.expectError(error.BadDate, parseDate("2026-13-01", 0, .due));
    try std.testing.expectError(error.BadDate, parseDate("+1y", 0, .due));
    try std.testing.expectError(error.BadDate, parseDate("-1d", 0, .due));
    try std.testing.expectError(error.BadDate, parseDate("+d", 0, .due));
    // a signed numeric field is rejected, not silently normalized
    try std.testing.expectError(error.BadDate, parseDate("2026-+6-14", 0, .due));
}

test "applyPatch: unchanged keeps base, set overrides" {
    const base = Content{ .title = "old", .priority = .low };
    var p = Patch{};
    p.title = .{ .set = "new" };
    p.priority = .{ .set = .high };
    const out = applyPatch(base, p);
    try std.testing.expectEqualStrings("new", out.title);
    try std.testing.expect(out.priority == .high);
    try std.testing.expect(out.status == .todo); // untouched -> base default
}

test "applyPatch: dates clear vs set; tags wholesale incl clear" {
    var base = Content{ .title = "t", .due_at = 123, .scheduled_at = 5 };
    var keep = [_][]const u8{ "x", "y" };
    base.tags = &keep;
    var p = Patch{};
    p.due = .{ .set = null }; // clear
    p.scheduled = .{ .set = 999 }; // set
    var empty: [0][]const u8 = .{};
    p.tags = .{ .set = &empty }; // clear all tags
    const out = applyPatch(base, p);
    try std.testing.expectEqual(@as(?i64, null), out.due_at);
    try std.testing.expectEqual(@as(?i64, 999), out.scheduled_at);
    try std.testing.expectEqual(@as(usize, 0), out.tags.len);
}

test "applyPatch over default Content is the add path" {
    const out = applyPatch(.{ .title = "made" }, .{});
    try std.testing.expectEqualStrings("made", out.title);
    try std.testing.expect(out.status == .todo);
    try std.testing.expectEqual(@as(usize, 0), out.child_ids.len);
}

test "applyPatch preserves child_ids (never patched)" {
    var kids = [_][]const u8{"child1"};
    var base = Content{ .title = "p" };
    base.child_ids = &kids;
    const out = applyPatch(base, .{ .title = .{ .set = "renamed" } });
    try std.testing.expectEqual(@as(usize, 1), out.child_ids.len);
}

test "Patch.isEmpty" {
    try std.testing.expect((Patch{}).isEmpty());
    try std.testing.expect(!(Patch{ .due = .{ .set = null } }).isEmpty());
    try std.testing.expect(!(Patch{ .title = .{ .set = "x" } }).isEmpty());
}

test "validate rejects empty title" {
    try std.testing.expectError(error.EmptyTitle, validate(.{ .title = "" }));
    try validate(.{ .title = "ok" });
}
