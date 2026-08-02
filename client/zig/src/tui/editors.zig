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

    // BOTH axes rotate the picker. It is drawn as `◂ value ▸`, so `←`/`→` is the
    // guess the screen invites; but a picker is also one item of a vertical field
    // list, so `↑`/`↓` is the guess the surrounding UI invites. Accepting only
    // `↑`/`↓` while drawing `◂ ▸` was reported as confusing by the project owner,
    // and there is no third meaning for either pair INSIDE an open picker to
    // conflict with — `←`/`→` fold and unfold in `.list` mode, which no open
    // editor can be in, and `.field` mode ignores them entirely.
    pub fn handle(self: *PickEditor, k: Key) void {
        if (self.len == 0) return;
        switch (k) {
            .up, .left => self.index = if (self.index == 0) self.len - 1 else self.index - 1,
            .down, .right => self.index = (self.index + 1) % self.len,
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

test "LineEditor prevBoundary walks back multi-byte continuation sequences (3-byte and 4-byte codepoints)" {
    const a = std.testing.allocator;
    // "a" (1 byte) + "€" (3 bytes) + "😀" (4 bytes) + "b" (1 byte) = 9 bytes.
    var e = try LineEditor.init(a, "a€😀b");
    defer e.deinit(a);
    try std.testing.expectEqualStrings("a€😀b", e.text());

    // .left must land exactly on codepoint boundaries, walking back over every
    // continuation byte of the wide codepoints (a single-step scan would stop short).
    try e.handle(a, .left); // skip 'b' (1 byte): cursor 9 -> 8
    try e.handle(a, .left); // skip 😀 (4 bytes, 3-iteration scan): cursor 8 -> 4
    try e.handle(a, .left); // skip €  (3 bytes, 2-iteration scan): cursor 4 -> 1
    try e.handle(a, .{ .char = 'x' });
    try std.testing.expectEqualStrings("ax€😀b", e.text());

    // Backspace across the wide codepoints from the end, one whole codepoint at a time.
    try e.handle(a, .end);
    try e.handle(a, .backspace); // removes 'b'
    try std.testing.expectEqualStrings("ax€😀", e.text());
    try e.handle(a, .backspace); // removes 😀 (4-byte scan)
    try std.testing.expectEqualStrings("ax€", e.text());
    try e.handle(a, .backspace); // removes €  (3-byte scan)
    try std.testing.expectEqualStrings("ax", e.text());
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

// The picker is drawn as `◂ value ▸` but only ever answered to `↑`/`↓`, which the
// project owner hit at a real terminal: "right and left arrows appear, but you
// need up and down — quite confusing." Both pairs now work, and the on-screen
// hint says so. This is the half of that fix that can be pinned.
test "PickEditor rotates on left/right exactly as it does on up/down" {
    var p = PickEditor{ .len = 4, .index = 0 };
    p.handle(.left);
    try std.testing.expectEqual(@as(usize, 3), p.index); // wraps backward, like .up
    p.handle(.right);
    try std.testing.expectEqual(@as(usize, 0), p.index); // wraps forward, like .down
    p.handle(.right);
    try std.testing.expectEqual(@as(usize, 1), p.index);

    // Not two independent cursors — the same motion under two names, over a
    // sequence long enough to wrap.
    var horizontal = PickEditor{ .len = 3 };
    var vertical = PickEditor{ .len = 3 };
    for ([_]Key{ .right, .right, .right, .right, .left }) |k| horizontal.handle(k);
    for ([_]Key{ .down, .down, .down, .down, .up }) |k| vertical.handle(k);
    try std.testing.expectEqual(vertical.index, horizontal.index);

    // The empty-picker guard covers the new keys too.
    var empty = PickEditor{ .len = 0 };
    empty.handle(.left);
    empty.handle(.right);
    try std.testing.expectEqual(@as(usize, 0), empty.index);
}
