const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Deps
    const uuid = b.dependency("anne_uuid", .{ .target = target, .optimize = optimize }).module("anne_uuid");
    const bench = b.dependency("anne_benchmark", .{ .target = target, .optimize = optimize }).module("anne_benchmark");

    // Main mod
    const mod = b.addModule("anne_table", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "benchmark",
                .module = bench,
            },
            .{
                .name = "uuid",
                .module = uuid,
            },
        },
    });

    // Lib export
    const lib = b.addLibrary(.{
        .name = "anne_table",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Testing
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
