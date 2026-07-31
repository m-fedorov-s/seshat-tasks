const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    up,
    down,
    left,
    right,
    enter,
    escape,
    tab,
    backspace,
    delete,
    home,
    end,
    ctrl_d,
    ctrl_u,
};

pub const LineEditor = struct {
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0, // BYTE index, always on a codepoint boundary

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !LineEditor {
        var e = LineEditor{};
        try e.buf.appendSlice(allocator, initial);
        e.cursor = e.buf.items.len;
        return e;
    }

    pub fn deinit(self: *LineEditor, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.* = undefined;
    }

    pub fn text(self: *const LineEditor) []const u8 {
        return self.buf.items;
    }

    fn nextBoundary(self: *const LineEditor, i: usize) usize {
        if (i >= self.buf.items.len) return self.buf.items.len;
        const n = std.unicode.utf8ByteSequenceLength(self.buf.items[i]) catch 1;
        return @min(i + n, self.buf.items.len);
    }

    fn prevBoundary(self: *const LineEditor, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        // Walk back over continuation bytes (10xxxxxx).
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }

    pub fn handle(self: *LineEditor, allocator: std.mem.Allocator, k: Key) !void {
        switch (k) {
            .char => |cp| {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch return;
                try self.buf.insertSlice(allocator, self.cursor, tmp[0..n]);
                self.cursor += n;
            },
            .left => self.cursor = self.prevBoundary(self.cursor),
            .right => self.cursor = self.nextBoundary(self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.buf.items.len,
            .backspace => {
                if (self.cursor == 0) return;
                const start = self.prevBoundary(self.cursor);
                try self.buf.replaceRange(allocator, start, self.cursor - start, &.{});
                self.cursor = start;
            },
            .delete => {
                if (self.cursor >= self.buf.items.len) return;
                const end = self.nextBoundary(self.cursor);
                try self.buf.replaceRange(allocator, self.cursor, end - self.cursor, &.{});
            },
            else => {},
        }
    }
};

pub const PickEditor = struct {
    len: usize,
    index: usize = 0,

    pub fn handle(self: *PickEditor, k: Key) void {
        if (self.len == 0) return;
        switch (k) {
            .up => self.index = if (self.index == 0) self.len - 1 else self.index - 1,
            .down => self.index = (self.index + 1) % self.len,
            else => {},
        }
    }
};

test "LineEditor starts prefilled with the cursor at the end" {
    const a = std.testing.allocator;
    var e = try LineEditor.init(a, "hello");
    defer e.deinit(a);
    try std.testing.expectEqualStrings("hello", e.text());
    try e.handle(a, .{ .char = '!' });
    try std.testing.expectEqualStrings("hello!", e.text());
}

test "LineEditor inserts at the cursor and backspaces before it" {
    const a = std.testing.allocator;
    var e = try LineEditor.init(a, "abc");
    defer e.deinit(a);
    try e.handle(a, .left);
    try e.handle(a, .{ .char = 'X' });
    try std.testing.expectEqualStrings("abXc", e.text());
    try e.handle(a, .backspace);
    try std.testing.expectEqualStrings("abc", e.text());
}

test "LineEditor home, end and delete" {
    const a = std.testing.allocator;
    var e = try LineEditor.init(a, "abc");
    defer e.deinit(a);
    try e.handle(a, .home);
    try e.handle(a, .delete);
    try std.testing.expectEqualStrings("bc", e.text());
    try e.handle(a, .end);
    try e.handle(a, .{ .char = 'z' });
    try std.testing.expectEqualStrings("bcz", e.text());
}

test "LineEditor backspace at the start and delete at the end are no-ops" {
    const a = std.testing.allocator;
    var e = try LineEditor.init(a, "a");
    defer e.deinit(a);
    try e.handle(a, .home);
    try e.handle(a, .backspace);
    try std.testing.expectEqualStrings("a", e.text());
    try e.handle(a, .end);
    try e.handle(a, .delete);
    try std.testing.expectEqualStrings("a", e.text());
}

test "LineEditor treats a multi-byte codepoint as one unit" {
    const a = std.testing.allocator;
    var e = try LineEditor.init(a, "");
    defer e.deinit(a);
    try e.handle(a, .{ .char = 'é' });
    try e.handle(a, .{ .char = 'ß' });
    try std.testing.expectEqualStrings("éß", e.text());
    try e.handle(a, .backspace);
    try std.testing.expectEqualStrings("é", e.text());
    try e.handle(a, .left);
    try e.handle(a, .{ .char = 'x' });
    try std.testing.expectEqualStrings("xé", e.text());
}

test "PickEditor wraps at both ends and ignores other keys" {
    var p = PickEditor{ .len = 4, .index = 0 };
    p.handle(.up);
    try std.testing.expectEqual(@as(usize, 3), p.index);
    p.handle(.down);
    try std.testing.expectEqual(@as(usize, 0), p.index);
    p.handle(.down);
    try std.testing.expectEqual(@as(usize, 1), p.index);
    p.handle(.{ .char = 'q' });
    try std.testing.expectEqual(@as(usize, 1), p.index);
}
