const std = @import("std");
const chronotail = @import("chronotail");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.InvalidArguments;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "append") and args.len == 2) return appendProbe(allocator, 1);
    if (std.mem.eql(u8, mode, "append-8-series") and args.len == 2)
        return appendProbe(allocator, 8);
    if (std.mem.eql(u8, mode, "append-batch") and args.len == 3) {
        const batch_size = try std.fmt.parseInt(usize, args[2], 10);
        if (batch_size == 0 or batch_size > 65_536) return error.InvalidArguments;
        return appendBatchProbe(allocator, batch_size);
    }
    if (std.mem.eql(u8, mode, "raw-point") and args.len == 2)
        return queryProbe(allocator, .raw, 1, 5_000_000);
    if (std.mem.eql(u8, mode, "raw-range") and args.len == 2)
        return queryProbe(allocator, .raw, 100, 5_000_000);
    if (std.mem.eql(u8, mode, "compressed-range") and args.len == 2)
        return queryProbe(allocator, .compressed, 100, 1_000_000);
    if (std.mem.eql(u8, mode, "raw-range-width") and args.len == 4) {
        const width = try std.fmt.parseInt(usize, args[2], 10);
        const count = try std.fmt.parseInt(usize, args[3], 10);
        if (width == 0 or width > 1_000_000 or count == 0) return error.InvalidArguments;
        return queryProbe(allocator, .raw, width, count);
    }
    if (std.mem.eql(u8, mode, "raw-point-irregular") and args.len == 2)
        return irregularPointProbe(allocator);
    if (std.mem.eql(u8, mode, "refresh") and args.len == 2) return refreshProbe(allocator);
    if (std.mem.eql(u8, mode, "open-reader") and args.len == 2) return openReaderProbe(allocator);
    if (std.mem.eql(u8, mode, "checkpoint") and args.len == 2) return checkpointProbe(allocator);
    return error.InvalidArguments;
}

fn appendProbe(allocator: std.mem.Allocator, series_count: usize) !void {
    const path = ".profile-append.ctdb";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    const names = [_][]const u8{
        "series-0", "series-1", "series-2", "series-3",
        "series-4", "series-5", "series-6", "series-7",
    };
    var writer = try chronotail.Appender.create(allocator, path, .raw);
    var timer = try std.time.Timer.start();
    const records_count = 10_000_000;
    for (0..records_count) |i| {
        const series_index = i % series_count;
        try writer.append(names[series_index], @intCast(i / series_count), @floatFromInt(i));
    }
    try writer.close();
    const elapsed_ns = timer.read();
    std.debug.print("series={d} records_per_second={d:.3}\n", .{
        series_count,
        @as(f64, records_count) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed_ns)),
    });
}

fn appendBatchProbe(allocator: std.mem.Allocator, batch_size: usize) !void {
    const path = ".profile-append.ctdb";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    const timestamps = try allocator.alloc(i64, batch_size);
    defer allocator.free(timestamps);
    const values = try allocator.alloc(f64, batch_size);
    defer allocator.free(values);
    var writer = try chronotail.Appender.create(allocator, path, .raw);
    const records_count = 10_000_000;
    var written: usize = 0;
    var timer = try std.time.Timer.start();
    while (written < records_count) {
        const count = @min(batch_size, records_count - written);
        for (timestamps[0..count], values[0..count], 0..) |*timestamp, *value, index| {
            timestamp.* = @intCast(written + index);
            value.* = @floatFromInt(written + index);
        }
        try writer.appendBatch("telemetry", timestamps[0..count], values[0..count]);
        written += count;
    }
    try writer.close();
    const elapsed_ns = timer.read();
    std.debug.print("batch={d} records_per_second={d:.3}\n", .{
        batch_size,
        @as(f64, records_count) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed_ns)),
    });
}

fn buildData(allocator: std.mem.Allocator, path: []const u8, codec: chronotail.Codec) !void {
    std.fs.cwd().deleteFile(path) catch {};
    var writer = try chronotail.Appender.create(allocator, path, codec);
    for (0..1_000_000) |i| {
        const input: f64 = @floatFromInt(i);
        const value = 20.0 + input * 0.000001 + @sin(input * 0.0001);
        try writer.append("telemetry", @intCast(i), value);
    }
    try writer.close();
}

fn queryProbe(
    allocator: std.mem.Allocator,
    codec: chronotail.Codec,
    width: usize,
    count: usize,
) !void {
    const path = if (codec == .raw) ".profile-raw.ctdb" else ".profile-compressed.ctdb";
    try buildData(allocator, path, codec);
    defer std.fs.cwd().deleteFile(path) catch {};
    var reader = try chronotail.Reader.open(allocator, path);
    defer reader.close();
    const timestamps = try allocator.alloc(i64, width);
    defer allocator.free(timestamps);
    const values = try allocator.alloc(f64, width);
    defer allocator.free(values);
    var state: u64 = 0xd1b54a32d192ed03;
    var digest: u64 = 0;
    var timer = try std.time.Timer.start();
    for (0..count) |_| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const start: i64 = @intCast(state % (1_000_000 - width + 1));
        const end = start + @as(i64, @intCast(width)) - 1;
        const found = try reader.rangeInto("telemetry", start, end, timestamps, values);
        if (found != width) return error.UnexpectedQueryResult;
        digest +%= @bitCast(values[width - 1]);
    }
    const elapsed_ns = timer.read();
    std.mem.doNotOptimizeAway(digest);
    std.debug.print(
        "width={d} queries={d} queries_per_second={d:.3} points_per_second={d:.3}\n",
        .{
            width,
            count,
            @as(f64, @floatFromInt(count)) * std.time.ns_per_s /
                @as(f64, @floatFromInt(elapsed_ns)),
            @as(f64, @floatFromInt(count * width)) * std.time.ns_per_s /
                @as(f64, @floatFromInt(elapsed_ns)),
        },
    );
}

fn irregularPointProbe(allocator: std.mem.Allocator) !void {
    const path = ".profile-irregular.ctdb";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    const timestamps = try allocator.alloc(i64, 1_000_000);
    defer allocator.free(timestamps);
    var writer = try chronotail.Appender.create(allocator, path, .raw);
    var timestamp: i64 = 0;
    var state: u64 = 0xd1b54a32d192ed03;
    for (timestamps, 0..) |*entry, index| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        timestamp += @intCast(state % 100 + 1);
        entry.* = timestamp;
        try writer.append("telemetry", timestamp, @floatFromInt(index));
    }
    try writer.close();

    var reader = try chronotail.Reader.open(allocator, path);
    defer reader.close();
    var output_timestamp: [1]i64 = undefined;
    var output_value: [1]f64 = undefined;
    var digest: u64 = 0;
    var timer = try std.time.Timer.start();
    for (0..5_000_000) |_| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const query = timestamps[state % timestamps.len];
        if (try reader.rangeInto("telemetry", query, query, &output_timestamp, &output_value) != 1)
            return error.UnexpectedQueryResult;
        digest +%= @bitCast(output_value[0]);
    }
    const elapsed_ns = timer.read();
    std.mem.doNotOptimizeAway(digest);
    std.debug.print("irregular_queries_per_second={d:.3}\n", .{
        @as(f64, 5_000_000) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed_ns)),
    });
}

fn refreshProbe(allocator: std.mem.Allocator) !void {
    const path = ".profile-refresh.ctdb";
    try buildData(allocator, path, .raw);
    defer std.fs.cwd().deleteFile(path) catch {};
    var reader = try chronotail.Reader.open(allocator, path);
    defer reader.close();
    var changed: usize = 0;
    for (0..2_000_000) |_| if (try reader.refresh()) {
        changed += 1;
    };
    std.mem.doNotOptimizeAway(changed);
}

fn openReaderProbe(allocator: std.mem.Allocator) !void {
    const path = ".profile-open.ctdb";
    try buildData(allocator, path, .raw);
    defer std.fs.cwd().deleteFile(path) catch {};
    var timer = try std.time.Timer.start();
    for (0..10_000) |_| {
        var reader = try chronotail.Reader.open(allocator, path);
        reader.close();
    }
    const elapsed_ns = timer.read();
    std.debug.print("opens_per_second={d:.3} average_open_ns={d:.3}\n", .{
        @as(f64, 10_000) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed_ns)),
        @as(f64, @floatFromInt(elapsed_ns)) / 10_000,
    });
}

fn checkpointProbe(allocator: std.mem.Allocator) !void {
    const path = ".profile-checkpoint.ctdb";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};
    var writer = try chronotail.Appender.create(allocator, path, .raw);
    for (0..50_000) |checkpoint| {
        for (0..1_000) |i| try writer.append(
            "telemetry",
            @intCast(checkpoint * 1_000 + i),
            @floatFromInt(i),
        );
        try writer.checkpoint(false);
    }
    try writer.close();
}
