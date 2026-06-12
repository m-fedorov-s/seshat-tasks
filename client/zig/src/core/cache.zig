const std = @import("std");
const Task = @import("task.zig").Task;

pub const CacheMetadata = struct {
    last_fetch_timestamp: i64,
    url_hash: [32]u8,
};

pub const CacheProvider = struct {
    io: std.Io,
    root_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8) CacheProvider {
        return .{
            .io = io,
            .root_dir = root_dir,
            .allocator = allocator,
        };
    }

    fn getCachePath(self: CacheProvider, allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &hash, .{});
        const hash_hex = std.fmt.bytesToHex(&hash, .lower);
        return try std.fs.path.join(allocator, &.{ self.root_dir, &hash_hex });
    }

    pub fn getTasks(self: CacheProvider, allocator: std.mem.Allocator, url: []const u8, ttl_seconds: u64) !?[]Task {
        const path = try self.getCachePath(allocator, url);
        defer allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const now = std.Io.Clock.now(.awake, self.io);
        if (stat.mtime.durationTo(now).toNanoseconds() > @as(i128, @intCast(ttl_seconds)) * 1000000000) {
            return null;
        }

        var file_reader = file.reader(self.io, &.{});
        const content = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice([]Task, allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // We need to dupe the tasks because parsed.deinit() will free the strings
        var tasks = try allocator.alloc(Task, parsed.value.len);
        for (parsed.value, 0..) |task, i| {
            tasks[i] = .{
                .id = try allocator.dupe(u8, task.id),
                .title = try allocator.dupe(u8, task.title),
                .priority = task.priority,
                .status = task.status,
            };
        }
        return tasks;
    }

    pub fn saveTasks(self: CacheProvider, url: []const u8, tasks: []const Task) !void {
        const path = try self.getCachePath(self.allocator, url);
        defer self.allocator.free(path);

        // Ensure directory exists
        std.Io.Dir.cwd().createDirPath(self.io, self.root_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);

        var file_writer = file.writer(self.io, &.{});

        var stringifier = std.json.Stringify{
            .writer = &file_writer.interface,
            .options = .{},
        };
        try stringifier.write(tasks);
    }
};

test "CacheProvider save and load tasks" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the absolute path of the tmp dir
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cache = CacheProvider.init(allocator, tmp_path);

    const tasks = [_]Task{
        .{ .id = "1", .title = "Buy milk", .priority = 1, .status = .todo },
        .{ .id = "2", .title = "Write tests", .priority = 2, .status = .done },
    };

    const url = "http://example.com/tasks";

    // Save tasks
    try cache.saveTasks(url, &tasks);

    // Load tasks with a generous TTL (1 hour)
    const loaded = try cache.getTasks(allocator, url, 3600);
    try testing.expect(loaded != null);

    const loaded_tasks = loaded.?;
    defer {
        for (loaded_tasks) |t| t.deinit(allocator);
        allocator.free(loaded_tasks);
    }

    try testing.expectEqual(@as(usize, 2), loaded_tasks.len);
    try testing.expectEqualStrings("1", loaded_tasks[0].id);
    try testing.expectEqualStrings("Buy milk", loaded_tasks[0].title);
    try testing.expectEqual(@as(i32, 1), loaded_tasks[0].priority);
    try testing.expectEqual(Task.Status.todo, loaded_tasks[0].status);
    try testing.expectEqualStrings("2", loaded_tasks[1].id);
    try testing.expectEqualStrings("Write tests", loaded_tasks[1].title);
    try testing.expectEqual(@as(i32, 2), loaded_tasks[1].priority);
    try testing.expectEqual(Task.Status.done, loaded_tasks[1].status);
}
