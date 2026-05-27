const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "app_name", "top-q");

    const exe = b.addExecutable(.{
        .name = switch (target.result.os.tag) {
            .macos => "top-q-macos",
            else => "top-q",
        },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run top-q");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");

    // utils.zig embedded tests (RingBuffer, formatters)
    const utils_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(utils_tests).step);

    // tests/procsrc_linux_test.zig — runs only on Linux targets.
    // We expose the whole src/ tree via src/lib.zig so the test can reach
    // internal modules without juggling separate Zig modules.
    if (target.result.os.tag == .linux) {
        const top_q_lib = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        const linux_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/procsrc_linux_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "top-q", .module = top_q_lib },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(linux_tests).step);
    }
}
