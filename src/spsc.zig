const std = @import("std");
const testing = std.testing;

const cache_line = std.atomic.cache_line;

pub const SpscVarQueue = struct {
    const Self = @This();

    pub const MsgHeader = struct {
        size: std.atomic.Value(u32) = .init(0),
        log_id: u32 = 0,

        pub fn push(self: *MsgHeader, sz: u32) void {
            self.size.store(sz + @sizeOf(MsgHeader), .release);
        }

        pub fn get_tsc(self: *const MsgHeader) i64 {
            const ptr: [*]const u8 = @ptrCast(self);
            return std.mem.readInt(
                i64,
                @as(*const [8]u8, @ptrCast(ptr + @sizeOf(MsgHeader))),
                .native,
            );
        }

        pub fn set_tsc(self: *const MsgHeader, tsc: i64) void {
            const ptr: [*]u8 = @ptrCast(@constCast(self));
            std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(ptr + @sizeOf(MsgHeader))), tsc, .native);
        }
    };

    _allocator: std.mem.Allocator,

    _blk: []align(cache_line) MsgHeader,

    _blk_cnt: u32,
    _write_idx: u32 = 0,
    _free_write_cnt: u32,

    _read_idx: std.atomic.Value(u32) align(cache_line) = .init(0),

    pub fn init(allocator: std.mem.Allocator, queue_size: u32) !Self {
        const blk_cnt = queue_size / @sizeOf(MsgHeader);
        const blk = try allocator.alignedAlloc(
            MsgHeader,
            std.mem.Alignment.fromByteUnits(cache_line),
            blk_cnt,
        );

        const step = std.heap.pageSize() / @sizeOf(MsgHeader);
        var i: usize = 0;
        while (i < blk_cnt) : (i += step) {
            blk[i].size.store(0, .monotonic);
        }

        return .{
            ._allocator = allocator,
            ._blk = blk,
            ._blk_cnt = blk_cnt,
            ._free_write_cnt = blk_cnt,
        };
    }

    pub fn deinit(self: Self) void {
        self._allocator.free(self._blk);
    }

    pub fn alloc(self: *Self, size: u32) ?*MsgHeader {
        var asize = size;
        asize += @sizeOf(MsgHeader);

        const blk_sz: u32 = (asize + @sizeOf(MsgHeader) - 1) / @sizeOf(MsgHeader);

        if (blk_sz >= self._free_write_cnt) {
            const read_idx_cache = self._read_idx.load(.acquire);

            if (read_idx_cache <= self._write_idx) {
                self._free_write_cnt = self._blk_cnt - self._write_idx;

                if (blk_sz >= self._free_write_cnt and read_idx_cache != 0) {
                    self._blk[0].size.store(0, .monotonic);
                    self._blk[self._write_idx].size.store(1, .release);
                    self._write_idx = 0;
                    self._free_write_cnt = read_idx_cache;
                }
            } else {
                self._free_write_cnt = read_idx_cache - self._write_idx;
            }

            if (self._free_write_cnt <= blk_sz) {
                return null;
            }
        }

        const ret = &self._blk[self._write_idx];
        self._write_idx += blk_sz;
        self._free_write_cnt -= blk_sz;
        self._blk[self._write_idx].size.store(0, .monotonic);

        return ret;
    }

    pub fn front(self: *Self) ?*MsgHeader {
        var size = self._blk[self._read_idx.load(.monotonic)].size.load(.acquire);
        if (size == 1) {
            self._read_idx.store(0, .monotonic);
            size = self._blk[0].size.load(.monotonic);
        }
        if (size == 0) return null;
        return &self._blk[self._read_idx.load(.monotonic)];
    }

    pub fn pop(self: *Self) void {
        const blk_sz = (self._blk[self._read_idx.load(.monotonic)].size.load(.monotonic) +
            @sizeOf(MsgHeader) - 1) / @sizeOf(MsgHeader);

        _ = self._read_idx.fetchAdd(blk_sz, .release);
    }
};

test "wrap alloc" {
    const block_size = @sizeOf(SpscVarQueue.MsgHeader);

    var queue = try SpscVarQueue.init(testing.allocator, block_size * 5);
    defer queue.deinit();

    for (0..4) |_| {
        const header = queue.alloc(0) orelse return error.TestUnexpectedResult;
        header.push(0);
    }

    for (0..4) |_| {
        try testing.expect(queue.front() != null);
        queue.pop();
    }

    try testing.expectEqual(@as(u32, 4), queue._read_idx.load(.monotonic));
    try testing.expectEqual(@as(u32, 4), queue._write_idx);
    try testing.expectEqual(@as(u32, 1), queue._free_write_cnt);

    const wrapped = queue.alloc(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(&queue._blk[0], wrapped);
    try testing.expectEqual(@as(u32, 1), queue._write_idx);
    try testing.expectEqual(@as(u32, 3), queue._free_write_cnt);
    try testing.expectEqual(@as(u32, 1), queue._blk[4].size.load(.monotonic));

    wrapped.push(0);

    try testing.expectEqual(&queue._blk[0], queue.front().?);
    try testing.expectEqual(@as(u32, 0), queue._read_idx.load(.monotonic));
}

test "wrap space" {
    const block_size = @sizeOf(SpscVarQueue.MsgHeader);

    var queue = try SpscVarQueue.init(testing.allocator, block_size * 5);
    defer queue.deinit();

    for (0..4) |_| {
        const header = queue.alloc(0) orelse return error.TestUnexpectedResult;
        header.push(0);
    }

    for (0..4) |_| {
        try testing.expect(queue.front() != null);
        queue.pop();
    }

    const wrapped = queue.alloc(0) orelse return error.TestUnexpectedResult;
    wrapped.push(0);

    try testing.expectEqual(@as(u32, 4), queue._read_idx.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), queue._write_idx);

    const second = queue.alloc(0) orelse return error.TestUnexpectedResult;
    second.push(0);
    const third = queue.alloc(0) orelse return error.TestUnexpectedResult;
    third.push(0);

    try testing.expectEqual(@as(u32, 4), queue._read_idx.load(.monotonic));
    try testing.expectEqual(@as(u32, 3), queue._write_idx);
    try testing.expectEqual(@as(u32, 1), queue._free_write_cnt);

    try testing.expect(queue.alloc(0) == null);
    try testing.expectEqual(@as(u32, 4), queue._read_idx.load(.monotonic));
    try testing.expectEqual(@as(u32, 3), queue._write_idx);
    try testing.expectEqual(@as(u32, 1), queue._free_write_cnt);
}
