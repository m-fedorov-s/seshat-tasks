const std = @import("std");

// Each file is its own anonymous module so src/shell.zig can @embedFile it: @embedFile
// cannot escape a module root, but a module can be rooted anywhere — see
// https://ziglang.org/learn/build-system/#embed-file
// REQUIRED INPUT: a missing path is `failed to check cache: '…' file_hash FileNotFound`.
const shell_files = .{
    .{ "shell_fish_completions", "../shell/fish/completions/seshat.fish" },
    .{ "shell_fish_conf_d", "../shell/fish/conf.d/seshat.fish" },
    .{ "shell_fish_functions", "../shell/fish/functions/seshat-prompt.fish" },
    .{ "shell_bash_completions", "../shell/bash/seshat.bash" },
    .{ "shell_zsh_completions", "../shell/zsh/_seshat" },
};

fn addShellFiles(b: *std.Build, m: *std.Build.Module) void {
    inline for (shell_files) |f|
        m.addAnonymousImport(f[0], .{ .root_source_file = b.path(f[1]) });
}

// DO NOT add an `if (code != 0) return null;` here: runAllowFail writes `out_code` only on
// the failure path, so reading it reads `undefined` and rejects every good result. A
// non-zero exit already arrives as error.ExitCodeFailure.
fn gitDescribe(b: *std.Build) ?[]const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "git", "describe", "--tags", "--always", "--dirty" },
        &code,
        .ignore,
    ) catch return null;
    const s = std.mem.trim(u8, out, " \t\r\n");
    return if (s.len == 0) null else s;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug info from the binary");

    // An EMPTY -Dversion is treated as absent: b.option returns a non-null empty slice,
    // which would ship `seshat \n`.
    const version = blk: {
        if (b.option([]const u8, "version", "Override the reported version string")) |v|
            if (v.len > 0) break :blk v;
        break :blk gitDescribe(b) orelse "dev";
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const exe = b.addExecutable(.{
        .name = "seshat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("vaxis", vaxis_mod);
    addShellFiles(b, exe.root_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // The test artifact is pinned to b.graph.host: a foreign-target test binary cannot be
    // run here. -Dtarget is therefore ignored by `zig build test`, which still compiles and
    // runs the full host suite — a green `test` says nothing about a cross-target build.
    // -Doptimize is not wired through either: the tests exercise Debug safety checks and
    // std.debug.assert.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });
    unit_tests.root_module.addOptions("build_options", options);
    unit_tests.root_module.addImport("vaxis", vaxis_mod);
    addShellFiles(b, unit_tests.root_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
