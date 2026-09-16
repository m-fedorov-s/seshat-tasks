//! The shell-integration files, embedded at build time from `client/shell/` — the single
//! source of truth for them. All five are a REQUIRED BUILD INPUT: delete one and `zig build`
//! fails with `error: failed to check cache: '…' file_hash FileNotFound`. Contents are owned
//! by the Stage 3 (c) spec; the names below are module names, not paths (see `build.zig`).

const std = @import("std");

pub const fish_completions = @embedFile("shell_fish_completions");
pub const fish_conf_d = @embedFile("shell_fish_conf_d");
pub const fish_functions = @embedFile("shell_fish_functions");
pub const bash_completions = @embedFile("shell_bash_completions");
pub const zsh_completions = @embedFile("shell_zsh_completions");

test "embedded shell files are non-empty" {
    try std.testing.expect(fish_completions.len > 0);
    try std.testing.expect(fish_conf_d.len > 0);
    try std.testing.expect(fish_functions.len > 0);
    try std.testing.expect(bash_completions.len > 0);
    try std.testing.expect(zsh_completions.len > 0);
}

// A drift alarm: the completions are hand-written, so nothing else makes them track the
// flag tables. Greps the `-a <subcommand>` entry, not the description.
test "the fish completion mentions every subcommand" {
    const subcommands = [_][]const u8{
        "-a show",   "-a tui",  "-a add",         "-a update",
        "-a delete", "-a done", "-a completions", "-a init",
    };
    for (subcommands) |entry| {
        if (std.mem.indexOf(u8, fish_completions, entry) == null) {
            std.debug.print("fish completion has no `{s}` entry\n", .{entry});
            return error.SubcommandMissingFromCompletion;
        }
    }
}
