# nanozlog

An ultra-low latency, lock-free asynchronous logging library for Zig, heavily inspired by and porting from C++'s FmtLog.

## Features

This project is focusing on blazing-fast frontend logging speed (nanoseconds per msg). It will be helpful in High-Frequency Trading or Game Development in which it must make sure that the logging instruction will cause minimal blocking of the working process.

- **Ultra-Low Latency & Lock-Free**: The frontend pushes raw log data into a background queue without acquiring any locks, getting out of the hot path in mere nanoseconds.
- **Zero Hidden Allocations**: Absolutely no surprise memory allocations on the critical path.
- **Interval Logging**: Built-in support for throttling spammy logs (`infoi`, `warni`, etc. to log at most once per `N` nanoseconds).
- **Customizable Metadata Logging**: Define your own metadata printing logic to format timestamps, log levels, file names, and thread IDs exactly how you want.
- **Queue-Full Callback**: Easily hook into queue-full events. You can gracefully handle buffer overflows by choosing to drop logs, trigger alerts, or execute custom logic when the asynchronous log queue hits its limit.

## Example

```zig
const nanozlog = @import("nanozlog");

var w_buffer: [4096]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &w_buffer);

try nanozlog.initNanoZlog(io, allocator, &stdout_writer.interface, .{});
defer nanozlog.deinitNanoZlog(allocator);

const n: usize = 100;
var i: usize = 0;
while (i < n) : (i += 1) {
    nanozlog.err(@src(), "Test log {d}", .{i}); // basic logging, @src() is required for optimization
    nanozlog.infoi(1000, @src(), "Test log {d}", .{i}); // time interval logging，avoid log flooding and excessive I/O usage
}
```

### Queue Full Callback (`setLogQFullCB`)

You can define a callback to execute custom logic when the logging queue is full (e.g., dropping logs, alerting, etc.).

```zig
fn onQueueFull(args: *anyopaque) void {
    _ = args;
    std.debug.print("Warning: Log queue is full! Logs might be dropped.\n", .{});
}

// When initializing nanozlog
try initNanoZlog(io, allocator, writer, .{ .log_q_full_cb = onQueueFull, .log_q_full_cb_args = undefined });
```

### Custom Print Meta Callback (`setPrintMetaCB`)

You can completely customize how the log metadata (timestamp, log level, thread ID, file name, etc.) is formatted by setting a custom callback.

```zig
fn customPrintMeta(writer: *std.Io.Writer, meta: nanozlog.Meta) std.Io.Writer.Error!void {
    const level_str = switch (meta.level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
        .trace => "TRACE",
    };
    try writer.print("[{s}] {s}:{d} - ", .{ level_str, meta.src.file, meta.src.line });
}

// When initializing nanozlog
try initNanoZlog(io, allocator, writer, .{ .print_meta_cb = customPrintMeta });
```

### Thread Buffer Cleanup (`deinitThreadBuffer`)

If your application creates and destroys many threads dynamically, you should call `deinitThreadBuffer()` before a thread exits to clean up its local logging buffer and prevent memory leaks.

```zig
fn workerThread() void {
    // Clean up the thread-local buffer when the thread finishes
    defer nanozlog.deinitThreadBuffer();

    nanozlog.info(@src(), "Worker thread started", .{});
    // ... do some work
}
```

## Configuration

You can configure the size of the background SPSC queue using the Zig build system. By default, the queue size is set to 1MB (`1 << 20` bytes).

To change the queue size when building your project or running benchmarks, in your `build.zig` (if depending on `nanozlog` as a module), you can pass this option down:

```zig
const nanozlog_dep = b.dependency("nanozlog", .{
    .target = target,
    .optimize = optimize,
    .queue_size = @as(u32, 2097152),
});
```

## Limitations

To guarantee zero hidden allocations and keep the hot path completely predictable, `nanozlog` restricts the types of arguments you can log. You can safely log primitives (ints, floats, bools) and string slices (`[]const u8`), but complex structs or arrays will be rejected at compile time.

## Benchmark

```bash
zig build benchmark
```

Benchmark result on AMD Ryzen™ 9 9950X CPU and 6000 MT/s DDR5 RAM

| Test Case      | Messages | Total Time (µs) | Throughput (msg/s) | Latency (ns/msg) | Dropped |
| :------------- | -------: | --------------: | -----------------: | ---------------: | :-----: |
| Static String  |  100,000 |         680.288 |        146,996,566 |            6.803 |  false  |
| Dynamic String |  100,000 |         687.129 |        145,533,080 |            6.871 |  false  |
| Single Integer |  100,000 |         687.558 |        145,442,275 |            6.876 |  false  |
| Two Integers   |  100,000 |         682.899 |        146,434,539 |            6.829 |  false  |
| Single Double  |  100,000 |         688.368 |        145,271,134 |            6.884 |  false  |
