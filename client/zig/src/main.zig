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
const app = @import("tui/app.zig");
const shell = @import("shell.zig");

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

    // Before the config load, like --version: the installer has no config file, maybe no $HOME.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "completions"))
        return runCompletions(&out, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "init"))
        return runInit(&out, args[2..]);

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
    } else if (std.mem.eql(u8, cmd, "tui")) {
        try runTui(allocator, init, &client, args[2..]);
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

fn runCompletions(out: *std.Io.File.Writer, argv: []const []const u8) !void {
    if (argv.len != 1) {
        std.debug.print("Usage: seshat completions <fish|bash|zsh>\n", .{});
        return error.Reported;
    }
    // Annotated because each @embedFile has its own `*const [N:0]u8` type.
    const blob: []const u8 = if (std.mem.eql(u8, argv[0], "fish"))
        shell.fish_completions
    else if (std.mem.eql(u8, argv[0], "bash"))
        shell.bash_completions
    else if (std.mem.eql(u8, argv[0], "zsh"))
        shell.zsh_completions
    else {
        std.debug.print("unknown shell \"{s}\" (want fish, bash or zsh)\n", .{argv[0]});
        return error.Reported;
    };
    out.interface.writeAll(blob) catch |err| return stdoutErr(err);
    out.flush() catch |err| return stdoutErr(err);
}

// ORDER IS LOAD-BEARING: conf.d's `status is-interactive; or exit` guard aborts sourcing at
// that point, so the function definitions must precede it. This makes
// `seshat init fish > ~/.config/fish/conf.d/seshat.fish` a complete single-file install.
fn runInit(out: *std.Io.File.Writer, argv: []const []const u8) !void {
    if (argv.len != 1) {
        std.debug.print("Usage: seshat init fish\n", .{});
        return error.Reported;
    }
    if (!std.mem.eql(u8, argv[0], "fish")) {
        std.debug.print("seshat init: only \"fish\" is supported (got \"{s}\")\n", .{argv[0]});
        return error.Reported;
    }
    out.interface.writeAll(shell.fish_functions) catch |err| return stdoutErr(err);
    out.interface.writeAll(shell.fish_conf_d) catch |err| return stdoutErr(err);
    out.flush() catch |err| return stdoutErr(err);
}

const show_specs = [_]argparse.OptionSpec{
    .{ .name = "sort", .kind = .value },
    .{ .name = "filter", .kind = .multi },
    .{ .name = "open", .kind = .boolean },
    .{ .name = "flat", .kind = .boolean },
    .{ .name = "detailed", .kind = .boolean },
    .{ .name = "json", .kind = .boolean },
    .{ .name = "no-color", .kind = .boolean },
    .{ .name = "limit", .kind = .value },
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

    // Parsed before the fetch so a bad value costs no request.
    const limit: ?usize = if (parsed.getValue("limit")) |s|
        argparse.positiveInt(s) orelse {
            std.debug.print("error: --limit must be a positive integer\n", .{});
            return error.Reported;
        }
    else
        null;

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

    // Derived from the parsed flags, not opts.show_children — opts is built below, after
    // the --json early return.
    const count_children = !parsed.getBool("flat") and !parsed.getBool("json");
    const lim = if (limit) |n|
        view.limitRows(selected, count_children, n)
    else
        view.Limited{ .shown = selected, .hidden_rows = 0 };

    if (parsed.getBool("json")) {
        // No trailer: a trailer would make the output not-JSON.
        formatter.renderJson(out, lim.shown) catch |err| return stdoutErr(err);
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

    formatter.render(out, opts, now, lim.shown, &idx) catch |err| return stdoutErr(err);
    if (lim.hidden_rows > 0)
        out.print("… and {d} more\n", .{lim.hidden_rows}) catch |err| return stdoutErr(err);
    out.flush() catch |err| return stdoutErr(err);
}

// The TUI takes the view flags that mean something to a full-screen tree:
// `--filter`, `--open` and `--sort`, parsed and merged exactly as `runShow` does.
//
// `--flat` is deliberately NOT accepted. In `show` it does two unrelated things —
// `roots_only = false` (rank every task as a top-level entry) and
// `show_children = false` (print no subtrees) — and the TUI's ledger is a tree by
// construction: folding, the `(+n)` badge and subtree scoring all assume roots
// with descendants under them. There is no flat mode to turn on.
const tui_specs = [_]argparse.OptionSpec{
    .{ .name = "sort", .kind = .value },
    .{ .name = "filter", .kind = .multi },
    .{ .name = "open", .kind = .boolean },
};

fn runTui(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    client: *Client,
    flag_argv: []const []const u8,
) !void {
    var parsed = argparse.parse(allocator, flag_argv, &tui_specs) catch |err| {
        std.debug.print("Bad arguments to `tui`: {s}\n", .{@errorName(err)});
        return error.Reported;
    };
    defer argparse.deinit(allocator, &parsed);

    // LIFETIME: everything below is handed to `app.run` and read for the whole
    // session, so unlike `runShow` nothing here is freed on the way out. In
    // particular there is no `fs.deinit` — `allocator` is the process arena, whose
    // `free` reclaims the most recent allocation, which would hand the filter's
    // own bytes to the next allocation in the session.
    const fs = filterspec.parse(allocator, parsed.getMulti("filter")) catch |e| switch (e) {
        error.BadFilter => {
            std.debug.print("error: bad --filter expression (want tag:NAME, status:S1,S2, or overdue)\n", .{});
            return error.Reported;
        },
        error.OutOfMemory => return e,
    };

    var status_list = std.ArrayList(task.Status).empty;
    if (parsed.getBool("open")) {
        try status_list.append(allocator, .todo);
        try status_list.append(allocator, .in_progress);
    }
    try status_list.appendSlice(allocator, fs.statuses);

    const filters = view.Filters{
        // Always a forest: see the `--flat` note above.
        .roots_only = true,
        .tags = fs.tags,
        .statuses = try status_list.toOwnedSlice(allocator),
        .overdue = fs.overdue,
    };

    const strategy: view.Strategy = blk: {
        const s = parsed.getValue("sort") orelse break :blk .urgency;
        break :blk std.meta.stringToEnum(view.Strategy, s) orelse {
            std.debug.print("Unknown sort strategy: {s}\n", .{s});
            return error.Reported;
        };
    };

    // The filter EXPRESSION travels alongside the parsed filters because the
    // model's three filter-aware behaviours read the text and the flag, not
    // `m.filters`: the header's scope word, the dimming of rows that matched only
    // via a descendant, and `ledger.buildRows`' orphan gate. Handing over
    // `filters` alone would apply the filter while rendering as if none were set.
    //
    // `--open` is spelled out as the status expression it stands for, so the
    // string re-parses to exactly these filters — that keeps the header honest and
    // gives `Esc` (which clears the whole filter) something truthful to clear.
    // Joined with spaces because that is the form the `/` prompt takes: one line,
    // whitespace where the flag repeat used to be.
    var exprs = std.ArrayList([]const u8).empty;
    if (parsed.getBool("open")) try exprs.append(allocator, "status:todo,in_progress");
    try exprs.appendSlice(allocator, parsed.getMulti("filter"));
    const filter_expr = try std.mem.join(allocator, " ", exprs.items);

    // `init.gpa`, NOT the process arena: a TUI session is long-lived and frees as
    // it goes (per-request arenas, editor buffers, the model's own arenas), and an
    // arena's no-op `free` would turn every refresh into permanent growth.
    try app.run(init.io, init.gpa, init.environ_map, client, filters, strategy, filter_expr);
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
        \\                      --limit N     at most N task rows, then "… and M more"
        \\  tui [flags]       Interactive full-screen view. Flags:
        \\                      --sort <priority|due|title|created|urgency>  (default urgency)
        \\                      --filter <tag:NAME|status:S1,S2|overdue>     (repeatable, AND)
        \\                      --open        only todo/in_progress
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
        \\  completions <shell>   Print shell completions (fish|bash|zsh)
        \\  init fish             Print the fish prompt-hook file to stdout
        \\  --version         Print the client version and exit
        \\
    , .{});
}

test {
    // Make the pure-module unit tests reachable from `zig build test`
    // (the build test root is this file; see client/zig/CLAUDE.md).
    _ = @import("shell.zig");
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
    // Same story for app.zig: no tests of its own, and nothing in the exe graph
    // reaches it until the `tui` subcommand exists. This import plus its own
    // `refAllDecls` block is what typechecks the event loop at all.
    _ = @import("tui/app.zig");
}

// A floor only: build_options is baked before this runs, so test/broken-pipe.sh is the
// check that can see a broken fallback.
test "build_options.version is non-empty" {
    try std.testing.expect(build_options.version.len > 0);
}
