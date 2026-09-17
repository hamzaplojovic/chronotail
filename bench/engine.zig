const std = @import("std");
const chronotail = @import("chronotail");

const point_count = 1_000_000;
const query_count = 10_000;
const query_width = 100;

const Result = struct {
    label: []const u8,
    codec: chronotail.Codec,
    write_seconds: f64,
    writes_per_second: f64,
    file_size: u64,
    queries_per_second: f64,
    p50_ns: u64,
    p99_ns: u64,
    raw_blocks: usize,
    compressed_blocks: usize,
    cold_profile: chronotail.QueryProfile,
    warm_profile: chronotail.QueryProfile,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const timestamps = try allocator.alloc(i64, point_count);
    defer allocator.free(timestamps);
    const values = try allocator.alloc(f64, point_count);
    defer allocator.free(values);

    makeSmooth(timestamps, values);
    const smooth_raw = try runBenchmark(
        allocator,
        "smooth-raw.ctdb",
        "smooth",
        .raw,
        timestamps,
        values,
    );
    const smooth_compressed = try runBenchmark(
        allocator,
        "smooth-compressed.ctdb",
        "smooth",
        .compressed,
        timestamps,
        values,
    );

    makeRandom(timestamps, values);
    const random_raw = try runBenchmark(
        allocator,
        "random-raw.ctdb",
        "random",
        .raw,
        timestamps,
        values,
    );
    const random_compressed = try runBenchmark(
        allocator,
        "random-compressed.ctdb",
        "random",
        .compressed,
        timestamps,
        values,
    );

    try printProfile(smooth_raw);
    try printPair(smooth_raw, smooth_compressed);
    try printPair(random_raw, random_compressed);
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    codec: chronotail.Codec,
    timestamps: []const i64,
    values: []const f64,
) !Result {
    var appender = try chronotail.Appender.create(allocator, path, codec);
    var write_timer = try std.time.Timer.start();
    for (timestamps, values) |timestamp, value| try appender.append("telemetry", timestamp, value);
    try appender.close();
    const write_ns = write_timer.read();

    const file = try std.fs.cwd().openFile(path, .{});
    const file_size = try file.getEndPos();
    file.close();

    var reader = try chronotail.Reader.open(allocator, path);
    defer reader.close();
    const codec_counts = try reader.codecCounts("telemetry");
    const profile_index = point_count / 2;
    const cold_profile = try reader.profileRange(
        "telemetry",
        timestamps[profile_index],
        timestamps[profile_index + query_width - 1],
    );
    const warm_profile = try reader.profileRange(
        "telemetry",
        timestamps[profile_index],
        timestamps[profile_index + query_width - 1],
    );
    _ = try reader.range("telemetry", timestamps[0], timestamps[point_count - 1], null);

    var latencies: [query_count]u64 = undefined;
    var state: u64 = 0xd1b54a32d192ed03;
    var query_timer = try std.time.Timer.start();
    var total_timer = try std.time.Timer.start();
    for (&latencies) |*latency| {
        state = nextRandom(state);
        const start_index: usize = @intCast(state % (point_count - query_width + 1));
        query_timer.reset();
        const matches = try reader.range(
            "telemetry",
            timestamps[start_index],
            timestamps[start_index + query_width - 1],
            null,
        );
        latency.* = query_timer.read();
        if (matches != query_width) return error.UnexpectedQueryResult;
    }
    const query_ns = total_timer.read();
    std.sort.heap(u64, &latencies, {}, std.sort.asc(u64));

    const write_seconds = @as(f64, @floatFromInt(write_ns)) / std.time.ns_per_s;
    const query_seconds = @as(f64, @floatFromInt(query_ns)) / std.time.ns_per_s;
    return .{
        .label = label,
        .codec = codec,
        .write_seconds = write_seconds,
        .writes_per_second = point_count / write_seconds,
        .file_size = file_size,
        .queries_per_second = query_count / query_seconds,
        .p50_ns = latencies[query_count / 2 - 1],
        .p99_ns = latencies[(query_count * 99) / 100 - 1],
        .raw_blocks = codec_counts[0],
        .compressed_blocks = codec_counts[1],
        .cold_profile = cold_profile,
        .warm_profile = warm_profile,
    };
}

fn printProfile(result: Result) !void {
    var output: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &output,
        "100-point raw query profile\n" ++
            "  cold block lookup: {d} ns\n" ++
            "  cold file read: {d} ns\n" ++
            "  cold checksum: {d} ns\n" ++
            "  cold record decode: {d} ns\n" ++
            "  cached block lookup: {d} ns\n" ++
            "  cached file read: {d} ns\n" ++
            "  cached checksum: {d} ns\n" ++
            "  cached record decode: {d} ns\n\n",
        .{
            result.cold_profile.block_lookup_ns,
            result.cold_profile.file_read_ns,
            result.cold_profile.checksum_ns,
            result.cold_profile.record_decode_ns,
            result.warm_profile.block_lookup_ns,
            result.warm_profile.file_read_ns,
            result.warm_profile.checksum_ns,
            result.warm_profile.record_decode_ns,
        },
    );
    try std.fs.File.stdout().writeAll(text);
}

fn printPair(raw: Result, compressed: Result) !void {
    var output: [1024]u8 = undefined;
    const ratio = @as(f64, @floatFromInt(raw.file_size)) /
        @as(f64, @floatFromInt(compressed.file_size));
    const text = try std.fmt.bufPrint(
        &output,
        "{s} / raw\n" ++
            "  write time: {d:.6} s\n" ++
            "  writes/sec: {d:.0}\n" ++
            "  file size: {d} bytes\n" ++
            "  compression ratio: 1.000x\n" ++
            "  queries/sec: {d:.0}\n" ++
            "  p50: {d} ns\n" ++
            "  p99: {d} ns\n" ++
            "  blocks: {d} raw, {d} compressed\n" ++
            "{s} / compressed-with-fallback\n" ++
            "  write time: {d:.6} s\n" ++
            "  writes/sec: {d:.0}\n" ++
            "  file size: {d} bytes\n" ++
            "  compression ratio: {d:.3}x\n" ++
            "  queries/sec: {d:.0}\n" ++
            "  p50: {d} ns\n" ++
            "  p99: {d} ns\n" ++
            "  blocks: {d} raw, {d} compressed\n\n",
        .{
            raw.label,
            raw.write_seconds,
            raw.writes_per_second,
            raw.file_size,
            raw.queries_per_second,
            raw.p50_ns,
            raw.p99_ns,
            raw.raw_blocks,
            raw.compressed_blocks,
            compressed.label,
            compressed.write_seconds,
            compressed.writes_per_second,
            compressed.file_size,
            ratio,
            compressed.queries_per_second,
            compressed.p50_ns,
            compressed.p99_ns,
            compressed.raw_blocks,
            compressed.compressed_blocks,
        },
    );
    try std.fs.File.stdout().writeAll(text);
}

fn makeSmooth(timestamps: []i64, values: []f64) void {
    for (timestamps, values, 0..) |*timestamp, *value, i| {
        timestamp.* = @intCast(i * 10);
        value.* = 42.0 + @as(f64, @floatFromInt(i % 1000)) * 0.001;
    }
}

fn makeRandom(timestamps: []i64, values: []f64) void {
    var state: u64 = 0xa0761d6478bd642f;
    var timestamp: i64 = 0;
    for (timestamps, values) |*stored_timestamp, *value| {
        state = nextRandom(state);
        timestamp += @intCast(state % 4_000_000_000 + 1);
        stored_timestamp.* = timestamp;
        state = nextRandom(state);
        value.* = @bitCast(state);
    }
}

fn nextRandom(state: u64) u64 {
    return state *% 6364136223846793005 +% 1442695040888963407;
}
