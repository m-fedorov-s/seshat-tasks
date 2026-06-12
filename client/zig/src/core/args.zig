const std = @import("std");

pub const Kind = enum { boolean, value, multi };

pub const OptionSpec = struct {
    name: []const u8, // without leading "--"
    kind: Kind,
};

pub const ParseError = error{ UnknownFlag, MissingValue, OutOfMemory };

pub const ParsedArgs = struct {
    bools: std.StringHashMap(void),
    values: std.StringHashMap([]const u8),
    multis: std.StringHashMap(std.ArrayList([]const u8)),
    positionals: std.ArrayList([]const u8),

    pub fn getBool(self: *const ParsedArgs, name: []const u8) bool {
        return self.bools.contains(name);
    }
    pub fn getValue(self: *const ParsedArgs, name: []const u8) ?[]const u8 {
        return self.values.get(name);
    }
    pub fn getMulti(self: *const ParsedArgs, name: []const u8) []const []const u8 {
        if (self.multis.get(name)) |list| return list.items;
        return &.{};
    }
};

test "parser handles bools, values, =, repeatable, and unknown flags" {
    const a = std.testing.allocator;
    const specs = [_]OptionSpec{
        .{ .name = "flat", .kind = .boolean },
        .{ .name = "sort", .kind = .value },
        .{ .name = "filter", .kind = .multi },
    };
    const argv = [_][]const u8{ "--flat", "--sort", "urgency", "--filter=tag:work", "--filter", "overdue", "pos1" };
    var parsed = try parse(a, &argv, &specs);
    defer deinit(a, &parsed);

    try std.testing.expect(parsed.getBool("flat"));
    try std.testing.expectEqualStrings("urgency", parsed.getValue("sort").?);
    const f = parsed.getMulti("filter");
    try std.testing.expectEqual(@as(usize, 2), f.len);
    try std.testing.expectEqualStrings("tag:work", f[0]);
    try std.testing.expectEqualStrings("overdue", f[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.positionals.items.len);

    const bad = [_][]const u8{"--nope"};
    try std.testing.expectError(error.UnknownFlag, parse(a, &bad, &specs));

    const missing = [_][]const u8{"--sort"};
    try std.testing.expectError(error.MissingValue, parse(a, &missing, &specs));
}

fn findSpec(specs: []const OptionSpec, name: []const u8) ?OptionSpec {
    for (specs) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

// argv should NOT include the program name or the subcommand — pass the flags only.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8, specs: []const OptionSpec) ParseError!ParsedArgs {
    var result = ParsedArgs{
        .bools = std.StringHashMap(void).init(allocator),
        .values = std.StringHashMap([]const u8).init(allocator),
        .multis = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        .positionals = .empty,
    };
    errdefer deinit(allocator, &result);

    var i: usize = 0;
    var no_more_flags = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!no_more_flags and std.mem.eql(u8, arg, "--")) {
            no_more_flags = true;
            continue;
        }
        if (no_more_flags or !std.mem.startsWith(u8, arg, "--")) {
            try result.positionals.append(allocator, arg);
            continue;
        }
        const body = arg[2..];
        // split on '=' if present
        var name = body;
        var inline_val: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            name = body[0..eq];
            inline_val = body[eq + 1 ..];
        }
        const spec = findSpec(specs, name) orelse return error.UnknownFlag;
        switch (spec.kind) {
            // boolean flags are presence-only; any `=value` (inline_val) is intentionally ignored
            .boolean => try result.bools.put(name, {}),
            .value, .multi => {
                const val = inline_val orelse blk: {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    break :blk argv[i];
                };
                if (spec.kind == .value) {
                    try result.values.put(name, val);
                } else {
                    const gop = try result.multis.getOrPut(name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(allocator, val);
                }
            },
        }
    }
    return result;
}

test "parser treats args after -- as positionals" {
    const a = std.testing.allocator;
    const specs = [_]OptionSpec{
        .{ .name = "flat", .kind = .boolean },
    };
    const argv = [_][]const u8{ "--flat", "--", "--not-a-flag", "pos" };
    var parsed = try parse(a, &argv, &specs);
    defer deinit(a, &parsed);

    try std.testing.expect(parsed.getBool("flat"));
    try std.testing.expectEqual(@as(usize, 2), parsed.positionals.items.len);
    try std.testing.expectEqualStrings("--not-a-flag", parsed.positionals.items[0]);
    try std.testing.expectEqualStrings("pos", parsed.positionals.items[1]);
}

pub fn deinit(allocator: std.mem.Allocator, p: *ParsedArgs) void {
    p.bools.deinit();
    p.values.deinit();
    var it = p.multis.valueIterator();
    while (it.next()) |list| list.deinit(allocator);
    p.multis.deinit();
    p.positionals.deinit(allocator);
}
