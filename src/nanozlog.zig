const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const zeit = @import("zeit");

const TscNs = @import("tscns.zig").TscNs;
const SpscVarQueue = @import("spsc.zig").SpscVarQueue;

pub const NanoZlog = struct {
    const Self = @This();

    pub const FormatToFn = *const fn (data: []const u8, writer: *std.Io.Writer) anyerror!void;
    pub const PrintMetaFn = *const fn (writer: *std.Io.Writer, meta: Meta) std.Io.Writer.Error!void;

    pub const Meta = struct {
        timestamp: i64,
        year: i32,
        month: u5,
        day: u5,
        hour: u5,
        minute: u6,
        second: u6,
        millisecond: u10,
        microsecond: u10,
        nanosecond: u10,
        src: std.builtin.SourceLocation,
        level: Level,
        thread_id: std.Thread.Id,
    };

    pub const LogQFullCBFn = *const fn (args: *anyopaque) void;
    fn emptyFn(_: *anyopaque) void {}

    threadlocal var thread_buffer: ?*ThreadBuffer = null;

    _allocator: std.mem.Allocator,
    _io: std.Io,
    _writer: *std.Io.Writer,

    _timezone: zeit.TimeZone,

    _log_infos: std.ArrayList(StaticLogInfo) = .empty,
    _bg_log_infos: std.ArrayList(StaticLogInfo) = .empty,
    _log_infos_mutex: std.Io.Mutex = .init,

    _thread_buffers: std.ArrayList(*ThreadBuffer) = .empty,
    _bg_thread_buffers: std.ArrayList(HeapNode) = .empty,
    _buffer_mutex: std.Io.Mutex = .init,

    _polling_worker: ?std.Io.Future(void) = null,
    _is_polling: std.atomic.Value(bool) = .init(false),

    _tscns: TscNs,

    _log_q_full_cb: LogQFullCBFn = &emptyFn,
    _log_q_full_cb_args: *anyopaque = undefined,

    _print_meta_cb: PrintMetaFn = &defaultPrintMeta,

    _next_flush_time: i64 = std.math.maxInt(i64),

    _config: Config = .{},

    pub const Level = enum {
        err,
        warn,
        info,
        debug,
        trace,
    };

    const ThreadBuffer = struct {
        varq: SpscVarQueue,
        should_deinit: std.atomic.Value(bool) = .init(false),
        thread_id: std.Thread.Id,

        pub fn init(allocator: std.mem.Allocator, queue_size: u32) !ThreadBuffer {
            return .{
                .varq = try .init(allocator, queue_size),
                .thread_id = std.Thread.getCurrentId(),
            };
        }

        pub fn deinit(self: ThreadBuffer) void {
            self.varq.deinit();
        }
    };

    const HeapNode = struct {
        tb: *ThreadBuffer,
        header: ?*SpscVarQueue.MsgHeader = null,

        pub fn init(buffer: *ThreadBuffer) HeapNode {
            return .{ .tb = buffer };
        }
    };

    const StaticLogInfo = struct {
        func: FormatToFn,
        src: std.builtin.SourceLocation,
        message_level: Level,
    };

    pub const Config = struct {
        min_level: Level = if (builtin.mode == .Debug) .debug else .info,
        queue_size: u32 = 1 << 20,
        flush_delay: i64 = 3_000_000_000,
        polling_interval: i64 = 1_000_000_000,
        is_localtime: bool = false,
        is_block: bool = false,
        log_q_full_cb: LogQFullCBFn = &emptyFn,
        log_q_full_cb_args: *anyopaque = undefined,
        print_meta_cb: PrintMetaFn = &defaultPrintMeta,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        writer: *std.Io.Writer,
        config: Config,
    ) !Self {
        return .{
            ._allocator = allocator,
            ._io = io,
            ._timezone = if (config.is_localtime) try zeit.local(allocator, io, .{}) else zeit.utc,
            ._writer = writer,
            ._tscns = try .init(io, .{}),
            ._config = config,
            ._log_q_full_cb = config.log_q_full_cb,
            ._log_q_full_cb_args = config.log_q_full_cb_args,
            ._print_meta_cb = config.print_meta_cb,
        };
    }

    pub fn deinit(self: *Self) void {
        deinitThreadBuffer();

        self._timezone.deinit();

        self._is_polling.store(false, .release);
        if (self._polling_worker) |*worker| {
            _ = worker.await(self._io);
        }
        self._writer.flush() catch {};

        for (self._thread_buffers.items) |buffer| {
            buffer.deinit();
            self._allocator.destroy(buffer);
        }
        for (self._bg_thread_buffers.items) |buffer| {
            buffer.tb.deinit();
            self._allocator.destroy(buffer.tb);
        }

        self._log_infos.deinit(self._allocator);
        self._bg_log_infos.deinit(self._allocator);
        self._thread_buffers.deinit(self._allocator);
        self._bg_thread_buffers.deinit(self._allocator);
    }

    pub fn initThreadBuffer(self: *Self) !void {
        try self.preallocate();
    }

    pub fn deinitThreadBuffer() void {
        if (thread_buffer) |buffer| {
            buffer.should_deinit.store(true, .release);
            thread_buffer = null;
        }
    }

    pub fn start(self: *Self) !void {
        try self.initDummyBgLogInfos();
        self._is_polling.store(true, .release);
        self._polling_worker = try self._io.concurrent(Self.pollingWorker, .{self});
    }

    pub fn rdtsc(self: Self) i64 {
        return self._tscns.rdtsc();
    }

    pub fn tsc2ns(self: *Self, tsc: i64) i64 {
        return self._tscns.tsc2ns(tsc);
    }

    pub fn rdns(self: *Self) i64 {
        return self._tscns.rdns();
    }

    pub fn log(
        self: *Self,
        tsc: i64,
        log_id: *u32,
        comptime src: std.builtin.SourceLocation,
        comptime message_level: Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (@intFromEnum(message_level) > @intFromEnum(self._config.min_level)) return;

        const Args = @TypeOf(args);

        if (log_id.* == 0) {
            self.registerLogInfo(
                log_id,
                generateFormatTo(Args, format),
                src,
                message_level,
            ) catch |err| {
                std.debug.print("[NanoZlog] Failed to register log info: {}\n", .{err});
                return;
            };
        }

        const alloc_size = @sizeOf(i64) + getArgsSize(args);
        var q_full_cb = true;

        while (true) {
            const header_opt = self.allocMsg(@intCast(alloc_size), q_full_cb) catch |err| {
                std.debug.print("[NanoZlog] Failed to allocate log message: {}\n", .{err});
                return;
            };

            if (header_opt) |header| {
                header.log_id = log_id.*;

                header.set_tsc(tsc);

                const data = @as([*]u8, @ptrCast(header)) + @sizeOf(@TypeOf(header.*));
                encodeArgs(data[@sizeOf(i64)..alloc_size], args);

                header.push(@intCast(alloc_size));
                break;
            }

            q_full_cb = false;

            if (!self._config.is_block) {
                break;
            }
        }
    }

    fn initDummyBgLogInfos(self: *Self) !void {
        const dummies = [_]StaticLogInfo{
            .{ .func = undefined, .src = @src(), .message_level = .trace },
            .{ .func = undefined, .src = @src(), .message_level = .debug },
            .{ .func = undefined, .src = @src(), .message_level = .info },
            .{ .func = undefined, .src = @src(), .message_level = .warn },
            .{ .func = undefined, .src = @src(), .message_level = .err },
        };

        try self._bg_log_infos.appendSlice(self._allocator, &dummies);
    }

    fn preallocate(self: *Self) !void {
        if (thread_buffer == null) {
            const ptr_thread_buffer = try self._allocator.create(ThreadBuffer);
            ptr_thread_buffer.* = try ThreadBuffer.init(self._allocator, self._config.queue_size);
            thread_buffer = ptr_thread_buffer;

            try self._buffer_mutex.lock(self._io);
            defer self._buffer_mutex.unlock(self._io);
            try self._thread_buffers.append(self._allocator, ptr_thread_buffer);
        }
    }

    fn registerLogInfo(
        self: *Self,
        log_id: *u32,
        comptime func: FormatToFn,
        comptime src: std.builtin.SourceLocation,
        comptime message_level: Level,
    ) !void {
        try self._log_infos_mutex.lock(self._io);
        defer self._log_infos_mutex.unlock(self._io);

        log_id.* = @intCast(self._log_infos.items.len + self._bg_log_infos.items.len);

        try self._log_infos.append(self._allocator, .{
            .func = func,
            .src = src,
            .message_level = message_level,
        });
    }

    fn pollingWorker(self: *Self) void {
        while (self._is_polling.load(.acquire)) {
            const before = self._tscns.rdns();

            self.poll(false) catch |err| {
                std.debug.print(
                    "[NanoZlog] Backend polling worker encountered an error: {}\n",
                    .{err},
                );
                return;
            };

            const delay = self._tscns.rdns() - before;
            if (delay < self._config.polling_interval) {
                self._io.sleep(
                    .fromNanoseconds(self._config.polling_interval - delay),
                    .awake,
                ) catch |err| {
                    std.debug.print("[NanoZlog] Backend polling worker sleep failed: {}\n", .{err});
                    return;
                };
            }
        }

        self.poll(true) catch |err| {
            std.debug.print("[NanoZlog] Backend polling worker encountered an error: {}\n", .{err});
            return;
        };
    }

    fn generateFormatTo(comptime Args: type, comptime format: []const u8) FormatToFn {
        const Closure = struct {
            fn formatTo(data: []const u8, writer: *std.Io.Writer) !void {
                var args: Args = undefined;

                var idx: usize = 0;

                const type_info = @typeInfo(Args);

                const fields_info = type_info.@"struct".fields;

                inline for (fields_info) |field| {
                    if (field.is_comptime) continue;

                    const T = field.type;
                    const info = @typeInfo(T);

                    switch (info) {
                        .void => {},
                        .float, .int, .bool, .@"enum", .error_set => {
                            const size = @sizeOf(T);
                            const ptr: *align(1) const T = @ptrCast(data[idx..].ptr);
                            @field(args, field.name) = ptr.*;
                            idx += size;
                        },
                        .pointer => |p| {
                            if (p.size == .slice and p.child == u8) {
                                const size = @sizeOf(usize);
                                const ptr: *align(1) const usize = @ptrCast(data[idx..].ptr);
                                const len = ptr.*;
                                idx += size;

                                @field(args, field.name).len = len;
                                @field(args, field.name).ptr = @constCast(data[idx..].ptr);
                                idx += len;
                            } else if (p.size == .one) {
                                const size = @sizeOf(T);
                                const ptr: *align(1) const T = @ptrCast(data[idx..].ptr);
                                @field(args, field.name) = ptr.*;
                                idx += size;
                            } else unreachable;
                        },
                        else => unreachable,
                    }
                }

                try writer.print(format ++ "\n", args);
            }
        };

        return Closure.formatTo;
    }

    fn getArgsSize(args: anytype) usize {
        var size: usize = 0;

        const Args = @TypeOf(args);
        const type_info = @typeInfo(Args);

        if (type_info != .@"struct") {
            @compileError("expected tuple or struct argument, found " ++ @typeName(Args));
        }

        const fields_info = type_info.@"struct".fields;

        inline for (fields_info) |field| {
            if (field.is_comptime) continue;

            const T = field.type;
            const info = @typeInfo(T);

            const val = @field(args, field.name);

            switch (info) {
                .void => {},
                .float, .int, .bool, .@"enum", .error_set => size += @sizeOf(T),
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        size += @sizeOf(usize) + val.len;
                    } else if (p.size == .one) {
                        size += @sizeOf(T);
                    } else {
                        @compileError("Dangerous Pointer: " ++ @typeName(T) ++
                            ". Only string slices ([]const u8) or single-item pointers " ++
                            "are allowed for zero-allocation logging.");
                    }
                },
                .@"struct", .array, .@"union", .optional => {
                    @compileError("Complex Type Rejected: " ++ @typeName(T) ++
                        " may trigger hidden memory allocation or deep copies.");
                },
                else => {
                    @compileError("Invalid Type for Logging: " ++ @typeName(T) ++
                        ". You cannot log compile-time or language-internal structures.");
                },
            }
        }

        return size;
    }

    fn encodeArgs(out: []u8, args: anytype) void {
        var idx: usize = 0;

        const Args = @TypeOf(args);
        const type_info = @typeInfo(Args);

        const fields_info = type_info.@"struct".fields;

        inline for (fields_info) |field| {
            if (field.is_comptime) continue;

            const T = field.type;
            const info = @typeInfo(T);

            const val = @field(args, field.name);

            switch (info) {
                .void => {},
                .float, .int, .bool, .@"enum", .error_set => {
                    const size = @sizeOf(T);
                    const ptr: *align(1) T = @ptrCast(out[idx..].ptr);
                    ptr.* = val;
                    idx += size;
                },
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        const ptr: *align(1) usize = @ptrCast(out[idx..].ptr);
                        ptr.* = val.len;
                        idx += @sizeOf(usize);

                        @memcpy(out[idx .. idx + val.len], val);
                        idx += val.len;
                    } else if (p.size == .one) {
                        const size = @sizeOf(T);
                        const ptr: *align(1) T = @ptrCast(out[idx..].ptr);
                        ptr.* = val;
                        idx += size;
                    } else unreachable;
                },
                else => unreachable,
            }
        }
    }

    fn poll(self: *Self, force_flush: bool) !void {
        self._tscns.calibrate();
        const tsc = self._tscns.rdtsc();

        if (self._log_infos.items.len != 0) {
            try self._log_infos_mutex.lock(self._io);
            defer self._log_infos_mutex.unlock(self._io);
            try self._bg_log_infos.appendSlice(self._allocator, self._log_infos.items);
            self._log_infos.clearAndFree(self._allocator);
        }

        if (self._thread_buffers.items.len != 0) {
            try self._buffer_mutex.lock(self._io);
            defer self._buffer_mutex.unlock(self._io);
            for (self._thread_buffers.items) |buffer| {
                try self._bg_thread_buffers.append(self._allocator, HeapNode.init(buffer));
            }
            self._thread_buffers.clearAndFree(self._allocator);
        }

        var i: usize = 0;
        while (i < self._bg_thread_buffers.items.len) {
            var node = &self._bg_thread_buffers.items[i];
            if (node.header) |_| {
                i += 1;
                continue;
            }
            node.header = node.tb.varq.front();
            if (node.header == null and node.tb.should_deinit.load(.acquire)) {
                node.tb.deinit();
                self._allocator.destroy(node.tb);
                _ = self._bg_thread_buffers.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (self._bg_thread_buffers.items.len == 0) return;

        i = self._bg_thread_buffers.items.len / 2 + 1;
        while (i > 0) {
            i -= 1;
            self.adjustHeap(i);
        }

        while (true) {
            const h = self._bg_thread_buffers.items[0].header;
            if (h == null or h.?.log_id >= self._bg_log_infos.items.len) break else {
                const h_t = h.?.get_tsc();
                if (h_t >= tsc) break;
            }
            const tb = self._bg_thread_buffers.items[0].tb;
            try self.handleLog(tb.thread_id, h.?);
            tb.varq.pop();
            self._bg_thread_buffers.items[0].header = tb.varq.front();
            self.adjustHeap(0);
        }

        if (force_flush) {
            try self._writer.flush();
            return;
        }

        const now = self._tscns.tsc2ns(tsc);
        if (now > self._next_flush_time) {
            try self._writer.flush();
        } else if (self._next_flush_time == std.math.maxInt(i64)) {
            self._next_flush_time = now + self._config.flush_delay;
        }
    }

    fn defaultPrintMeta(writer: *std.Io.Writer, meta: Meta) std.Io.Writer.Error!void {
        const PrintLevel = enum { ERR, WARN, INFO, DEBUG, TRACE };

        try writer.print(
            "{d}/{d:02}/{d:02} {d:02}:{d:02}:{d:02}.{d:03}{d:03} {s}:{d}  {s}[{d}] ",
            .{
                meta.year,
                meta.month,
                meta.day,
                meta.hour,
                meta.minute,
                meta.second,
                meta.millisecond,
                meta.microsecond,
                meta.src.file,
                meta.src.line,
                @tagName(@as(PrintLevel, @enumFromInt(@intFromEnum(meta.level)))),
                meta.thread_id,
            },
        );
    }

    fn handleLog(
        self: *Self,
        thread_id: std.Thread.Id,
        header: *const SpscVarQueue.MsgHeader,
    ) !void {
        const log_id = header.log_id;
        const data_size = header.size.load(.monotonic);
        const log_info = self._bg_log_infos.items[log_id];

        const time_val = header.get_tsc();
        const timestamp = self._tscns.tsc2ns(time_val);
        const time = zeit.instant(
            .{ .unix_nano = timestamp },
            &self._timezone,
        ).time();

        const meta = Meta{
            .timestamp = timestamp,
            .year = time.year,
            .month = @intFromEnum(time.month),
            .day = time.day,
            .hour = time.hour,
            .minute = time.minute,
            .second = time.second,
            .millisecond = time.millisecond,
            .microsecond = time.microsecond,
            .nanosecond = time.nanosecond,
            .src = log_info.src,
            .level = log_info.message_level,
            .thread_id = thread_id,
        };

        try self._print_meta_cb(self._writer, meta);

        const data = @as([*]const u8, @ptrCast(header)) + @sizeOf(@TypeOf(header));
        try log_info.func(
            data[@sizeOf(i64)..data_size],
            self._writer,
        );
    }

    fn adjustHeap(self: Self, i: usize) void {
        var idx = i;
        while (true) {
            var min_i: usize = idx;

            var ch: usize = idx * 2 + 1;
            const end = std.sort.min(
                usize,
                &[_]usize{ ch + 2, self._bg_thread_buffers.items.len },
                {},
                std.sort.asc(usize),
            ).?;
            while (ch < end) {
                defer ch += 1;
                const h_ch = self._bg_thread_buffers.items[ch].header;
                const h_min = self._bg_thread_buffers.items[min_i].header;
                if (h_ch != null) {
                    if (h_min == null) {
                        min_i = ch;
                    } else {
                        const h_ch_t = h_ch.?.get_tsc();
                        const h_min_t = h_min.?.get_tsc();
                        if (h_ch_t < h_min_t) {
                            min_i = ch;
                        }
                    }
                }
            }
            if (min_i == idx) break;
            std.mem.swap(
                HeapNode,
                &self._bg_thread_buffers.items[idx],
                &self._bg_thread_buffers.items[min_i],
            );
            idx = min_i;
        }
    }

    fn allocMsg(self: *Self, size: u32, q_full_cb: bool) !?*SpscVarQueue.MsgHeader {
        try self.preallocate();

        if (thread_buffer) |buffer| {
            const ret = buffer.varq.alloc(size);

            if (ret == null and q_full_cb) {
                self._log_q_full_cb(self._log_q_full_cb_args);
            }

            return ret;
        } else {
            return error.ThreadBufferIsNull;
        }
    }
};
