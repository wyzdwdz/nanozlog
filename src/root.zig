const std = @import("std");
const testing = std.testing;

var ptr_log: ?*NanoZlog = null;

const NanoZlog = @import("nanozlog.zig").NanoZlog;

const LogQFullCBFn = NanoZlog.LogQFullCBFn;
const PrintMetaCBFn = NanoZlog.PrintMetaFn;

/// Log level enum.
pub const Level = NanoZlog.Level;
/// Metadata for a log message.
pub const Meta = NanoZlog.Meta;

/// Errors returned by NanoZlog functions.
pub const Error = error{
    LoggerAlreadyInitialized,
    LoggerInitializationFailed,
    LoggerIsNotInitialized,
};

/// Configuration options for NanoZlog.
///
/// Includes the following fields:
/// - `min_level`: Minimum log level to record (defaults to `.debug` in Debug mode, else `.info`).
/// - `flush_delay`: Nanoseconds to wait before auto-flushing the log buffer (defaults to 3,000,000,000 ns).
/// - `polling_interval`: Nanoseconds between polling intervals for the background thread (defaults to 1,000,000,000 ns).
/// - `is_localtime`: Whether to format timestamps in local time instead of UTC (defaults to `false`).
/// - `is_block`: Whether a logging call should block when the log queue is full (defaults to `false`).
/// - `log_q_full_cb`: A custom callback function to be invoked when the log queue is full (defaults to empty function).
/// - `log_q_full_cb_args`: An anyopaque pointer used as log_q_full_cb callback function args (defaults to undefined).
/// - `print_meta_cb`: A custom callback function to format and print log metadata. (defaults to builtin function).
pub const Config = NanoZlog.Config;

/// Initializes the global NanoZlog instance.
pub fn initNanoZlog(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    config: Config,
) Error!void {
    if (ptr_log) |_| {
        return Error.LoggerAlreadyInitialized;
    } else {
        const ptr_nanozlog = allocator.create(NanoZlog) catch
            return Error.LoggerInitializationFailed;
        ptr_nanozlog.* = NanoZlog.init(io, allocator, writer, config) catch
            return Error.LoggerInitializationFailed;
        ptr_nanozlog.*.start() catch
            return Error.LoggerInitializationFailed;

        ptr_log = ptr_nanozlog;
    }
}

/// Deinitializes the global NanoZlog instance and frees resources.
pub fn deinitNanoZlog(allocator: std.mem.Allocator) void {
    if (ptr_log) |logger| {
        logger.deinit();
        allocator.destroy(logger);
        ptr_log = null;
    }
}

test "init and deinit NanoZlog" {
    var buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    try initNanoZlog(testing.io, testing.allocator, &discarding.writer, .{});
    try testing.expect(ptr_log != null);
    try testing.expect(ptr_log.?._config.is_block == false);
    deinitNanoZlog(testing.allocator);
    try testing.expect(ptr_log == null);
}

/// Deinitializes the thread-local buffer used by NanoZlog for the current thread.
pub fn deinitThreadBuffer() void {
    NanoZlog.deinitThreadBuffer();
}

fn LogId(comptime src: std.builtin.SourceLocation) type {
    return struct {
        const _src = src;
        var log_id: u32 = 0;
        var limit_ns: i64 = 0;
    };
}

fn log(
    comptime message_level: Level,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const S = LogId(src);

    if (ptr_log) |logger| {
        const tsc = logger.rdtsc();
        logger.log(tsc, &S.log_id, src, message_level, format, args) catch {};
    }
}

test "log" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    const a = 5;
    try initNanoZlog(testing.io, testing.allocator, &fixed, .{});
    log(.debug, @src(), "Test log {d}", .{a});
    deinitNanoZlog(testing.allocator);
    try testing.expectStringEndsWith(buffer[0..fixed.end], "Test log 5\n");
}

fn logi(
    comptime min_interval: i64,
    comptime message_level: Level,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const S = LogId(src);

    if (ptr_log) |logger| {
        const tsc = logger.rdtsc();
        const ns = logger.tsc2ns(tsc);

        if (ns < S.limit_ns) return;
        S.limit_ns = ns + min_interval;
        logger.log(tsc, &S.log_id, src, message_level, format, args) catch {};
    }
}

test "logi" {
    var buffer: [51200]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    const a = 10;
    try initNanoZlog(testing.io, testing.allocator, &fixed, .{});
    for (0..100) |_| {
        logi(100_000_000_000, .debug, @src(), "Test log {d}", .{a});
    }
    deinitNanoZlog(testing.allocator);
    const written_logs = buffer[0..fixed.end];
    const actual_log_count = std.mem.count(u8, written_logs, "Test log");
    try testing.expectEqual(1, actual_log_count);
}

/// Logs a message with trace level.
pub fn trace(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.trace, src, format, args);
}

/// Logs a message with trace level, at most once per `min_interval` nanoseconds.
pub fn tracei(
    comptime min_interval: i64,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logi(min_interval, .trace, src, format, args);
}

/// Logs a message with debug level.
pub fn debug(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.debug, src, format, args);
}

/// Logs a message with debug level, at most once per `min_interval` nanoseconds.
pub fn debugi(
    comptime min_interval: i64,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logi(min_interval, .debug, src, format, args);
}

/// Logs a message with info level.
pub fn info(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.info, src, format, args);
}

/// Logs a message with info level, at most once per `min_interval` nanoseconds.
pub fn infoi(
    comptime min_interval: i64,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logi(min_interval, .info, src, format, args);
}

/// Logs a message with warn level.
pub fn warn(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.warn, src, format, args);
}

/// Logs a message with warn level, at most once per `min_interval` nanoseconds.
pub fn warni(
    comptime min_interval: i64,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logi(min_interval, .warn, src, format, args);
}

/// Logs a message with error level.
pub fn err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.err, src, format, args);
}

/// Logs a message with error level, at most once per `min_interval` nanoseconds.
pub fn erri(
    comptime min_interval: i64,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logi(min_interval, .err, src, format, args);
}

test {
    std.testing.refAllDecls(@This());
}

fn testPrintMeta(writer: *std.Io.Writer, meta: Meta) std.Io.Writer.Error!void {
    _ = meta;
    try writer.print("Test Print Meta CB ", .{});
}
test "printMetaCB" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    try initNanoZlog(testing.io, testing.allocator, &fixed, .{ .print_meta_cb = testPrintMeta });
    log(.debug, @src(), "Test log", .{});
    deinitNanoZlog(testing.allocator);
    try testing.expectStringStartsWith(buffer[0..fixed.end], "Test Print Meta CB");
}

test "multithread" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    try initNanoZlog(testing.io, testing.allocator, &fixed, .{});

    const Closure = struct {
        fn func() void {
            defer deinitThreadBuffer();
            var i: usize = 0;
            var m: usize = 5;
            while (i < 10) : (i += 1) {
                info(@src(), "Test thread log, i = {d}, m = {d}", .{ i, m });
                m += 5;
            }
        }
    };

    var t1 = try std.Thread.spawn(.{}, Closure.func, .{});
    var t2 = try std.Thread.spawn(.{}, Closure.func, .{});
    var t3 = try std.Thread.spawn(.{}, Closure.func, .{});

    t1.join();
    t2.join();
    t3.join();

    deinitNanoZlog(testing.allocator);

    const written_logs = buffer[0..fixed.end];

    try testing.expect(written_logs.len > 0);
    try testing.expect(fixed.end < buffer.len);

    const expected_log_count: usize = 30;
    const actual_log_count = std.mem.count(u8, written_logs, "Test thread log");
    try testing.expectEqual(expected_log_count, actual_log_count);

    var expected_i: usize = 0;
    while (expected_i < 10) : (expected_i += 1) {
        const expected_m = (expected_i + 1) * 5;

        var search_buf: [64]u8 = undefined;
        const search_str = try std.fmt.bufPrint(
            &search_buf,
            "i = {d}, m = {d}",
            .{ expected_i, expected_m },
        );

        const occurrence_count = std.mem.count(u8, written_logs, search_str);

        try testing.expectEqual(@as(usize, 3), occurrence_count);
    }
}

test "min level" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);

    try initNanoZlog(testing.io, testing.allocator, &fixed, .{ .min_level = .warn });

    debug(@src(), "Test log {d}", .{1});
    trace(@src(), "Test log {d}", .{5});
    err(@src(), "Test log {d}", .{10});
    info(@src(), "Test log {d}", .{15});
    warn(@src(), "Test log {d}", .{20});
    deinitNanoZlog(testing.allocator);

    const written_logs = buffer[0..fixed.end];
    const actual_log_count = std.mem.count(u8, written_logs, "Test log");
    try testing.expectEqual(2, actual_log_count);
}

test "dynamic string" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);

    try initNanoZlog(testing.io, testing.allocator, &fixed, .{});

    var buf: [1024]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "Dynamic String", .{});
    const n = 5;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        info(@src(), "benchmark test log {s}", .{str});
    }
    deinitNanoZlog(testing.allocator);

    const written_logs = buffer[0..fixed.end];
    try std.testing.expect(
        std.mem.indexOf(u8, written_logs, "benchmark test log Dynamic String") != null,
    );
    const count = std.mem.count(u8, written_logs, "benchmark test log Dynamic String");
    try std.testing.expectEqual(@as(usize, 5), count);
}
