const std = @import("std");
const Config = @import("core/config.zig").Config;
const Client = @import("api/client.zig").Client;
const formatter = @import("formatter.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    // defer args.deinit();

    const config_path = init.environ_map.get("SESHAT_CONFIG") orelse try get_default_config_path(init, allocator);
    defer allocator.free(config_path);

    const home = init.environ_map.get("HOME") orelse return error.HomeNotFound;
    const parsed_config = Config.load(init.io, allocator, home, config_path) catch |err| {
        std.debug.print("Error loading config from {s}: {any}\n", .{ config_path, err });
        return err;
    };
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var client = Client.init(init.io, allocator, &config);

    if (args.len < 2) {
        usage();
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "show")) {
        const tasks = try client.fetchTasks();
        defer {
            for (tasks) |t| t.deinit(allocator);
            allocator.free(tasks);
        }
        const output = try formatter.formatTasksJson(allocator, tasks, config.max_lines);
        defer allocator.free(output);
        var stdout = std.Io.File.stdout().writer(init.io, &.{});
        try stdout.interface.print("{s}\n", .{output});
    } else if (std.mem.eql(u8, cmd, "add")) {
        if (args.len < 4) {
            std.debug.print("Usage: seshat add <title> <priority>\n", .{});
            return error.InvalidArgs;
        }
        const title = args[2];
        const priority = try std.fmt.parseInt(i32, args[3], 10);
        try client.addTask(title, priority);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 3) {
            std.debug.print("Usage: seshat delete <title>\n", .{});
            return error.InvalidArgs;
        }
        const title = args[2];
        try client.deleteTask(title);
    } else if (std.mem.eql(u8, cmd, "help")) {
        usage();
        return;
    } else {
        std.debug.print("Unknown command\n", .{});
        usage();
        return;
    }
}

fn usage() void {
    std.debug.print(
        \\Usage: seshat <command> [args]
        \\
        \\Commands:
        \\  show              Show tasks
        \\  add <title> <prio> Add a task
        \\  delete <title>    Delete a task
        \\
    , .{});
}

fn get_default_config_path(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const home = init.environ_map.get("HOME") orelse return error.HomeNotFound;
    return try std.fs.path.join(allocator, &.{ home, ".config", "seshat", "config.json" });
}
