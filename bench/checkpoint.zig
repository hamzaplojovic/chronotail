const std = @import("std");
const chronotail = @import("chronotail");

const append_count = 1_000_000;
const checkpoint_interval = 1_000;
const reopen_count = 200;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var checkpoint_latencies: [append_count / checkpoint_interval]u64 = undefined;
    var appender = try chronotail.Appender.create(allocator, "checkpoint-1k.ctdb", .raw);
    var checkpoint_timer = try std.time.Timer.start();
    var total_timer = try std.time.Timer.start();
    var checkpoint_index: usize = 0;

    for (0..append_count) |i| {
        try appender.append("telemetry", @intCast(i), 42.5);
        if ((i + 1) % checkpoint_interval == 0) {
            checkpoint_timer.reset();
            try appender.checkpoint(true);
            checkpoint_latencies[checkpoint_index] = checkpoint_timer.read();
            checkpoint_index += 1;
        }
    }
    try appender.close();
    const total_ns = total_timer.read();

    const file = try std.fs.cwd().openFile("checkpoint-1k.ctdb", .{});
    const file_size = try file.getEndPos();
    file.close();

    var reopen_latencies: [reopen_count]u64 = undefined;
    var reopen_timer = try std.time.Timer.start();
    for (&reopen_latencies) |*latency| {
        reopen_timer.reset();
        var reader = try chronotail.Reader.open(allocator, "checkpoint-1k.ctdb");
        reader.close();
        latency.* = reopen_timer.read();
    }

    std.sort.heap(u64, &checkpoint_latencies, {}, std.sort.asc(u64));
    std.sort.heap(u64, &reopen_latencies, {}, std.sort.asc(u64));
    const seconds = @as(f64, @floatFromInt(total_ns)) / std.time.ns_per_s;

    var output: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &output,
        "checkpoint every 1000 records, fsync=true\n" ++
            "  checkpoints: 1000\n" ++
            "  writes/sec: {d:.0}\n" ++
            "  checkpoint p50: {d:.3} ms\n" ++
            "  checkpoint p99: {d:.3} ms\n" ++
            "  reopen p50: {d:.3} ms\n" ++
            "  reopen p99: {d:.3} ms\n" ++
            "  file size: {d} bytes\n",
        .{
            append_count / seconds,
            milliseconds(checkpoint_latencies[checkpoint_latencies.len / 2 - 1]),
            milliseconds(checkpoint_latencies[checkpoint_latencies.len * 99 / 100 - 1]),
            milliseconds(reopen_latencies[reopen_latencies.len / 2 - 1]),
            milliseconds(reopen_latencies[reopen_latencies.len * 99 / 100 - 1]),
            file_size,
        },
    );
    try std.fs.File.stdout().writeAll(text);
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}
