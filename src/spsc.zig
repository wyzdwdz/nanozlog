const std = @import("std");

const config = @import("config");

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

    const blk_cnt: u32 = config.queue_size / @sizeOf(MsgHeader);

    _blk: [blk_cnt]MsgHeader align(cache_line) = undefined,
    _write_idx: u32 = 0,
    _free_write_cnt: u32 = blk_cnt,

    _read_idx: std.atomic.Value(u32) align(cache_line) = .init(0),

    pub fn init() Self {
        return .{};
    }

    pub fn deinit() void {}

    pub fn alloc(self: *Self, size: u32) ?*MsgHeader {
        var asize = size;
        asize += @sizeOf(MsgHeader);

        const blk_sz: u32 = (asize + @sizeOf(MsgHeader) - 1) / @sizeOf(MsgHeader);

        if (blk_sz >= self._free_write_cnt) {
            const read_idx_cache = self._read_idx.load(.acquire);

            if (read_idx_cache <= self._write_idx) {
                self._free_write_cnt = blk_cnt - self._write_idx;

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
