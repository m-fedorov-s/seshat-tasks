const std = @import("std");
const build_options = @import("build_options");
const Config = @import("core/config.zig").Config;
const Client = @import("api/client.zig").Client;
const task = @import("core/task.zig");
const types = @import("api/types.zig");
const formatter = @import("formatter.zig");
const view = @import("core/view.zig");
const argparse = @import("core/args.zig");
const edit = @import("core/edit.zig");
const filterspec = @import("core/filterspec.zig");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // run()/its callees already printed a user-facing message for expected failures.
        error.Reported => std.process.exit(1),
        // Broken pipe: the consumer closed stdout early (`seshat show | head`, quitting
        // a pager, `| grep -q`). Unix convention is a clean stop, not an error.
        // `error.StdoutClosed` is a distinct error deliberately mapped from
        // `error.WriteFailed` ONLY at stdout write/flush sites (see `stdoutErr` below) —
        // never at api/client.zig's HTTP writes, which raise the exact same
        // `error.WriteFailed` (a one-member error set per Zig 0.16's std.Io.Writer) for a
        // dropped connection. A raw `error.WriteFailed` reaching this switch therefore did
        // NOT come from stdout and must fall through to the catch-all below, propagating
        // nonzero — otherwise `seshat done <id>` on a dropped connection would exit 0 while
        // silently never reaching the server.
        error.StdoutClosed => std.process.exit(0),
        // Unexpected (network, render, OOM, ...): one clean line, no stack trace.
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

// Maps a stdout write/flush failure (`error.WriteFailed`) to the distinct
// `error.StdoutClosed`, so `main`'s broken-pipe exit-0 path cannot accidentally swallow a
// `error.WriteFailed` raised elsewhere (e.g. a network write in api/client.zig). Call this
// ONLY at stdout write/flush sites — never wrap a `client.*` call with it.
fn stdoutErr(err: anyerror) anyerror {
    return if (err == error.WriteFailed) error.StdoutClosed else err;
}

// api/client.zig no longer prints: a non-2xx response is *recorded* on the Client (so a
// future alt-screen TUI can put it in a status line instead of corrupting the display) and
// surfaced as `error.ApiFailed`. The CLI's user-facing line is emitted here instead —
// same text, same `error.Reported` → silent exit 1 as before. Any other error (network,
// OOM) passes through untouched to main's catch-all.
fn reportApiError(client: *Client, err: anyerror) anyerror {
    if (err != error.ApiFailed) return err;
    const e = client.lastError() orelse return err;
    std.debug.print("server error ({d}): {s}\n", .{ e.code, e.message });
    return error.Reported;
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var out = std.Io.File.stdout().writer(init.io, &.{});

    // Handled before the config load on purpose: a machine with no config is exactly
    // where you need to ask which binary this is.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--version")) {
        out.interface.print("seshat {s}\n", .{build_options.version}) catch |err| return stdoutErr(err);
        out.flush() catch |err| return stdoutErr(err);
        return;
    }

    const home = init.environ_map.get("HOME") orelse return error.HomeNotFound;
    const config_path = init.environ_map.get("SESHAT_CONFIG") orelse
        try std.fs.path.join(allocator, &.{ home, ".config", "seshat", "config.json" });

    const parsed_config = Config.load(init.io, allocator, home, config_path) catch |err| {
        if (err == error.BadOffset) {
            std.debug.print(
                "Error loading config from {s}: utc_offset must be +HH:MM or -HH:MM (e.g. +03:00, -05:00), range +14:00 to -14:00\n",
                .{config_path},
            );
        } else {
            std.debug.print("Error loading config from {s}: {any}\n", .{ config_path, err });
        }
        return error.Reported;
    };
    defer parsed_config.deinit();
    const config = parsed_config.value;

    var client = Client.init(init.io, allocator, &config);

    if (args.len < 2) return usage();
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "show")) {
        try runShow(allocator, init, &client, &out.interface, args[2..]);
    } else if (std.mem.eql(u8, cmd, "add")) {
        try runAdd(allocator, init, &client, &out.interface, args[2..]);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 3) {
            std.debug.print("Usage: seshat delete <id>\n", .{});
            return error.Reported;
        }
        const tasks = client.fetchTasks(allocator) catch |err| return reportApiError(&client, err);
        const t = view.resolve(tasks, args[2]) catch |err| {
            reportResolveError(err, args[2]);
            return error.Reported;
        };
        client.deleteTask(allocator, t.id) catch |err| return reportApiError(&client, err);
    } else if (std.mem.eql(u8, cmd, "done")) {
        if (args.len < 3) {
            std.debug.print("Usage: seshat done <id>\n", .{});
            return error.Reported;
        }
        try markDone(allocator, &client, args[2]);
    } else if (std.mem.eql(u8, cmd, "update")) {
        try runUpdate(allocator, init, &client, &out.interface, args[2..]);
    } else if (std.mem.eql(u8, cmd, "help")) {
        return usage();
    } else {
        std.debug.print("Unknown command\n", .{});
        usage();
        return error.Reported;
    }
}

const show_specs = [_]argparse.OptionSpec{
    .{ .name = "sort", .kind = .value },
    .{ .name = "filter", .kind = .multi },
    .{ .name = "open", .kind = .boolean },
    .{ .name = "flat", .kind = .boolean },
    .{ .name = "detailed", .kind = .boolean },
    .{ .name = "json", .kind = .boolean },
    .{ .name = "no-color", .kind = .boolean },
};

fn runShow(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    client: *Client,
    out: *std.Io.Writer,
    flag_argv: []const []const u8,
) !void {
    var parsed = argparse.parse(allocator, flag_argv, &show_specs) catch |err| {
        std.debug.print("Bad arguments to `show`: {s}\n", .{@errorName(err)});
        return error.Reported;
    };
    defer argparse.deinit(allocator, &parsed);

    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(init.io, .real).nanoseconds, std.time.ns_per_s));
    const tasks = client.fetchTasks(allocator) catch |err| return reportApiError(client, err);
    var idx = try view.Index.build(allocator, tasks);
    defer idx.deinit();

    // --- build Filters ---
    // filterspec.parse only knows about `--filter` expressions; `--open` (seeds the
    // status list) and `--flat` (roots_only) are merged in here, not inside the parser —
    // see client/zig/src/core/filterspec.zig for why.
    const fs = filterspec.parse(allocator, parsed.getMulti("filter")) catch |e| switch (e) {
        error.BadFilter => {
            std.debug.print("error: bad --filter expression (want tag:NAME, status:S1,S2, or overdue)\n", .{});
            return error.Reported;
        },
        error.OutOfMemory => return e,
    };
    defer fs.deinit(allocator);

    var status_list = std.ArrayList(task.Status).empty;
    defer status_list.deinit(allocator);
    if (parsed.getBool("open")) {
        try status_list.append(allocator, .todo);
        try status_list.append(allocator, .in_progress);
    }
    try status_list.appendSlice(allocator, fs.statuses);

    const filters = view.Filters{
        .roots_only = !parsed.getBool("flat"),
        .tags = fs.tags,
        .statuses = status_list.items,
        .overdue = fs.overdue,
    };

    // --- sort strategy ---
    const strategy: view.Strategy = blk: {
        const s = parsed.getValue("sort") orelse break :blk .urgency;
        break :blk std.meta.stringToEnum(view.Strategy, s) orelse {
            std.debug.print("Unknown sort strategy: {s}\n", .{s});
            return error.Reported;
        };
    };

    // --- run pipeline ---
    const selected = try view.select(allocator, tasks, &idx, filters, now);
    defer allocator.free(selected);
    view.rank(selected, strategy, now);

    if (parsed.getBool("json")) {
        formatter.renderJson(out, selected) catch |err| return stdoutErr(err);
        out.flush() catch |err| return stdoutErr(err);
        return;
    }

    if (selected.len == 0) {
        std.debug.print("No tasks match.\n", .{});
        return;
    }

    var opts = if (parsed.getBool("detailed")) formatter.RenderOptions.detailed() else formatter.RenderOptions.compact();
    opts.width = resolveWidth(init, client);
    if (parsed.getBool("flat")) opts.show_children = false;
    opts.color = resolveColor(init, parsed.getBool("no-color"));
    opts.offset_minutes = client.config.offset_minutes;

    // Handle length computed over ALL fetched tasks so every printed #handle is
    // globally unique and resolvable by view.resolve (which scans all tasks).
    var all_ids = std.ArrayList([]const u8).empty;
    defer all_ids.deinit(allocator);
    for (tasks) |t| try all_ids.append(allocator, t.id);
    opts.handle_len = try view.minUniqueSuffixLen(allocator, all_ids.items);

    formatter.render(out, opts, now, selected, &idx) catch |err| return stdoutErr(err);
    out.flush() catch |err| return stdoutErr(err);
}

// auto -> on only if stdout is a TTY and NO_COLOR is unset; --no-color forces off.
// Uses std.Io.File.isTty (Zig 0.16 API) instead of posix.isatty.
fn resolveColor(init: std.process.Init, no_color_flag: bool) formatter.ColorMode {
    if (no_color_flag) return .off;
    if (init.environ_map.get("NO_COLOR") != null) return .off;
    const is_tty = std.Io.File.stdout().isTty(init.io) catch false;
    if (is_tty) return .on;
    return .off;
}

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

fn resolveWidth(init: std.process.Init, client: *Client) usize {
    if (init.environ_map.get("COLUMNS")) |c| {
        if (std.fmt.parseInt(usize, c, 10)) |w| {
            if (w > 0) return w;
        } else |_| {}
    }
    return @as(usize, client.config.width);
}

fn reportPatchError(err: edit.BuildError) void {
    switch (err) {
        error.BadStatus => std.debug.print("Unknown status (todo|in_progress|done|cancelled)\n", .{}),
        error.BadPriority => std.debug.print("Unknown priority (none|low|medium|high)\n", .{}),
        error.BadDate => std.debug.print("Bad date. Use YYYY-MM-DD, YYYY-MM-DDTHH:MM, +Nd/+Nw/+Nm, or none\n", .{}),
        error.OutOfMemory => std.debug.print("Out of memory\n", .{}),
    }
}

// Render a single task. `handle_tasks` sizes the #handle (full fetched set for update;
// just `t` for add). `layout` picks compact/detailed.
fn renderOne(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    out: *std.Io.Writer,
    client: *Client,
    handle_tasks: []const task.Task,
    t: task.Task,
    layout: formatter.Layout,
    now: i64,
) !void {
    var idx = try view.Index.build(allocator, handle_tasks);
    defer idx.deinit();

    var opts = if (layout == .detailed) formatter.RenderOptions.detailed() else formatter.RenderOptions.compact();
    opts.width = resolveWidth(init, client);
    opts.color = resolveColor(init, false);
    opts.offset_minutes = client.config.offset_minutes;

    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (handle_tasks) |x| try ids.append(allocator, x.id);
    opts.handle_len = try view.minUniqueSuffixLen(allocator, ids.items);

    const one = [_]task.Task{t};
    formatter.render(out, opts, now, &one, &idx) catch |err| return stdoutErr(err);
    out.flush() catch |err| return stdoutErr(err);
}

fn reportResolveError(err: view.ResolveError, id_prefix: []const u8) void {
    switch (err) {
        error.NoSuchId => std.debug.print("No task matching id `{s}`\n", .{id_prefix}),
        error.AmbiguousId => std.debug.print("Ambiguous id `{s}` — matches multiple tasks\n", .{id_prefix}),
    }
}

// markDone fetches fresh, resolves the id prefix, flips status to done, sends a
// batch update with the current version. A conflict is reported plainly.
fn markDone(allocator: std.mem.Allocator, client: *Client, id_prefix: []const u8) !void {
    const tasks = client.fetchTasks(allocator) catch |err| return reportApiError(client, err);
    const t = view.resolve(tasks, id_prefix) catch |err| {
        reportResolveError(err, id_prefix);
        return error.Reported;
    };
    var content = t.content;
    content.status = .done;
    const ops = [_]types.UpdateOp{.{ .id = t.id, .content = content, .expected_version = t.meta.version }};
    const result = client.updateTasks(allocator, &ops) catch |err| return reportApiError(client, err);
    switch (result) {
        // The CLI refetched immediately above, so a conflict here means a genuine race
        // with another writer; it has nothing useful to do with the fresh tasks.
        .conflict => {
            std.debug.print("Conflict: task changed on the server. Re-run after a fresh `show`.\n", .{});
            return error.Reported;
        },
        .ok => {},
    }
}

fn runAdd(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    client: *Client,
    out: *std.Io.Writer,
    flag_argv: []const []const u8,
) !void {
    var parsed = argparse.parse(allocator, flag_argv, &edit.flag_specs) catch |err| {
        std.debug.print("Bad arguments to `add`: {s}\n", .{@errorName(err)});
        return error.Reported;
    };
    defer argparse.deinit(allocator, &parsed);

    if (parsed.positionals.items.len < 1) {
        std.debug.print("Usage: seshat add <title> [edits...]\n", .{});
        return error.Reported;
    }
    const title = parsed.positionals.items[0];
    const now = nowSeconds(init.io);

    const patch = edit.patchFromArgs(allocator, &parsed, now, client.config.offset_minutes) catch |err| {
        reportPatchError(err);
        return error.Reported;
    };
    const new_content = edit.applyPatch(.{ .title = title }, patch);
    edit.validate(new_content) catch |err| {
        std.debug.print("Invalid task: {s}\n", .{@errorName(err)});
        return error.Reported;
    };

    if (parsed.getBool("dry-run")) {
        // No server id yet; use a placeholder so the preview renders a (meaningless) handle.
        const placeholder = "??????????????????????????"; // 26 chars, ULID width
        const preview = task.Task{ .id = placeholder, .content = new_content, .meta = .{} };
        try renderOne(allocator, init, out, client, &.{preview}, preview, .detailed, now);
        return;
    }

    const created = client.addTask(allocator, new_content, null) catch |err| return reportApiError(client, err);
    if (parsed.getBool("verbose")) {
        const one = [_]task.Task{created};
        try renderOne(allocator, init, out, client, &one, created, .compact, now);
    }
}

fn runUpdate(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    client: *Client,
    out: *std.Io.Writer,
    flag_argv: []const []const u8,
) !void {
    var parsed = argparse.parse(allocator, flag_argv, &edit.flag_specs) catch |err| {
        std.debug.print("Bad arguments to `update`: {s}\n", .{@errorName(err)});
        return error.Reported;
    };
    defer argparse.deinit(allocator, &parsed);

    if (parsed.positionals.items.len < 1) {
        std.debug.print("Usage: seshat update <id> [edits...]\n", .{});
        return error.Reported;
    }
    const id = parsed.positionals.items[0];
    const now = nowSeconds(init.io);

    const patch = edit.patchFromArgs(allocator, &parsed, now, client.config.offset_minutes) catch |err| {
        reportPatchError(err);
        return error.Reported;
    };
    if (patch.isEmpty()) {
        std.debug.print("nothing to update\n", .{});
        return error.Reported;
    }

    const tasks = client.fetchTasks(allocator) catch |err| return reportApiError(client, err);
    const t = view.resolve(tasks, id) catch |err| {
        reportResolveError(err, id);
        return error.Reported;
    };

    const new_content = edit.applyPatch(t.content, patch);
    edit.validate(new_content) catch |err| {
        std.debug.print("Invalid task: {s}\n", .{@errorName(err)});
        return error.Reported;
    };

    if (parsed.getBool("dry-run")) {
        const preview = task.Task{ .id = t.id, .content = new_content, .meta = t.meta };
        try renderOne(allocator, init, out, client, tasks, preview, .detailed, now);
        return;
    }

    const ops = [_]types.UpdateOp{.{ .id = t.id, .content = new_content, .expected_version = t.meta.version }};
    const result = client.updateTasks(allocator, &ops) catch |err| return reportApiError(client, err);
    const updated = switch (result) {
        // As in markDone: this process refetched a moment ago, so the fresh tasks the 409
        // carries add nothing the user can act on here. The TUI is the caller that uses them.
        .conflict => {
            std.debug.print("Conflict: task changed on the server. Re-run after a fresh `show`.\n", .{});
            return error.Reported;
        },
        .ok => |tasks_out| tasks_out,
    };

    if (parsed.getBool("verbose") and updated.len > 0) {
        try renderOne(allocator, init, out, client, updated, updated[0], .compact, now);
    }
}

fn usage() void {
    std.debug.print(
        \\Usage: seshat <command> [args]
        \\
        \\Commands:
        \\  show [flags]      Show tasks. Flags:
        \\                      --sort <priority|due|title|created|urgency>  (default urgency)
        \\                      --filter <tag:NAME|status:S1,S2|overdue>     (repeatable, AND)
        \\                      --open        only todo/in_progress
        \\                      --flat        rank all tasks, no tree
        \\                      --detailed    rich output (tags, dates, ids, description)
        \\                      --json        machine-readable Task array
        \\                      --no-color    disable color
        \\  add <title> [edits]   Add a top-level task. Accepts the edit flags below.
        \\  update <id> [edits]   Edit a task (id tail / #handle). Edit flags:
        \\                      --title S  --description S  --status S  --priority S
        \\                      --due DATE|none  --scheduled DATE|none  --tags a,b,c
        \\                      DATE = YYYY-MM-DD | YYYY-MM-DDTHH:MM | +Nd|+Nw|+Nm
        \\                      (interpreted in the configured local offset; see utc_offset
        \\                       in config.json)
        \\                      --dry-run   preview the result, do not write
        \\                      --verbose   print the resulting task on success
        \\  delete <id>       Delete a task (accepts an id tail / #handle, e.g. delete a1b2)
        \\  done <id>         Mark a task done (accepts an id tail / #handle, e.g. done a1b2)
        \\  --version         Print the client version and exit
        \\
    , .{});
}

test {
    // Make the pure-module unit tests reachable from `zig build test`
    // (the build test root is this file; see client/zig/CLAUDE.md).
    _ = @import("core/view.zig");
    _ = @import("core/args.zig");
    _ = @import("core/display.zig");
    _ = @import("formatter.zig");
    _ = @import("core/config.zig");
    _ = @import("core/edit.zig");
    _ = @import("core/filterspec.zig");
    _ = @import("api/client.zig");
    _ = @import("tui/ledger.zig");
    _ = @import("tui/editors.zig");
    _ = @import("tui/model.zig");
    // render.zig has no tests of its own (spec §14) and nothing imports it yet, so
    // this import plus its own `refAllDecls` block is the ONLY thing that gets its
    // function bodies typechecked at all.
    _ = @import("tui/render.zig");
}
