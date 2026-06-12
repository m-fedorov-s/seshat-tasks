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
        if (resp.head.status != .ok) return error.HttpError;

        const body = try resp.reader(&.{}).allocRemaining(self.allocator, .unlimited);
        const parsed = try std.json.parseFromSliceLeaky(types.GetResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.tasks;
    }

    pub fn addTask(self: *Client, content: types.Content, parent_id: ?[]const u8) !void {
        const payload = types.AddRequest{ .content = content, .parent_id = parent_id };
        try self.postJson("/api/tasks/add", payload, &.{ .ok, .created });
    }

    pub fn updateTasks(self: *Client, updates: []const types.UpdateOp) !void {
        const payload = types.UpdateRequest{ .updates = updates };
        try self.postJson("/api/tasks/update", payload, &.{.ok});
    }

    pub fn deleteTask(self: *Client, id: []const u8) !void {
        const payload = types.DeleteRequest{ .id = id };
        try self.postJson("/api/tasks/delete", payload, &.{ .ok, .no_content });
    }

    // postJson serializes payload, POSTs it, checks status. 409 -> error.Conflict.
    fn postJson(self: *Client, path: []const u8, payload: anytype, ok_statuses: []const std.http.Status) !void {
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
        const resp = try req.receiveHead(&rb);
        if (resp.head.status == .conflict) return error.Conflict;
        for (ok_statuses) |s| if (resp.head.status == s) return;
        return error.HttpError;
    }
};
