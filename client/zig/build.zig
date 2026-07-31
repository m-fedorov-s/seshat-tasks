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

    const vaxis_dep = b.dependency("vaxis", .{ .target = b.graph.host, .optimize = .Debug });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const exe = b.addExecutable(.{
        .name = "seshat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("vaxis", vaxis_mod);

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
    unit_tests.root_module.addImport("vaxis", vaxis_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `src/spike.zig` is a throwaway probe of the libvaxis API — kept out of the
    // main `seshat` binary/tests so it can't silently become the CLI (see
    // client/zig/CLAUDE.md "Zig 0.16 API notes"). Run it with `zig build spike`;
    // it needs a real TTY, so it isn't wired into `test` or the default install.
    const spike_exe = b.addExecutable(.{
        .name = "spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike.zig"),
            .target = b.graph.host,
        }),
    });
    spike_exe.root_module.addImport("vaxis", vaxis_mod);

    const run_spike = b.addRunArtifact(spike_exe);
    const spike_step = b.step("spike", "Run the libvaxis spike (needs a real terminal)");
    spike_step.dependOn(&run_spike.step);
}
