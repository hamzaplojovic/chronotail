const std = @import("std");
const chronotail = @import("chronotail");

const reader_count = 8;
const append_count = 1_000_000;
const checkpoint_interval = 1_000;
const max_queries_per_reader = 200_000;

const Shared = struct {
    ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    start: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const ReaderStats = struct {
    latencies: []u64,
    count: usize = 0,
    failed: bool = false,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var appender = try chronotail.Appender.create(allocator, "concurrent.ctdb", .raw);
    for (0..checkpoint_interval) |i| try appender.append("telemetry", @intCast(i), 42.5);
    try appender.checkpoint(false);

    var shared = Shared{};
    var stats: [reader_count]ReaderStats = undefined;
    var threads: [reader_count]std.Thread = undefined;
    for (0..reader_count) |i| {
        stats[i] = .{ .latencies = try allocator.alloc(u64, max_queries_per_reader) };
        threads[i] = try std.Thread.spawn(.{}, readerWorker, .{ &shared, &stats[i] });
    }
    while (shared.ready.load(.acquire) != reader_count) std.atomic.spinLoopHint();

    var timer = try std.time.Timer.start();
    shared.start.store(true, .release);
    for (checkpoint_interval..append_count + checkpoint_interval) |i| {
        try appender.append("telemetry", @intCast(i), 42.5);
        if ((i + 1) % checkpoint_interval == 0) try appender.checkpoint(false);
    }
    const elapsed_ns = timer.read();
    shared.done.store(true, .release);
    try appender.close();
    for (&threads) |thread| thread.join();

    var all_latencies: std.ArrayList(u64) = .empty;
    defer all_latencies.deinit(allocator);
    for (&stats) |reader_stats| {
        defer allocator.free(reader_stats.latencies);
        if (reader_stats.failed) return error.ReaderFailed;
        try all_latencies.appendSlice(allocator, reader_stats.latencies[0..reader_stats.count]);
    }
    if (all_latencies.items.len == 0) return error.NoReaderQueries;
    std.sort.heap(u64, all_latencies.items, {}, std.sort.asc(u64));

    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const p50 = all_latencies.items[all_latencies.items.len / 2 - 1];
    const p99 = all_latencies.items[all_latencies.items.len * 99 / 100 - 1];
    var output: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &output,
        "1 writer / 8 readers\n" ++
            "  appends: {d}\n" ++
            "  reader queries: {d}\n" ++
            "  writer writes/sec: {d:.0}\n" ++
            "  reader p50: {d:.3} us\n" ++
            "  reader p99: {d:.3} us\n",
        .{
            append_count,
            all_latencies.items.len,
            append_count / seconds,
            microseconds(p50),
            microseconds(p99),
        },
    );
    try std.fs.File.stdout().writeAll(text);
}

fn readerWorker(shared: *Shared, stats: *ReaderStats) void {
    readerWorkerFallible(shared, stats) catch {
        stats.failed = true;
        shared.done.store(true, .release);
    };
}

fn readerWorkerFallible(shared: *Shared, stats: *ReaderStats) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var reader = try chronotail.Reader.open(gpa.allocator(), "concurrent.ctdb");
    defer reader.close();
    _ = shared.ready.fetchAdd(1, .release);
    while (!shared.start.load(.acquire)) std.atomic.spinLoopHint();

    var state: u64 = 0x9e3779b97f4a7c15 +% @intFromPtr(stats);
    var query_timer = try std.time.Timer.start();
    while (!shared.done.load(.acquire) and stats.count < stats.latencies.len) {
        if (stats.count % 64 == 0) _ = try reader.refresh();
        const latest = (try reader.latestTimestamp("telemetry")) orelse continue;
        if (latest < 99) continue;
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const start: i64 = @intCast(state % @as(u64, @intCast(latest - 98)));
        query_timer.reset();
        const matches = try reader.range("telemetry", start, start + 99, null);
        stats.latencies[stats.count] = query_timer.read();
        stats.count += 1;
        if (matches != 100) return error.UnexpectedQueryResult;
    }
}

fn microseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_us;
}
