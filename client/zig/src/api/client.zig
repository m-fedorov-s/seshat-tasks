const std = @import("std");
const Config = @import("../core/config.zig").Config;
const types = @import("types.zig");
const Task = @import("../core/task.zig").Task;

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const Config,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: *const Config) Client {
        return .{ .io = io, .allocator = allocator, .config = config };
    }

    fn endpointUrl(self: *Client, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.url, path });
    }

    // fail reports a non-2xx response using the server's own message where available,
    // then returns error.Reported — matching the client-wide error model (print the
    // user-facing message at the failure site, exit nonzero without a trace).
    // The return type is error{Reported}, NOT anyerror: anyerror would collapse the
    // inferred error sets of fetchTasks/postJson themselves, widening what callers within
    // this file must account for and losing compile-time error-set checking at those call
    // sites. (main.zig's stdoutErr helper already widens run()'s own inferred set via
    // anyerror, so the narrow type here no longer protects all the way up to run() — but
    // it still keeps this file's API surface precise and documents intent.)
    fn fail(self: *Client, status: std.http.Status, body: []const u8) error{Reported} {
        const code = @intFromEnum(status);
        const msg = parseServerError(self.allocator, body) orelse defaultMessage(code);
        std.debug.print("server error ({d}): {s}\n", .{ code, msg });
        return error.Reported;
    }

    // GET all tasks. self.allocator is the process arena, so parse "leaky" into it
    // and return the slice directly — valid until the CLI exits, no frees.
    pub fn fetchTasks(self: *Client) ![]Task {
        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        const url = try self.endpointUrl("/api/tasks/get");
        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{
            .headers = .{ .authorization = .{ .override = self.config.secret } },
        });
        defer req.deinit();
        try req.sendBodiless();

        var rb: [1024]u8 = undefined;
        var resp = try req.receiveHead(&rb);
        if (resp.head.status != .ok) {
            const err_body = resp.reader(&.{}).allocRemaining(self.allocator, .unlimited) catch "";
            return self.fail(resp.head.status, err_body);
        }

        const body = try resp.reader(&.{}).allocRemaining(self.allocator, .unlimited);
        const parsed = try std.json.parseFromSliceLeaky(types.GetResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.tasks;
    }

    pub fn addTask(self: *Client, content: types.Content, parent_id: ?[]const u8) !Task {
        const payload = types.AddRequest{ .content = content, .parent_id = parent_id };
        const body = try self.postJson("/api/tasks/add", payload, &.{ .ok, .created });
        const parsed = try std.json.parseFromSliceLeaky(types.AddResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.task;
    }

    pub fn updateTasks(self: *Client, updates: []const types.UpdateOp) ![]Task {
        const payload = types.UpdateRequest{ .updates = updates };
        const body = try self.postJson("/api/tasks/update", payload, &.{.ok});
        const parsed = try std.json.parseFromSliceLeaky(types.UpdateResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.tasks;
    }

    pub fn deleteTask(self: *Client, id: []const u8) !void {
        const payload = types.DeleteRequest{ .id = id };
        _ = try self.postJson("/api/tasks/delete", payload, &.{ .ok, .no_content });
    }

    // postJson serializes payload, POSTs it, checks status, returns the response body.
    // 409 -> error.Conflict.
    fn postJson(self: *Client, path: []const u8, payload: anytype, ok_statuses: []const std.http.Status) ![]u8 {
        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        const url = try self.endpointUrl(path);
        const uri = try std.Uri.parse(url);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var w = std.json.Stringify{ .writer = &aw.writer, .options = .{} };
        try w.write(payload);
        const body = aw.written();

        var req = try client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = self.config.secret },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        var rb: [1024]u8 = undefined;
        var resp = try req.receiveHead(&rb);
        if (resp.head.status == .conflict) return error.Conflict;
        var ok = false;
        for (ok_statuses) |s| {
            if (resp.head.status == s) ok = true;
        }
        if (!ok) {
            const err_body = resp.reader(&.{}).allocRemaining(self.allocator, .unlimited) catch "";
            return self.fail(resp.head.status, err_body);
        }
        return try resp.reader(&.{}).allocRemaining(self.allocator, .unlimited);
    }
};

// parseServerError extracts the message from the server's `{"error": "..."}` body.
// Returns null when the body is not a JSON object carrying a string `error` field.
//
// LIFETIME: ParseOptions.allocate defaults to .alloc_if_needed for parseFromSlice*,
// so for an unescaped string the result is a SLICE INTO `body`, not a fresh
// allocation — it lives exactly as long as body does. Safe here because callers pass
// an arena-allocated body and print the message immediately. If you ever store the
// result beyond the body's lifetime, pass .allocate = .alloc_always.
//
// Note: `error` is a Zig keyword, hence the @"error" field name.
pub fn parseServerError(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const Envelope = struct { @"error": []const u8 };
    const parsed = std.json.parseFromSliceLeaky(Envelope, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.@"error";
}

// defaultMessage is the fallback when the server sent no parseable body. Switches on
// the numeric code rather than std.http.Status tags, whose names have churned across
// Zig releases.
pub fn defaultMessage(code: u16) []const u8 {
    return switch (code) {
        429 => "rate limited; try again shortly",
        413 => "request too large",
        403 => "access denied (check your secret)",
        404 => "not found",
        else => "unexpected response from server",
    };
}

test "parseServerError extracts the message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msg = parseServerError(arena.allocator(), "{\"error\":\"rate limited\"}");
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("rate limited", msg.?);
}

test "parseServerError ignores unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msg = parseServerError(arena.allocator(), "{\"error\":\"not found\",\"ids\":[\"a\"]}");
    try std.testing.expectEqualStrings("not found", msg.?);
}

test "parseServerError returns null on a body with no error field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(parseServerError(arena.allocator(), "{\"state_version\":1}") == null);
}

test "parseServerError returns null on malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(parseServerError(arena.allocator(), "not json at all") == null);
    try std.testing.expect(parseServerError(arena.allocator(), "") == null);
}

test "defaultMessage covers the statuses Stage 0 introduced" {
    try std.testing.expectEqualStrings("rate limited; try again shortly", defaultMessage(429));
    try std.testing.expectEqualStrings("request too large", defaultMessage(413));
    try std.testing.expectEqualStrings("access denied (check your secret)", defaultMessage(403));
    try std.testing.expectEqualStrings("unexpected response from server", defaultMessage(500));
}
