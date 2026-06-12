const std = @import("std");
const Config = @import("core/config.zig").Config;
const Client = @import("api/client.zig").Client;
const task = @import("core/task.zig");
const types = @import("api/types.zig");
const formatter = @import("formatter.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const home = init.environ_map.get("HOME") orelse return error.HomeNotFound;
    const config_path = init.environ_map.get("SESHAT_CONFIG") orelse
        try std.fs.path.join(allocator, &.{ home, ".config", "seshat", "config.json" });

    const parsed_config = Config.load(init.io, allocator, home, config_path) catch |err| {
        std.debug.print("Error loading config from {s}: {any}\n", .{ config_path, err });
        return err;
    };
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var client = Client.init(init.io, allocator, &config);
    var out = std.Io.File.stdout().writer(init.io, &.{});

    if (args.len < 2) return usage();
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "show")) {
        const tasks = try client.fetchTasks();
        try formatter.render(allocator, &out.interface, tasks);
        try out.interface.flush();
    } else if (std.mem.eql(u8, cmd, "add")) {
        if (args.len < 3) {
            std.debug.print("Usage: seshat add <title> [priority]\n", .{});
            return error.InvalidArgs;
        }
        const priority = if (args.len >= 4) std.meta.stringToEnum(task.Priority, args[3]) orelse .none else .none;
        const content = task.Content{ .title = args[2], .priority = priority };
        try client.addTask(content, null);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 3) {
            std.debug.print("Usage: seshat delete <id>\n", .{});
            return error.InvalidArgs;
        }
        try client.deleteTask(args[2]);
    } else if (std.mem.eql(u8, cmd, "done")) {
        if (args.len < 3) {
            std.debug.print("Usage: seshat done <id>\n", .{});
            return error.InvalidArgs;
        }
        try markDone(&client, args[2]);
    } else if (std.mem.eql(u8, cmd, "help")) {
        return usage();
    } else {
        std.debug.print("Unknown command\n", .{});
        return usage();
    }
}

// markDone fetches the task fresh, flips status to done, sends a batch update
// with its current version. A conflict is reported plainly.
fn markDone(client: *Client, id: []const u8) !void {
    const tasks = try client.fetchTasks();
    for (tasks) |t| {
        if (std.mem.eql(u8, t.id, id)) {
            var content = t.content;
            content.status = .done;
            const ops = [_]types.UpdateOp{.{ .id = id, .content = content, .expected_version = t.meta.version }};
            client.updateTasks(&ops) catch |err| {
                if (err == error.Conflict) {
                    std.debug.print("Conflict: task changed on the server. Re-run after a fresh `show`.\n", .{});
                    return;
                }
                return err;
            };
            return;
        }
    }
    std.debug.print("No task with id {s}\n", .{id});
}

fn usage() void {
    std.debug.print(
        \\Usage: seshat <command> [args]
        \\
        \\Commands:
        \\  show              Show tasks (forest)
        \\  add <title> [prio] Add a top-level task
        \\  delete <id>       Delete a task by id
        \\  done <id>         Mark a task done by id
        \\
    , .{});
}
