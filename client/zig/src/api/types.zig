const std = @import("std");
const Task = @import("../core/task.zig").Task;

pub const AddTaskRequest = struct {
    title: []const u8,
    priority: i32,
};

pub const DeleteTaskRequest = struct {
    title: []const u8,
};
