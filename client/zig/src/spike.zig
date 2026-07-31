// Throwaway spike proving libvaxis 0.6.0's real API shapes against Zig 0.16.
// Not part of the seshat CLI — built via `zig build spike`, not `zig build`.
// See client/zig/CLAUDE.md "Zig 0.16 API notes" for what this discovered.
const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    var buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    try loop.installResizeHandler();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    while (true) {
        const ev = try loop.nextEvent();
        switch (ev) {
            .key_press => |k| if (k.matches('q', .{})) break,
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }
        const win = vx.window();
        win.clear();
        _ = win.printSegment(.{ .text = "seshat spike — press q" }, .{});
        try vx.render(tty.writer());
    }
}
