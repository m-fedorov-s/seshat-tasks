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
