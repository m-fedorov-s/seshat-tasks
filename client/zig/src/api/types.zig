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
