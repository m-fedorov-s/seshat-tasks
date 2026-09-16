const std = @import("std");

pub const OffsetError = error{BadOffset};

// "+HH:MM" / "-HH:MM" -> minutes east of UTC. Strict: exactly 6 chars, no
// abbreviations, no IANA names. Range is the real-world -14:00..+14:00.
pub fn parseUtcOffset(s: []const u8) OffsetError!i32 {
    if (s.len != 6 or s[3] != ':') return error.BadOffset;
    const sign: i32 = switch (s[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.BadOffset,
    };
    const hh = std.fmt.parseUnsigned(u8, s[1..3], 10) catch return error.BadOffset;
    const mm = std.fmt.parseUnsigned(u8, s[4..6], 10) catch return error.BadOffset;
    if (mm > 59) return error.BadOffset;
    const total = @as(i32, hh) * 60 + @as(i32, mm);
    if (total > 14 * 60) return error.BadOffset;
    return sign * total;
}

pub const Config = struct {
    url: []const u8,
    secret: []const u8,
    /// Wall-clock deadline for every HTTP request, in milliseconds. 0 disables it.
    timeout_ms: u32 = 10_000,
    cache_ttl_seconds: u64 = 300,
    cache_dir: []const u8 = "",
    width: u32 = 120,
    utc_offset: []const u8 = "+00:00",
    // Derived from utc_offset by load(). A value supplied directly in JSON is
    // always overwritten — utc_offset is the single source of truth.
    offset_minutes: i32 = 0,

    pub fn loadFromSlice(allocator: std.mem.Allocator, content: []const u8, home: []const u8) !std.json.Parsed(Config) {
        var result = try std.json.parseFromSlice(Config, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        errdefer result.deinit();

        // Before the cache_dir fixup: nothing outside the JSON arena is allocated yet,
        // so errdefer alone is a complete cleanup.
        result.value.offset_minutes = try parseUtcOffset(result.value.utc_offset);

        if (std.mem.eql(u8, result.value.cache_dir, "")) {
            result.value.cache_dir = try std.fs.path.join(result.arena.allocator(), &.{ home, ".cache", "seshat" });
        }
        return result;
    }

    pub fn load(io: std.Io, allocator: std.mem.Allocator, home: []const u8, path: []const u8) !std.json.Parsed(Config) {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var file_reader = file.reader(io, &.{});
        const content = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        return loadFromSlice(allocator, content, home);
    }
};

test "config defaults width to 120 and parses an override" {
    const a = std.testing.allocator;
    const default_json =
        \\{"url":"http://x","secret":"s"}
    ;
    const d = try std.json.parseFromSlice(Config, a, default_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 120), d.value.width);

    const override_json =
        \\{"url":"http://x","secret":"s","width":80}
    ;
    const o = try std.json.parseFromSlice(Config, a, override_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer o.deinit();
    try std.testing.expectEqual(@as(u32, 80), o.value.width);
}

test "parseUtcOffset accepts well-formed offsets" {
    try std.testing.expectEqual(@as(i32, 0), try parseUtcOffset("+00:00"));
    try std.testing.expectEqual(@as(i32, 180), try parseUtcOffset("+03:00"));
    try std.testing.expectEqual(@as(i32, -300), try parseUtcOffset("-05:00"));
    try std.testing.expectEqual(@as(i32, 330), try parseUtcOffset("+05:30"));
    try std.testing.expectEqual(@as(i32, -840), try parseUtcOffset("-14:00"));
}

test "parseUtcOffset rejects malformed offsets" {
    const bad = [_][]const u8{
        "Europe/Moscow", "03:00", "+3:00", "+03:0", "+03:60",
        "+15:00", "-15:00", "", "+aa:bb", "+03-00",
    };
    for (bad) |s| {
        try std.testing.expectError(error.BadOffset, parseUtcOffset(s));
    }
}

test "loadFromSlice derives offset_minutes and rejects a malformed offset" {
    const a = std.testing.allocator;

    var d = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\"}", "/home/u");
    defer d.deinit();
    try std.testing.expectEqualStrings("+00:00", d.value.utc_offset);
    try std.testing.expectEqual(@as(i32, 0), d.value.offset_minutes);

    var e = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\",\"utc_offset\":\"+03:00\"}", "/home/u");
    defer e.deinit();
    try std.testing.expectEqual(@as(i32, 180), e.value.offset_minutes);

    // The spec's headline invariant: malformed is a hard error, never a silent 0.
    try std.testing.expectError(
        error.BadOffset,
        Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\",\"utc_offset\":\"Europe/Moscow\"}", "/home/u"),
    );
}

test "loadFromSlice ignores an offset_minutes supplied directly in JSON" {
    const a = std.testing.allocator;
    var d = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\",\"utc_offset\":\"+03:00\",\"offset_minutes\":-999}", "/home/u");
    defer d.deinit();
    try std.testing.expectEqual(@as(i32, 180), d.value.offset_minutes);
}

test "config defaults timeout_ms to 10000 and parses an override" {
    const a = std.testing.allocator;
    var d = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\"}", "/home/u");
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 10_000), d.value.timeout_ms);

    var o = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\",\"timeout_ms\":1500}", "/home/u");
    defer o.deinit();
    try std.testing.expectEqual(@as(u32, 1500), o.value.timeout_ms);

    // 0 is a documented opt-out, not an error.
    var z = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\",\"timeout_ms\":0}", "/home/u");
    defer z.deinit();
    try std.testing.expectEqual(@as(u32, 0), z.value.timeout_ms);
}

// max_lines was deleted; an existing config.json that still carries it must keep loading.
test "config still loads when a stale max_lines key is present" {
    const a = std.testing.allocator;
    var d = try Config.loadFromSlice(a, "{\"url\":\"http://x\",\"secret\":\"s\",\"max_lines\":7}", "/home/u");
    defer d.deinit();
    try std.testing.expectEqualStrings("http://x", d.value.url);
    try std.testing.expectEqual(@as(u32, 10_000), d.value.timeout_ms);
}
