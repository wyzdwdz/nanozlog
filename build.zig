const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });
    const zeit_mod = zeit_dep.module("zeit");

    const queue_size = b.option(
        u32,
        "queue_size",
        "The size of the SPSC queue (default: 1MB)",
    ) orelse 1 << 20;

    const options = b.addOptions();
    options.addOption(usize, "queue_size", queue_size);
    const config_mod = options.createModule();

    const nanozlog_mod = b.addModule("nanozlog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zeit", .module = zeit_mod },
            .{ .name = "config", .module = config_mod },
        },
    });

    const mod_unit_tests = b.addTest(.{
        .root_module = nanozlog_mod,
    });

    const run_mod_unit_tests = b.addRunArtifact(mod_unit_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_unit_tests.step);

    const bench_options = b.addOptions();
    bench_options.addOption(usize, "queue_size", 1 << 25);
    const bench_config_mod = bench_options.createModule();

    const bench_nanozlog_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "zeit", .module = zeit_mod },
            .{ .name = "config", .module = bench_config_mod },
        },
    });

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "nanozlog", .module = bench_nanozlog_mod },
            },
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("benchmark", "Run benchmark");
    bench_step.dependOn(&run_bench.step);

    b.installArtifact(bench_exe);
}
