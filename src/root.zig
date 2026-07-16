const std = @import("std");
const testing = std.testing;

var ptr_log: ?*NanoZlog = null;

const NanoZlog = @import("nanozlog.zig").NanoZlog;

const LogQFullCBFn = NanoZlog.LogQFullCBFn;
const PrintMetaCBFn = NanoZlog.PrintMetaFn;

pub const Level = NanoZlog.Level;
pub const Meta = NanoZlog.Meta;

/// Errors returned by NanoZlog functions.
pub const Error = error{
    LoggerAlreadyInitialized,
    LoggerInitializationFailed,
    LoggerIsNotInitialized,
    ThreadBufferInitializationFailed,
};

pub const Config = NanoZlog.Config;

var _is_shutting_down: std.atomic.Value(bool) = .init(false);

/// Initializes the global NanoZlog instance.
pub fn initNanoZlog(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    config: Config,
) Error!void {
    if (ptr_log) |_| {
        return Error.LoggerAlreadyInitialized;
    } else {
        const ptr_nanozlog = allocator.create(NanoZlog) catch
            return Error.LoggerInitializationFailed;
        errdefer allocator.destroy(ptr_nanozlog);
        ptr_nanozlog.* = NanoZlog.init(allocator, io, writer, config) catch
            return Error.LoggerInitializationFailed;
        ptr_nanozlog.*.start() catch
            return Error.LoggerInitializationFailed;

        _is_shutting_down.store(false, .release);
        ptr_log = ptr_nanozlog;
    }
}

/// Deinitializes the global NanoZlog instance and frees resources.
pub fn deinitNanoZlog(allocator: std.mem.Allocator) void {
    if (ptr_log) |logger| {
        _is_shutting_down.store(true, .release);
        logger.deinit();
        allocator.destroy(logger);
        ptr_log = null;
    }
}

test "init deinit" {
    var buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    try initNanoZlog(testing.allocator, testing.io, &discarding.writer, .{});
    try testing.expect(ptr_log != null);
    try testing.expect(ptr_log.?._config.is_block == false);
    try testing.expectError(
        Error.LoggerAlreadyInitialized,
        initNanoZlog(testing.allocator, testing.io, &discarding.writer, .{}),
    );
    deinitNanoZlog(testing.allocator);
    try testing.expect(ptr_log == null);
}

test "_is_shutting_down" {
    var first_buffer: [4096]u8 = undefined;
    var first_fixed = std.Io.Writer.fixed(&first_buffer);

    try initNanoZlog(testing.allocator, testing.io, &first_fixed, .{});
    deinitNanoZlog(testing.allocator);
    try testing.expect(_is_shutting_down.load(.acquire));

    var second_buffer: [4096]u8 = undefined;
    var second_fixed = std.Io.Writer.fixed(&second_buffer);

    try initNanoZlog(testing.allocator, testing.io, &second_fixed, .{});
    try testing.expect(!_is_shutting_down.load(.acquire));

    _is_shutting_down.store(true, .release);
    debug(@src(), "log while shutting down", .{});
    debugi(1000, @src(), "interval log while shutting down", .{});
    debugz(@src(), "once log while shutting down", .{});
    try testing.expectEqual(@as(usize, 0), second_fixed.end);

    _is_shutting_down.store(false, .release);
    info(@src(), "log after reinit", .{});
    deinitNanoZlog(testing.allocator);

    try testing.expectStringEndsWith(second_buffer[0..second_fixed.end], "log after reinit\n");
}

test "init failure" {
    var buffer: [@sizeOf(NanoZlog)]u8 align(@alignOf(NanoZlog)) = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var writer_buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&writer_buffer);

    try testing.expectError(
        Error.LoggerInitializationFailed,
        initNanoZlog(fba.allocator(), testing.io, &discarding.writer, .{}),
    );
}

test "queue size smaller than 24 Bytes" {
    var buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    try testing.expectError(
        Error.LoggerInitializationFailed,
        initNanoZlog(testing.allocator, testing.io, &discarding.writer, .{ .queue_size = 23 }),
    );
}

/// Initializes the thread-local buffer used by NanoZlog for the current thread.
/// **Not necessary**, buffer will be initialized automatically when logging the first one in this thread.
/// This is mainly used for pre-allocating the buffer outside of performance-critical code paths to avoid latency spikes during the first log call.
pub fn initThreadBuffer() Error!void {
    if (ptr_log) |logger| {
        logger.initThreadBuffer() catch return Error.ThreadBufferInitializationFailed;
    } else {
        return Error.LoggerIsNotInitialized;
    }
}

test "thread init" {
    var buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    try initNanoZlog(testing.allocator, testing.io, &discarding.writer, .{});
    defer deinitNanoZlog(testing.allocator);
    try initThreadBuffer();
    try testing.expect(ptr_log.?._thread_buffers.items.len == 1);
}

/// Deinitializes the thread-local buffer used by NanoZlog for the current thread.
/// **Not necessary**, all buffers will be deinitialized automatically when calling `deinitNanoZlog`.
/// This is mainly used for explicitly freeing memory when a thread is about to terminate or no longer needs logging. It helps prevent memory accumulation.
pub fn deinitThreadBuffer() void {
    NanoZlog.deinitThreadBuffer();
}

test "thread deinit" {
    var buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&buffer);
    try initNanoZlog(testing.allocator, testing.io, &discarding.writer, .{});
    defer deinitNanoZlog(testing.allocator);
    try initThreadBuffer();
    deinitThreadBuffer();
    try testing.io.sleep(.fromSeconds(3), .awake);
    try testing.expect(ptr_log.?._thread_buffers.items.len == 0);
}

fn LogId(comptime src: std.builtin.SourceLocation) type {
    return struct {
        const _src = src;
        var log_id: std.atomic.Value(u32) = .init(0);
        var limit_ns: std.atomic.Value(i64) = .init(0);
        var log_once: std.atomic.Value(bool) = .init(false);
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
        if (_is_shutting_down.load(.acquire)) return;
        const tsc = logger.rdtsc();
        logger.log(tsc, &S.log_id, src, message_level, format, args);
    }
}

test "log" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    const a = 5;
    try initNanoZlog(testing.allocator, testing.io, &fixed, .{});
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
        if (_is_shutting_down.load(.acquire)) return;

        const tsc = logger.rdtsc();
        const ns = logger.tsc2ns(tsc);

        if (ns < S.limit_ns.load(.acquire)) return;
        S.limit_ns.store(ns + min_interval, .release);
        logger.log(tsc, &S.log_id, src, message_level, format, args);
    }
}

test "logi" {
    var buffer: [51200]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    const a = 10;
    try initNanoZlog(testing.allocator, testing.io, &fixed, .{});
    for (0..100) |_| {
        logi(100_000_000_000, .debug, @src(), "Test log {d}", .{a});
    }
    deinitNanoZlog(testing.allocator);
    const written_logs = buffer[0..fixed.end];
    const actual_log_count = std.mem.count(u8, written_logs, "Test log");
    try testing.expectEqual(1, actual_log_count);
}

fn logz(
    comptime message_level: Level,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const S = LogId(src);

    if (ptr_log) |logger| {
        if (_is_shutting_down.load(.acquire)) return;

        if (S.log_once.load(.acquire) == true) return;
        S.log_once.store(true, .release);

        const tsc = logger.rdtsc();
        logger.log(tsc, &S.log_id, src, message_level, format, args);
    }
}

test "logz" {
    var buffer: [51200]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    const a = 10;
    try initNanoZlog(testing.allocator, testing.io, &fixed, .{});
    for (0..100) |_| {
        logz(.debug, @src(), "Test log {d}", .{a});
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

/// Logs a message with trace level only once.
pub fn tracez(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logz(.trace, src, format, args);
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

/// Logs a message with debug level only once.
pub fn debugz(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logz(.debug, src, format, args);
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

/// Logs a message with info level only once.
pub fn infoz(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logz(.info, src, format, args);
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

/// Logs a message with warn level only once.
pub fn warnz(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logz(.warn, src, format, args);
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

/// Logs a message with error level only once.
pub fn errz(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    logz(.err, src, format, args);
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
    try initNanoZlog(testing.allocator, testing.io, &fixed, .{ .print_meta_cb = testPrintMeta });
    log(.debug, @src(), "Test log", .{});
    deinitNanoZlog(testing.allocator);
    try testing.expectStringStartsWith(buffer[0..fixed.end], "Test Print Meta CB");
}

test "multithread" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    try initNanoZlog(testing.allocator, testing.io, &fixed, .{});

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

    var f1 = try testing.io.concurrent(Closure.func, .{});
    var f2 = try testing.io.concurrent(Closure.func, .{});
    var f3 = try testing.io.concurrent(Closure.func, .{});

    _ = f1.await(testing.io);
    _ = f2.await(testing.io);
    _ = f3.await(testing.io);

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

    try initNanoZlog(testing.allocator, testing.io, &fixed, .{ .min_level = .warn });

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

    try initNanoZlog(testing.allocator, testing.io, &fixed, .{});

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

test "periodic flush" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);

    try initNanoZlog(testing.allocator, testing.io, &fixed, .{
        .flush_delay = 1_000_000_000,
        .polling_interval = 1_000_000,
    });
    defer deinitNanoZlog(testing.allocator);

    try initThreadBuffer();

    var poll_count: usize = 0;
    while (ptr_log.?._next_flush_time == std.math.maxInt(i64) and
        poll_count < 100) : (poll_count += 1)
    {
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    try testing.expect(ptr_log.?._next_flush_time != std.math.maxInt(i64));

    ptr_log.?._next_flush_time = 0;

    poll_count = 0;
    while (ptr_log.?._next_flush_time == 0 and poll_count < 100) : (poll_count += 1) {
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    try testing.expect(ptr_log.?._next_flush_time != 0);
}

test "cached bg node" {
    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);

    try initNanoZlog(testing.allocator, testing.io, &fixed, .{
        .polling_interval = 1_000_000,
    });
    defer deinitNanoZlog(testing.allocator);

    try testing.io.sleep(.fromMilliseconds(10), .awake);

    info(@src(), "future log", .{});

    const thread_buffer = ptr_log.?._thread_buffers.items[0];
    const header = thread_buffer.varq.front().?;
    header.set_tsc(std.math.maxInt(i64));

    var poll_count: usize = 0;
    while (ptr_log.?._bg_thread_buffers.items.len == 0 and poll_count < 100) : (poll_count += 1) {
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    try testing.expect(ptr_log.?._bg_thread_buffers.items.len != 0);
    try testing.expect(ptr_log.?._bg_thread_buffers.items[0].header != null);

    try testing.io.sleep(.fromMilliseconds(10), .awake);

    try testing.expect(ptr_log.?._bg_thread_buffers.items[0].header != null);
}

test "queue full" {
    const Closure = struct {
        fn onQueueFull(args: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(args));
            count.* += 1;
        }
    };

    var buffer: [4096]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    var q_full_count: usize = 0;

    try initNanoZlog(testing.allocator, testing.io, &fixed, .{
        .queue_size = 24,
        .polling_interval = 1_000_000_000,
        .log_q_full_cb = Closure.onQueueFull,
        .log_q_full_cb_args = &q_full_count,
    });

    try testing.io.sleep(.fromMilliseconds(10), .awake);

    info(@src(), "first log", .{});
    info(@src(), "second log", .{});

    try testing.expectEqual(@as(usize, 1), q_full_count);

    deinitNanoZlog(testing.allocator);

    const written_logs = buffer[0..fixed.end];
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written_logs, "first log"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, written_logs, "second log"));

    var default_callback_buffer: [4096]u8 = undefined;
    var default_callback_fixed = std.Io.Writer.fixed(&default_callback_buffer);

    try initNanoZlog(testing.allocator, testing.io, &default_callback_fixed, .{
        .queue_size = 24,
        .polling_interval = 1_000_000_000,
    });
    defer deinitNanoZlog(testing.allocator);

    try testing.io.sleep(.fromMilliseconds(10), .awake);

    info(@src(), "first default callback log", .{});
    info(@src(), "second default callback log", .{});
}
