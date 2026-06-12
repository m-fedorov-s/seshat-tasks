const std = @import("std");

pub const Config = struct {
    url: []const u8,
    secret: []const u8,
    max_lines: u32 = 3,
    cache_ttl_seconds: u64 = 300,
    cache_dir: []const u8 = "",
    width: u32 = 120,

    pub fn load(io: std.Io, allocator: std.mem.Allocator, home: []const u8, path: []const u8) !std.json.Parsed(Config) {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var file_reader = file.reader(io, &.{});
        const content = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        var result = try std.json.parseFromSlice(Config, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (std.mem.eql(u8, result.value.cache_dir, "")) {
            result.value.cache_dir = try std.fs.path.join(allocator, &.{ home, ".cache", "seshat" });
        }
        return result;
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
