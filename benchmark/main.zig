const std = @import("std");
const nanozlog = @import("nanozlog");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var w_buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&w_buffer);
    const writer = &discarding.writer;

    var has_drop: bool = false;

    try nanozlog.initNanoZlog(allocator, io, writer, .{
        .queue_size = 1 << 24,
        .log_q_full_cb = handleFull,
        .log_q_full_cb_args = @ptrCast(&has_drop),
    });
    defer nanozlog.deinitNanoZlog(allocator);

    nanozlog.info(@src(), "Benchmark started Warm-Up", .{});

    {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const n: usize = 100_000;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            nanozlog.info(@src(), "benchmark test log {s}", .{"Static String"});
        }
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1000.0;
        std.debug.print("Static String:\n" ++
            "Logged {d} messages in {d:.3} microseconds. {d:.0} msg/s. {d:.3} ns/msg\n" ++
            "has_drop: {}\n\n", .{
            n,
            elapsed,
            @as(f64, @floatFromInt(n)) / elapsed * 1_000_000,
            elapsed * 1000.0 / n,
            has_drop,
        });
    }

    {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const n: usize = 100_000;
        var i: i32 = 0;

        var buf: [1024]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "Dynamic String", .{});

        while (i < n) : (i += 1) {
            nanozlog.info(@src(), "benchmark test log {s}", .{str});
        }
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1000.0;
        std.debug.print("Dynamic String:\n" ++
            "Logged {d} messages in {d:.3} microseconds. {d:.0} msg/s. {d:.3} ns/msg\n" ++
            "has_drop: {}\n\n", .{
            n,
            elapsed,
            @as(f64, @floatFromInt(n)) / elapsed * 1_000_000,
            elapsed * 1000.0 / n,
            has_drop,
        });
    }

    {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const n: usize = 100_000;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            nanozlog.info(@src(), "benchmark test log {d}", .{i});
        }
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1000.0;
        std.debug.print("Single Integer:\n" ++
            "Logged {d} messages in {d:.3} microseconds. {d:.0} msg/s. {d:.3} ns/msg\n" ++
            "has_drop: {}\n\n", .{
            n,
            elapsed,
            @as(f64, @floatFromInt(n)) / elapsed * 1_000_000,
            elapsed * 1000.0 / n,
            has_drop,
        });
    }

    {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const n: usize = 100_000;
        var i: i32 = 0;
        var a: i32 = 5;
        while (i < n) : (i += 1) {
            nanozlog.info(@src(), "benchmark test log {d} {d}", .{ i, a });
            a += 5;
        }
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1000.0;
        std.debug.print("Two Integers:\n" ++
            "Logged {d} messages in {d:.3} microseconds. {d:.0} msg/s. {d:.3} ns/msg\n" ++
            "has_drop: {}\n\n", .{
            n,
            elapsed,
            @as(f64, @floatFromInt(n)) / elapsed * 1_000_000,
            elapsed * 1000.0 / n,
            has_drop,
        });
    }

    {
        const start = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        const n: usize = 100_000;
        var i: i32 = 0;
        var a: f64 = 5.0;
        while (i < n) : (i += 1) {
            nanozlog.info(@src(), "benchmark test log {d}", .{a});
            a += 5.0;
        }
        const end = std.Io.Timestamp.now(io, .awake).toNanoseconds();

        const elapsed = @as(f64, @floatFromInt(end - start)) / 1000.0;
        std.debug.print("Single Double:\n" ++
            "Logged {d} messages in {d:.3} microseconds. {d:.0} msg/s. {d:.3} ns/msg\n" ++
            "has_drop: {}\n\n", .{
            n,
            elapsed,
            @as(f64, @floatFromInt(n)) / elapsed * 1_000_000,
            elapsed * 1000.0 / n,
            has_drop,
        });
    }
}

fn handleFull(args: *anyopaque) void {
    const has_drop_ptr: *bool = @ptrCast(@alignCast(args));
    has_drop_ptr.* = true;
}
