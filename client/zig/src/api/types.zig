const task = @import("../core/task.zig");

pub const Content = task.Content;
pub const Task = task.Task;

// GET /api/tasks/get response
pub const GetResponse = struct {
    state_version: u64,
    tasks: []Task,
};

// POST /api/tasks/add request
pub const AddRequest = struct {
    content: Content,
    parent_id: ?[]const u8 = null,
    position: ?i64 = null,
};

// POST /api/tasks/update request (atomic batch)
pub const UpdateOp = struct {
    id: []const u8,
    content: Content,
    expected_version: u64,
};
pub const UpdateRequest = struct {
    updates: []const UpdateOp,
};

// POST /api/tasks/delete request
pub const DeleteRequest = struct {
    id: []const u8,
};

// POST /api/tasks/add response
pub const AddResponse = struct {
    state_version: u64 = 0,
    task: Task,
};

// POST /api/tasks/update response
pub const UpdateResponse = struct {
    state_version: u64 = 0,
    tasks: []Task,
};

// POST /api/tasks/update 409 response. The server's optimistic-concurrency failure
// already carries the *fresh* server-side tasks (server/handlers.go: ConflictError ->
// `{"conflicts": [Task, ...]}`), so a caller can resolve a conflict without refetching —
// there is no single-task GET endpoint.
pub const ConflictResponse = struct {
    conflicts: []Task,
};
