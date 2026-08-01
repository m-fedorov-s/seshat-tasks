const std = @import("std");
const Config = @import("../core/config.zig").Config;
const types = @import("types.zig");
const Task = @import("../core/task.zig").Task;

// ApiError is a non-2xx response recorded on the Client instead of printed. A long-lived
// caller (the TUI) runs inside an alt-screen where a stray stderr write corrupts the
// display, so the failure has to be *data*, not output.
//
// `message` is OWNED by the Client: recordError dupes it out of the response body, and
// clearError frees it. It must never be a slice into a response body — parseServerError
// returns exactly such a slice, and the body lives in a per-request arena that is reset
// long before the message is rendered.
pub const ApiError = struct {
    code: u16,
    message: []const u8,
};

// The outcome of an optimistic-concurrency batch update. A 409 is not an error: the
// server hands back the fresh tasks it rejected the write against, which is precisely
// what a caller needs to reconcile.
pub const UpdateResult = union(enum) {
    ok: []Task,
    conflict: []Task,
};

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const Config,
    // Owned by `allocator` (see recordError/clearError). Null until a request fails.
    last_error: ?ApiError = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: *const Config) Client {
        return .{ .io = io, .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        self.clearError(self.allocator);
    }

    fn endpointUrl(self: *Client, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ self.config.url, path });
    }

    // recordError stores a non-2xx response as data. `alloc` owns the resulting message
    // and must be the SAME allocator later passed to clearError — pass a long-lived one
    // (self.allocator), never the per-request arena the body came from.
    //
    // The message is the server's own `{"error": "..."}` text, falling back to
    // defaultMessage(code). It is duped: parseServerError's result aliases `body`.
    // Recording twice frees the previous message first, so it cannot leak.
    pub fn recordError(self: *Client, alloc: std.mem.Allocator, code: u16, body: []const u8) !void {
        // parseServerError may allocate (an escaped JSON string), so give it scratch we
        // can drop wholesale; only the duped message survives.
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const msg = parseServerError(scratch.allocator(), body) orelse defaultMessage(code);
        // Dupe BEFORE clearing: on OOM the previous error is left intact, and `body` is
        // allowed to alias the message we are about to free.
        const owned = try alloc.dupe(u8, msg);
        self.clearError(alloc);
        self.last_error = .{ .code = code, .message = owned };
    }

    // clearError frees the recorded message. Idempotent.
    pub fn clearError(self: *Client, alloc: std.mem.Allocator) void {
        if (self.last_error) |e| alloc.free(e.message);
        self.last_error = null;
    }

    // lastError returns the failure recorded by the most recent request. The message is
    // valid until the next recordError/clearError.
    pub fn lastError(self: *const Client) ?ApiError {
        return self.last_error;
    }

    // fail records a non-2xx response and returns error.ApiFailed. The caller decides how
    // to surface it: the CLI prints `server error (<code>): <message>` and exits nonzero;
    // the TUI puts it in the status line.
    // The return type is an error SET (an error value, not an error union), NOT anyerror:
    // anyerror would collapse the inferred error sets of fetchTasks/postJson themselves,
    // widening what callers within this file must account for and losing compile-time
    // error-set checking at those call sites. An error-set return is also what lets
    // `return self.fail(...)` sit in functions with different payload types.
    fn fail(self: *Client, status: std.http.Status, body: []const u8) error{ ApiFailed, OutOfMemory } {
        // Recorded against self.allocator, not the per-request `alloc`: the message has to
        // outlive the request whose arena the body lives in.
        // (An error-set return type cannot host `try`, hence the explicit catch.)
        self.recordError(self.allocator, @intFromEnum(status), body) catch |e| return e;
        return error.ApiFailed;
    }

    // GET all tasks. Everything (connection buffers, the response body, the parsed tasks)
    // comes from `alloc`, so a long-lived caller can hand in a per-fetch arena and reclaim
    // the whole lot. The tasks are parsed .alloc_always, so they do NOT alias the body.
    pub fn fetchTasks(self: *Client, alloc: std.mem.Allocator) ![]Task {
        var client = std.http.Client{ .io = self.io, .allocator = alloc };
        defer client.deinit();

        const url = try self.endpointUrl(alloc, "/api/tasks/get");
        defer alloc.free(url);
        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{
            .headers = .{ .authorization = .{ .override = self.config.secret } },
        });
        defer req.deinit();
        try req.sendBodiless();

        var rb: [1024]u8 = undefined;
        var resp = try req.receiveHead(&rb);
        if (resp.head.status != .ok) {
            const err_body = resp.reader(&.{}).allocRemaining(alloc, .unlimited) catch "";
            defer if (err_body.len > 0) alloc.free(err_body);
            return self.fail(resp.head.status, err_body);
        }

        const body = try resp.reader(&.{}).allocRemaining(alloc, .unlimited);
        defer alloc.free(body);
        return parseGet(alloc, body);
    }

    pub fn addTask(self: *Client, alloc: std.mem.Allocator, content: types.Content, parent_id: ?[]const u8) !Task {
        const payload = types.AddRequest{ .content = content, .parent_id = parent_id };
        const res = try self.postJson(alloc, "/api/tasks/add", payload, &.{ .ok, .created });
        defer alloc.free(res.body);
        return parseAdd(alloc, res.body);
    }

    // updateTasks sends an atomic batch with per-task expected_version. A 409 comes back
    // as `.conflict` carrying the server's fresh tasks, NOT as an error — see
    // types.ConflictResponse.
    pub fn updateTasks(self: *Client, alloc: std.mem.Allocator, updates: []const types.UpdateOp) !UpdateResult {
        const payload = types.UpdateRequest{ .updates = updates };
        const res = try self.postJson(alloc, "/api/tasks/update", payload, update_statuses);
        defer alloc.free(res.body);
        return updateResultFrom(alloc, res.status, res.body);
    }

    // The statuses updateTasks accepts. 409 is in here on purpose — it is an outcome, not
    // a failure — and dropping it would silently route every conflict through fail().
    const update_statuses: []const std.http.Status = &.{ .ok, .conflict };

    pub fn deleteTask(self: *Client, alloc: std.mem.Allocator, id: []const u8) !void {
        const payload = types.DeleteRequest{ .id = id };
        const res = try self.postJson(alloc, "/api/tasks/delete", payload, &.{ .ok, .no_content });
        alloc.free(res.body);
    }

    const PostResult = struct {
        status: std.http.Status,
        // Allocated from the caller's `alloc`; the caller frees it.
        body: []u8,
    };

    // postJson serializes payload, POSTs it, and returns the status + response body for
    // any status the caller listed in ok_statuses. Anything else is recorded via fail().
    // Note 409 is only accepted when the caller asks for it (updateTasks does); on any
    // other endpoint the server never emits one, so it falls through to fail() rather
    // than getting a bespoke error.
    fn postJson(
        self: *Client,
        alloc: std.mem.Allocator,
        path: []const u8,
        payload: anytype,
        ok_statuses: []const std.http.Status,
    ) !PostResult {
        var client = std.http.Client{ .io = self.io, .allocator = alloc };
        defer client.deinit();

        const url = try self.endpointUrl(alloc, path);
        defer alloc.free(url);
        const uri = try std.Uri.parse(url);

        var aw: std.Io.Writer.Allocating = .init(alloc);
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
        for (ok_statuses) |s| {
            if (resp.head.status == s) return .{
                .status = resp.head.status,
                .body = try resp.reader(&.{}).allocRemaining(alloc, .unlimited),
            };
        }
        const err_body = resp.reader(&.{}).allocRemaining(alloc, .unlimited) catch "";
        defer if (err_body.len > 0) alloc.free(err_body);
        return self.fail(resp.head.status, err_body);
    }
};

// ---------------------------------------------------------------------------------------
// Response parsing.
//
// EVERY parse below uses `.allocate = .alloc_always`, and that is the single most important
// invariant in this file. The default (.alloc_if_needed) hands back task strings that are
// SLICES INTO the response body — and every caller frees the body immediately, or resets the
// arena it came from. Under the CLI's process arena that bug is invisible (nothing is ever
// reclaimed, so an aliased string reads correctly forever); under the TUI's per-request arena
// it surfaces as corrupted titles mid-session, nowhere near this code.
//
// Each of these is a separate function purely so a test can feed it a body owned by its own
// arena, destroy that arena, and then read the returned strings. Do not inline them back into
// the request functions — that would make the invariant untestable again.
// ---------------------------------------------------------------------------------------

// parseGet: GET /api/tasks/get -> the task forest.
fn parseGet(alloc: std.mem.Allocator, body: []const u8) ![]Task {
    const parsed = try std.json.parseFromSliceLeaky(types.GetResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed.tasks;
}

// parseAdd: POST /api/tasks/add -> the created task the server echoed back.
fn parseAdd(alloc: std.mem.Allocator, body: []const u8) !Task {
    const parsed = try std.json.parseFromSliceLeaky(types.AddResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed.task;
}

// updateResultFrom turns a (status, body) pair into an UpdateResult. Split out of
// updateTasks purely so the 409 branch is reachable from a unit test — the CLI refetches
// immediately before every update, so no CLI invocation can produce a conflict, and the
// TUI (Tasks 18-19) is the first caller that will.
fn updateResultFrom(alloc: std.mem.Allocator, status: std.http.Status, body: []const u8) !UpdateResult {
    if (status == .conflict) return .{ .conflict = try parseConflict(alloc, body) };
    const parsed = try std.json.parseFromSliceLeaky(types.UpdateResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{ .ok = parsed.tasks };
}

// parseConflict pulls the server's fresh tasks out of a 409 body. A body that is not a
// parseable ConflictResponse yields an empty slice — a conflict the caller cannot reconcile
// from is still a conflict, and there is no better answer than "no fresh tasks". OOM
// propagates (it is not a statement about the body).
pub fn parseConflict(alloc: std.mem.Allocator, body: []const u8) ![]Task {
    const parsed = std.json.parseFromSliceLeaky(types.ConflictResponse, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return &.{},
    };
    return parsed.conflicts;
}

// parseServerError extracts the message from the server's `{"error": "..."}` body.
// Returns null when the body is not a JSON object carrying a string `error` field.
//
// LIFETIME: ParseOptions.allocate defaults to .alloc_if_needed for parseFromSlice*,
// so for an unescaped string the result is a SLICE INTO `body`, not a fresh
// allocation — it lives exactly as long as body does. This is why recordError DUPES the
// result before storing it on the Client: the body lives in a per-request arena that is
// reset long before the message is rendered. Do not store this slice directly.
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

test "parseConflict extracts the fresh tasks from a 409 body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body =
        \\{"conflicts":[{"id":"abc","content":{"title":"t","status":"todo","priority":"none","child_ids":[],"tags":[]},"meta":{"created_at":1,"updated_at":2,"version":9}}]}
    ;
    const tasks = try parseConflict(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("abc", tasks[0].id);
    try std.testing.expectEqual(@as(u64, 9), tasks[0].meta.version);
}

// The fixture above is hand-written. This one is a VERBATIM capture of a real dev-server
// response (POST /api/tasks/update with a stale expected_version), so ConflictResponse is
// checked against the server's actual wire shape rather than against our guess at it.
test "parseConflict handles a real server 409 body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body =
        \\{"conflicts":[{"id":"01KYZE7W631M7R58PDM356968X","content":{"title":"Buy birthday gift for Sam","description":"He likes hiking gear","status":"todo","priority":"medium","child_ids":[],"tags":["home","shopping"],"due_at":1786132437,"scheduled_at":1785700437},"meta":{"created_at":1785614037,"updated_at":1785614037,"completed_at":null,"version":1}}]}
    ;
    const tasks = try parseConflict(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("01KYZE7W631M7R58PDM356968X", tasks[0].id);
    try std.testing.expectEqualStrings("Buy birthday gift for Sam", tasks[0].content.title);
    try std.testing.expectEqual(@as(usize, 2), tasks[0].content.tags.len);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].meta.version);
}

// The parsed tasks must not alias the body (.alloc_always): the TUI parses out of a
// per-request arena and keeps the tasks in a different, longer-lived one.
test "parseConflict tasks do NOT alias the response body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var body_arena = std.heap.ArenaAllocator.init(a);
    const body = try std.fmt.allocPrint(
        body_arena.allocator(),
        "{{\"conflicts\":[{s}]}}",
        .{alias_task_json},
    );
    const tasks = try parseConflict(arena.allocator(), body);
    body_arena.deinit(); // the body is GONE

    try expectOutlivedBody(tasks[0]);
}

// --- non-aliasing coverage for EVERY parse site that hands tasks to a caller ------------
//
// `.allocate = .alloc_always` is the property this whole rework exists to guarantee, and it
// has to be pinned at each parse site independently: flipping any one of them back to
// .alloc_if_needed still compiles, still round-trips, and is invisible under the CLI's
// process arena. Each test below parses from a body owned by its OWN arena, destroys that
// arena, and only then reads the strings — so an aliased result reads freed memory.
//
// If you add a parse that returns tasks, add a test here too.

const alias_task_json =
    \\{"id":"01ID","content":{"title":"keep me","description":"and me","status":"todo","priority":"none","child_ids":["kid"],"tags":["tag1"]},"meta":{"created_at":1,"updated_at":2,"version":9}}
;

// Every string on the task, not just the id — .alloc_if_needed aliases all of them.
fn expectOutlivedBody(t: Task) !void {
    try std.testing.expectEqualStrings("01ID", t.id);
    try std.testing.expectEqualStrings("keep me", t.content.title);
    try std.testing.expectEqualStrings("and me", t.content.description);
    try std.testing.expectEqualStrings("kid", t.content.child_ids[0]);
    try std.testing.expectEqualStrings("tag1", t.content.tags[0]);
}

test "fetched tasks do NOT alias the response body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var body_arena = std.heap.ArenaAllocator.init(a);
    const body = try std.fmt.allocPrint(
        body_arena.allocator(),
        "{{\"state_version\":3,\"tasks\":[{s}]}}",
        .{alias_task_json},
    );
    const tasks = try parseGet(arena.allocator(), body);
    body_arena.deinit(); // the body is GONE

    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try expectOutlivedBody(tasks[0]);
}

test "the added task does NOT alias the response body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var body_arena = std.heap.ArenaAllocator.init(a);
    const body = try std.fmt.allocPrint(
        body_arena.allocator(),
        "{{\"state_version\":3,\"task\":{s}}}",
        .{alias_task_json},
    );
    const created = try parseAdd(arena.allocator(), body);
    body_arena.deinit(); // the body is GONE

    try expectOutlivedBody(created);
}

test "updateResultFrom .ok tasks do NOT alias the response body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var body_arena = std.heap.ArenaAllocator.init(a);
    const body = try std.fmt.allocPrint(
        body_arena.allocator(),
        "{{\"state_version\":3,\"tasks\":[{s}]}}",
        .{alias_task_json},
    );
    const res = try updateResultFrom(arena.allocator(), .ok, body);
    body_arena.deinit(); // the body is GONE

    try expectOutlivedBody(res.ok[0]);
}

test "parseConflict returns an empty slice for an unparseable body" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tasks = try parseConflict(arena.allocator(), "not json");
    try std.testing.expectEqual(@as(usize, 0), tasks.len);
}

test "the recorded ApiError message OUTLIVES the response body" {
    const a = std.testing.allocator;
    var c = Client{ .io = undefined, .allocator = a, .config = undefined };
    defer c.clearError(a);

    var body_arena = std.heap.ArenaAllocator.init(a);
    const body = try body_arena.allocator().dupe(u8, "{\"error\":\"rate limited\"}");
    try c.recordError(a, 429, body);
    body_arena.deinit(); // the body is GONE

    const e = c.lastError().?;
    try std.testing.expectEqual(@as(u16, 429), e.code);
    try std.testing.expectEqualStrings("rate limited", e.message);
}

test "recordError falls back to a default message for an unparseable body" {
    const a = std.testing.allocator;
    var c = Client{ .io = undefined, .allocator = a, .config = undefined };
    defer c.clearError(a);
    try c.recordError(a, 413, "<html>");
    try std.testing.expectEqual(@as(u16, 413), c.lastError().?.code);
    try std.testing.expect(c.lastError().?.message.len > 0);
}

// updateTasks' 409 branch: a conflict must come back as DATA carrying the server's fresh
// tasks, never as an error. This is the TUI's whole conflict path.
test "updateResultFrom maps a 409 to .conflict with the server's fresh tasks" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body =
        \\{"conflicts":[{"id":"abc","content":{"title":"theirs","status":"todo","priority":"none","child_ids":[],"tags":[]},"meta":{"created_at":1,"updated_at":2,"version":9}}]}
    ;
    const res = try updateResultFrom(arena.allocator(), .conflict, body);
    switch (res) {
        .ok => return error.TestExpectedConflict,
        .conflict => |tasks| {
            try std.testing.expectEqual(@as(usize, 1), tasks.len);
            try std.testing.expectEqualStrings("theirs", tasks[0].content.title);
            try std.testing.expectEqual(@as(u64, 9), tasks[0].meta.version);
        },
    }
}

test "updateResultFrom maps a 200 to .ok with the echoed tasks" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body =
        \\{"state_version":7,"tasks":[{"id":"abc","content":{"title":"mine","status":"done","priority":"none","child_ids":[],"tags":[]},"meta":{"created_at":1,"updated_at":2,"version":3}}]}
    ;
    const res = try updateResultFrom(arena.allocator(), .ok, body);
    switch (res) {
        .conflict => return error.TestUnexpectedConflict,
        .ok => |tasks| {
            try std.testing.expectEqual(@as(usize, 1), tasks.len);
            try std.testing.expectEqualStrings("mine", tasks[0].content.title);
        },
    }
}

// A conflict whose body we cannot parse is still a conflict — it must not degrade into
// `.ok` (which would let the caller believe the write landed).
test "updateResultFrom still reports .conflict when the 409 body is unparseable" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const res = try updateResultFrom(arena.allocator(), .conflict, "<html>");
    try std.testing.expectEqual(@as(usize, 0), res.conflict.len);
}

// Guards the ok_statuses list itself: drop .conflict and every 409 would be routed
// through fail() as a generic server error, never reaching updateResultFrom.
test "updateTasks accepts 409 as an outcome rather than an error" {
    var saw_conflict = false;
    for (Client.update_statuses) |s| {
        if (s == .conflict) saw_conflict = true;
    }
    try std.testing.expect(saw_conflict);
}

// Both halves run under std.testing.allocator, so a leaked first message or a leaked
// parse scratch buffer fails the BUILD STEP.
test "recording twice frees the first message; clearError is idempotent" {
    const a = std.testing.allocator;
    var c = Client{ .io = undefined, .allocator = a, .config = undefined };
    defer c.clearError(a);
    try c.recordError(a, 429, "{\"error\":\"rate limited\"}");
    try c.recordError(a, 404, "{\"error\":\"not found\"}");
    try std.testing.expectEqual(@as(u16, 404), c.lastError().?.code);
    try std.testing.expectEqualStrings("not found", c.lastError().?.message);
    c.clearError(a);
    try std.testing.expect(c.lastError() == null);
    c.clearError(a); // idempotent
    try std.testing.expect(c.lastError() == null);
}

// An escaped JSON string is the one case where parseServerError allocates rather than
// slicing into the body; recordError's scratch arena has to absorb that.
test "recordError unescapes without leaking the parse scratch" {
    const a = std.testing.allocator;
    var c = Client{ .io = undefined, .allocator = a, .config = undefined };
    defer c.clearError(a);
    try c.recordError(a, 400, "{\"error\":\"quota \\\"hard\\\" limit\"}");
    try std.testing.expectEqualStrings("quota \"hard\" limit", c.lastError().?.message);
}

test "defaultMessage covers the statuses Stage 0 introduced" {
    try std.testing.expectEqualStrings("rate limited; try again shortly", defaultMessage(429));
    try std.testing.expectEqualStrings("request too large", defaultMessage(413));
    try std.testing.expectEqualStrings("access denied (check your secret)", defaultMessage(403));
    try std.testing.expectEqualStrings("unexpected response from server", defaultMessage(500));
}
