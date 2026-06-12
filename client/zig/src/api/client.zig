const std = @import("std");
const Config = @import("../core/config.zig").Config;
const Task = @import("../core/task.zig").Task;
const types = @import("types.zig");
const CacheProvider = @import("../core/cache.zig").CacheProvider;

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const Config,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: *const Config) Client {
        return .{
            .io = io,
            .allocator = allocator,
            .config = config,
        };
    }

    fn endpointUrl(self: *Client, path: []const u8) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.config.url, path });
    }

    pub fn fetchTasks(self: *Client) ![]Task {
        const cache = CacheProvider.init(self.io, self.allocator, self.config.cache_dir);

        if (try cache.getTasks(self.allocator, self.config.url, self.config.cache_ttl_seconds)) |cached| {
            return cached;
        }

        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        const url = try self.endpointUrl("/api/tasks/get");
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);
        var req = try client.request(.GET, uri, .{
            .headers = .{ .authorization = .{ .override = self.config.secret } },
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buffer: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) return error.HttpError;

        const body = try response.reader(&.{}).allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(body);

        const parsed = try std.json.parseFromSlice([]Task, self.allocator, body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var tasks = try self.allocator.alloc(Task, parsed.value.len);
        for (parsed.value, 0..) |task, i| {
            tasks[i] = .{
                .id = try self.allocator.dupe(u8, task.id),
                .title = try self.allocator.dupe(u8, task.title),
                .priority = task.priority,
                .status = task.status,
            };
        }

        try cache.saveTasks(self.config.url, tasks);

        return tasks;
    }

    pub fn addTask(self: *Client, title: []const u8, priority: i32) !void {
        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        const url = try self.endpointUrl("/api/tasks/add");
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);
        const payload = types.AddTaskRequest{ .title = title, .priority = priority };
        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        var stringifier = std.json.Stringify{
            .writer = &out.writer,
            .options = .{},
        };
        try stringifier.write(payload);
        const body = out.toArrayList();

        var req = try client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = self.config.secret },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.items.len };
        try req.sendBodyComplete(body.items);
        const response = try req.receiveHead(&.{});

        if (response.head.status != .ok and response.head.status != .created) return error.HttpError;
    }

    pub fn deleteTask(self: *Client, title: []const u8) !void {
        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        const url = try self.endpointUrl("/api/tasks/delete");
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);
        const payload = types.DeleteTaskRequest{ .title = title };
        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        var stringifier = std.json.Stringify{
            .writer = &out.writer,
            .options = .{},
        };
        try stringifier.write(payload);
        const body = out.toArrayList();

        var req = try client.request(.DELETE, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = self.config.secret },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.items.len };
        try req.sendBodyComplete(body.items);
        const response = try req.receiveHead(&.{});

        if (response.head.status != .ok and response.head.status != .no_content) return error.HttpError;
    }
};
