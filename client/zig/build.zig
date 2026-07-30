const std = @import("std");

pub fn build(b: *std.Build) void {
    // Every build is assumed to happen inside a git checkout (see the Stage 0 spec).
    // `--always` yields a bare sha when no tags exist, so no tagging policy is needed.
    // `-Dversion=` overrides for release builds. Tarball builds are out of scope and
    // backlogged in plans/todo.md.
    const version = b.option([]const u8, "version", "Override the reported version string") orelse
        std.mem.trim(u8, b.run(&.{ "git", "describe", "--tags", "--always", "--dirty" }), " \t\r\n");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "seshat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });
    // The test root is main.zig, which imports build_options — so the test artifact
    // needs the same options module or `zig build test` fails to compile.
    unit_tests.root_module.addOptions("build_options", options);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
