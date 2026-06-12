const std = @import("std");

pub const Task = struct {
    id: []const u8 = "",
    title: []const u8,
    priority: i32 = 0,
    status: Status = .todo,

    pub const Status = enum {
        todo,
        done,
    };

    pub fn deinit(self: Task, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
    }
};
