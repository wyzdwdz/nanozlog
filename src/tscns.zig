pub const TscNs = @This();

const std = @import("std");
const builtin = @import("builtin");

const cache_line = std.atomic.cache_line;

const Atomic64 = struct {
    lo: std.atomic.Value(u32),
    hi: std.atomic.Value(u32),

    pub fn init(val: anytype) Atomic64 {
        const uval: u64 = @bitCast(val);
        return .{
            .lo = .init(@as(u32, @truncate(uval))),
            .hi = .init(@as(u32, @truncate(uval >> 32))),
        };
    }

    pub fn store(
        self: *Atomic64,
        val: anytype,
        comptime order: std.builtin.AtomicOrder,
    ) void {
        const uval: u64 = @bitCast(val);
        self.lo.store(@as(u32, @truncate(uval)), order);
        self.hi.store(@as(u32, @truncate(uval >> 32)), order);
    }

    pub fn load(
        self: *const Atomic64,
        comptime T: type,
        comptime order: std.builtin.AtomicOrder,
    ) T {
        const lo = self.lo.load(order);
        const hi = self.hi.load(order);
        const uval = (@as(u64, hi) << 32) | @as(u64, lo);
        return @bitCast(uval);
    }
};

_io: std.Io,

_param_seq: std.atomic.Value(u32) align(cache_line) = .init(0),
_ns_per_tsc: Atomic64 = .init(@as(f64, 0.0)),
_base_tsc: Atomic64 = .init(@as(i64, 0)),
_base_ns: Atomic64 = .init(@as(i64, 0)),
_calibrate_interval_ns: i64,
_base_ns_err: i64 = 0,
_next_calibrate_tsc: i64 = 0,

const NsPerSec = 1_000_000_000;

pub const Config = struct {
    init_calibrate_ns: i64 = 20_000_000,
    calibrate_interval_ns: i64 = 3_000_000_000,
};

pub fn init(io: std.Io, config: Config) !TscNs {
    var tscns = TscNs{
        ._io = io,
        ._calibrate_interval_ns = config.calibrate_interval_ns,
    };

    const base = tscns.syncTime();
    const expire_ns = base.ns_out + config.init_calibrate_ns;

    while (tscns.rdsysns() < expire_ns) {
        std.atomic.spinLoopHint();
    }

    const delay = tscns.syncTime();

    const init_ns_per_tsc = @as(f64, @floatFromInt(delay.ns_out - base.ns_out)) /
        @as(f64, @floatFromInt(delay.tsc_out - base.tsc_out));

    tscns.saveParam(base.tsc_out, base.ns_out, 0, init_ns_per_tsc);

    return tscns;
}

pub fn calibrate(self: *TscNs) void {
    if (self.rdtsc() < self._next_calibrate_tsc) return;
    const time = self.syncTime();
    var ns_err = self.tsc2ns(time.tsc_out) - time.ns_out;
    if (ns_err > 1_000_000) ns_err = 1_000_000;
    if (ns_err < -1_000_000) ns_err = -1_000_000;

    const ns_per_tsc = self._ns_per_tsc.load(f64, .monotonic);
    const base_tsc = self._base_tsc.load(i64, .monotonic);
    const new_ns_per_tsc = ns_per_tsc * (1.0 -
        @as(f64, @floatFromInt(ns_err + ns_err - self._base_ns_err)) /
            (@as(f64, @floatFromInt(time.tsc_out - base_tsc)) * ns_per_tsc));

    self.saveParam(time.tsc_out, time.ns_out, ns_err, new_ns_per_tsc);
}

pub fn rdns(self: *TscNs) i64 {
    return self.tsc2ns(self.rdtsc());
}

pub fn rdtsc(self: TscNs) i64 {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            var lo: u32 = undefined;
            var hi: u32 = undefined;

            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );

            return (@as(i64, hi) << 32 | @as(i64, lo));
        },
        .aarch64, .aarch64_be => {
            var val: u64 = undefined;

            asm volatile ("mrs %[val], cntvct_el0"
                : [val] "=r" (val),
            );

            return @as(i64, @bitCast(val));
        },
        .riscv64, .riscv64be => {
            var val: u64 = undefined;

            asm volatile ("rdtime %[val]"
                : [val] "=r" (val),
            );

            return @as(i64, @bitCast(val));
        },
        .loongarch64 => {
            var val: u64 = undefined;

            asm volatile ("rdtime.d %[val], $zero"
                : [val] "=r" (val),
            );

            return @as(i64, @bitCast(val));
        },
        .powerpc64, .powerpc64le => {
            var val: u64 = undefined;

            asm volatile ("mftb %[val]"
                : [val] "=r" (val),
            );

            return @as(i64, @bitCast(val));
        },
        else => {
            return self.rdsysns();
        },
    }
}

pub fn tsc2ns(self: *TscNs, tsc: i64) i64 {
    while (true) {
        const before_seq = self._param_seq.load(.acquire) & ~@as(u32, 1);

        const ns_per_tsc = self._ns_per_tsc.load(f64, .monotonic);
        const base_ns = self._base_ns.load(i64, .monotonic);
        const base_tsc = self._base_tsc.load(i64, .monotonic);
        const ns = base_ns + @as(
            i64,
            @trunc(@as(f64, @floatFromInt(tsc - base_tsc)) * ns_per_tsc),
        );

        const after_seq = self._param_seq.load(.acquire);
        if (before_seq == after_seq) return ns;
    }
}

fn rdsysns(self: TscNs) i64 {
    return @intCast(std.Io.Timestamp.now(self._io, .real).toNanoseconds());
}

fn syncTime(self: TscNs) struct { tsc_out: i64, ns_out: i64 } {
    const n = if (builtin.os.tag == .windows) 15 else 3;

    var tsc: [n + 1]i64 = undefined;
    var ns: [n + 1]i64 = undefined;

    tsc[0] = self.rdtsc();
    for (1..n + 1) |i| {
        ns[i] = self.rdsysns();
        tsc[i] = self.rdtsc();
    }

    var j: usize = 0;

    if (builtin.os.tag == .windows) {
        j = 1;
        for (2..n + 1) |i| {
            if (ns[i] == ns[i - 1]) continue;
            tsc[j - 1] = tsc[i - 1];
            ns[j] = ns[i];
            j += 1;
        }
        j -= 1;
    } else {
        j = n + 1;
    }

    var best: usize = 1;

    for (2..j) |i| {
        if (tsc[i] - tsc[i - 1] < tsc[best] - tsc[best - 1]) best = i;
    }

    return .{ .tsc_out = (tsc[best] + tsc[best - 1]) >> 1, .ns_out = ns[best] };
}

fn saveParam(
    self: *TscNs,
    base_tsc: i64,
    sys_ns: i64,
    base_ns_err: i64,
    new_ns_per_tsc: f64,
) void {
    self._base_ns_err = base_ns_err;
    self._next_calibrate_tsc = base_tsc + @as(
        i64,
        @trunc(@as(
            f64,
            @floatFromInt(self._calibrate_interval_ns - 1000),
        ) / new_ns_per_tsc),
    );

    _ = self._param_seq.fetchAdd(1, .acquire);

    self._base_tsc.store(base_tsc, .monotonic);
    self._base_ns.store(sys_ns + base_ns_err, .monotonic);
    self._ns_per_tsc.store(new_ns_per_tsc, .monotonic);

    _ = self._param_seq.fetchAdd(1, .release);
}

test "tsc2ns retry" {
    const testing = std.testing;

    var tscns = TscNs{
        ._io = testing.io,
        ._ns_per_tsc = .init(@as(f64, 1.0)),
        ._base_tsc = .init(@as(i64, 10)),
        ._base_ns = .init(@as(i64, 100)),
        ._calibrate_interval_ns = 1_000_000_000,
        ._param_seq = .init(1),
    };

    const Closure = struct {
        fn finishUpdate(io: std.Io, ptr: *TscNs) void {
            io.sleep(.fromMilliseconds(1), .awake) catch {};
            ptr._param_seq.store(2, .release);
        }
    };

    var future = try testing.io.concurrent(Closure.finishUpdate, .{ testing.io, &tscns });
    defer _ = future.await(testing.io);

    try testing.expectEqual(@as(i64, 110), tscns.tsc2ns(20));
}
