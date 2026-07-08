const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });
    const zeit_mod = zeit_dep.module("zeit");

    const nanozlog_mod = b.addModule("nanozlog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zeit", .module = zeit_mod },
        },
    });

    const mod_unit_tests = b.addTest(.{
        .root_module = nanozlog_mod,
    });

    const run_mod_unit_tests = b.addRunArtifact(mod_unit_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_unit_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "nanozlog", .module = nanozlog_mod },
            },
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("benchmark", "Run benchmark");
    bench_step.dependOn(&run_bench.step);

    b.installArtifact(bench_exe);
}
