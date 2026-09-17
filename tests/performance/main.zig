const std = @import("std");
const chronotail = @import("chronotail");

const Config = struct {
    points: usize = 1_000_000,
    quick: bool = false,
    repetitions: usize = 3,
    output_path: []const u8 = "tests/performance/results/latest.jsonl",

    fn finalize(self: *Config) void {
        if (!self.quick) return;
        self.points = 100_000;
        self.repetitions = 1;
    }
};

const TimestampPattern = enum { dense, sparse, irregular };
const ValuePattern = enum { constant, smooth, spiky, random };

const Dataset = struct {
    timestamps: []i64,
    values: []f64,

    fn deinit(self: Dataset, allocator: std.mem.Allocator) void {
        allocator.free(self.timestamps);
        allocator.free(self.values);
    }
};

const Result = struct {
    group: []const u8,
    name: []const u8,
    codec: []const u8 = "none",
    timestamp_pattern: []const u8 = "none",
    value_pattern: []const u8 = "none",
    series_count: usize = 0,
    batch_size: usize = 0,
    width: usize = 0,
    operations: u64 = 0,
    points: u64 = 0,
    elapsed_ns: u64 = 0,
    operations_per_second: f64 = 0,
    points_per_second: f64 = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    max_ns: u64 = 0,
    file_size: u64 = 0,
    bytes_per_point: f64 = 0,
    raw_blocks: usize = 0,
    compressed_blocks: usize = 0,
    allocation_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    allocated_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    detail_a: u64 = 0,
    detail_b: u64 = 0,
};

const Reporter = struct {
    file: std.fs.File,

    fn init(path: []const u8) !Reporter {
        if (std.fs.path.dirname(path)) |directory| {
            try std.fs.cwd().makePath(directory);
        }
        return .{ .file = try std.fs.cwd().createFile(path, .{ .truncate = true }) };
    }

    fn close(self: *Reporter) void {
        self.file.close();
    }

    fn metadata(self: *Reporter, config: Config) !void {
        var buffer: [2048]u8 = undefined;
        const builtin = @import("builtin");
        const text = try std.fmt.bufPrint(
            &buffer,
            "{{\"type\":\"metadata\",\"format\":1,\"engine_format\":{d}," ++
                "\"zig\":\"{s}\",\"os\":\"{s}\",\"arch\":\"{s}\"," ++
                "\"points\":{d},\"repetitions\":{d},\"quick\":{s}}}\n",
            .{
                chronotail.file_header[4],
                @import("builtin").zig_version_string,
                @tagName(builtin.os.tag),
                @tagName(builtin.cpu.arch),
                config.points,
                config.repetitions,
                if (config.quick) "true" else "false",
            },
        );
        try self.file.writeAll(text);
    }

    fn emit(self: *Reporter, result: Result) !void {
        var buffer: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &buffer,
            "{{\"type\":\"result\",\"group\":\"{s}\",\"name\":\"{s}\"," ++
                "\"codec\":\"{s}\",\"timestamp_pattern\":\"{s}\"," ++
                "\"value_pattern\":\"{s}\",\"series_count\":{d}," ++
                "\"batch_size\":{d},\"width\":{d},\"operations\":{d}," ++
                "\"points\":{d},\"elapsed_ns\":{d}," ++
                "\"operations_per_second\":{d:.3},\"points_per_second\":{d:.3}," ++
                "\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d},\"max_ns\":{d}," ++
                "\"file_size\":{d},\"bytes_per_point\":{d:.6}," ++
                "\"raw_blocks\":{d},\"compressed_blocks\":{d}," ++
                "\"allocation_calls\":{d},\"resize_calls\":{d}," ++
                "\"remap_calls\":{d},\"free_calls\":{d}," ++
                "\"allocated_bytes\":{d},\"live_bytes\":{d}," ++
                "\"peak_live_bytes\":{d}," ++
                "\"detail_a\":{d},\"detail_b\":{d}}}\n",
            .{
                result.group,
                result.name,
                result.codec,
                result.timestamp_pattern,
                result.value_pattern,
                result.series_count,
                result.batch_size,
                result.width,
                result.operations,
                result.points,
                result.elapsed_ns,
                result.operations_per_second,
                result.points_per_second,
                result.p50_ns,
                result.p95_ns,
                result.p99_ns,
                result.max_ns,
                result.file_size,
                result.bytes_per_point,
                result.raw_blocks,
                result.compressed_blocks,
                result.allocation_calls,
                result.resize_calls,
                result.remap_calls,
                result.free_calls,
                result.allocated_bytes,
                result.live_bytes,
                result.peak_live_bytes,
                result.detail_a,
                result.detail_b,
            },
        );
        try self.file.writeAll(text);
        try self.file.sync();
    }
};

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocation_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    allocated_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn resetMeasurements(self: *CountingAllocator) void {
        self.allocation_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.free_calls = 0;
        self.allocated_bytes = 0;
        self.peak_live_bytes = self.live_bytes;
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const memory = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocation_calls += 1;
        self.allocated_bytes += len;
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, return_address)) return false;
        self.resize_calls += 1;
        if (new_len > memory.len) {
            self.allocated_bytes += new_len - memory.len;
            self.live_bytes += new_len - memory.len;
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.remap_calls += 1;
        if (new_len > memory.len) {
            self.allocated_bytes += new_len - memory.len;
            self.live_bytes += new_len - memory.len;
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
        self.free_calls += 1;
        self.live_bytes -= memory.len;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var config = try parseArgs(allocator);
    config.finalize();
    var reporter = try Reporter.init(config.output_path);
    defer reporter.close();
    try reporter.metadata(config);

    std.debug.print(
        "internal performance matrix: points={d} repetitions={d} output={s}\n",
        .{ config.points, config.repetitions, config.output_path },
    );
    for (0..config.repetitions) |repetition| {
        std.debug.print(
            "matrix repetition {d}/{d}\n",
            .{ repetition + 1, config.repetitions },
        );
        try runAppendMatrix(allocator, config, &reporter);
        try runStorageMatrix(allocator, config, &reporter);
        try runQueryMatrix(allocator, config, &reporter);
        try runReadApiMatrix(allocator, config, &reporter);
        try runAggregateMatrix(allocator, config, &reporter);
        try runSeriesLookupMatrix(allocator, config, &reporter);
        try runCheckpointMatrix(allocator, config, &reporter);
        try runControlPlaneMatrix(allocator, config, &reporter);
        try runAllocationMatrix(config, &reporter);
        try runParallelReaderMatrix(allocator, config, &reporter);
    }
    std.debug.print("internal performance matrix complete: {s}\n", .{config.output_path});
}

fn runReadApiMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: bounded-read-apis\n", .{});
    const dataset = try makeDataset(allocator, config.points, .irregular, .random);
    defer dataset.deinit(allocator);
    const path = ".profile-internal-read-apis.ctdb";
    deleteFile(path);
    defer deleteFile(path);
    try writeDataset(allocator, path, .raw, dataset, 4_096);
    var reader = try chronotail.Reader.open(allocator, path);
    defer reader.close();
    const handle = try reader.prepare("telemetry");

    inline for (.{ 16, 128, 1_024, 4_096 }) |capacity| {
        var output_timestamps: [capacity]i64 = undefined;
        var output_values: [capacity]f64 = undefined;
        const repetitions: usize = if (config.quick) 1 else 10;
        var digest: u64 = 0;
        var timer = try std.time.Timer.start();
        for (0..repetitions) |_| {
            var cursor = try reader.cursorPrepared(
                handle,
                dataset.timestamps[0],
                dataset.timestamps[dataset.timestamps.len - 1],
            );
            while (true) {
                const count = try reader.cursorNext(
                    &cursor,
                    &output_timestamps,
                    &output_values,
                );
                if (count == 0) break;
                digest +%= @bitCast(output_values[count - 1]);
            }
        }
        const elapsed = timer.read();
        std.mem.doNotOptimizeAway(digest);
        try reporter.emit(rateResult(.{
            .group = "query",
            .name = "cursor-full-range",
            .codec = "raw",
            .batch_size = capacity,
            .operations = repetitions,
            .points = repetitions * dataset.timestamps.len,
            .elapsed_ns = elapsed,
        }));
    }

    const borrow_count: usize = if (config.quick) 20_000 else 500_000;
    var random_state: u64 = 0x243f6a8885a308d3;
    var digest: u64 = 0;
    var timer = try std.time.Timer.start();
    for (0..borrow_count) |_| {
        random_state = nextRandom(random_state);
        const point_index = random_state % dataset.timestamps.len;
        const view = try reader.borrowRawPage(handle, dataset.timestamps[point_index]);
        digest +%= @bitCast(view.values[point_index % view.values.len]);
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(digest);
    try reporter.emit(rateResult(.{
        .group = "query",
        .name = "borrow-raw-page",
        .codec = "raw",
        .operations = borrow_count,
        .elapsed_ns = elapsed,
    }));
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var config = Config{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--quick")) {
            config.quick = true;
        } else if (std.mem.eql(u8, args[index], "--output")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            config.output_path = try allocator.dupe(u8, args[index]);
        } else if (std.mem.eql(u8, args[index], "--points")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            config.points = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--repetitions")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            config.repetitions = try std.fmt.parseInt(usize, args[index], 10);
        } else {
            return error.InvalidArguments;
        }
    }
    if (config.points < 10_000 or config.repetitions == 0) return error.InvalidArguments;
    return config;
}

fn runAppendMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: append\n", .{});
    const batch_sizes = [_]usize{ 1, 16, 64, 256, 1_000, 4_096, 65_536 };
    const dataset = try makeDataset(allocator, config.points, .dense, .smooth);
    defer dataset.deinit(allocator);
    inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
        for (batch_sizes) |batch_size| {
            const path = ".profile-internal-append.ctdb";
            deleteFile(path);
            defer deleteFile(path);
            var writer = try chronotail.Appender.create(allocator, path, codec);
            var timer = try std.time.Timer.start();
            var offset: usize = 0;
            while (offset < config.points) {
                const end = @min(offset + batch_size, config.points);
                try writer.appendBatch(
                    "telemetry",
                    dataset.timestamps[offset..end],
                    dataset.values[offset..end],
                );
                offset = end;
            }
            try writer.close();
            const elapsed = timer.read();
            try reporter.emit(rateResult(.{
                .group = "append",
                .name = "batch",
                .codec = @tagName(codec),
                .timestamp_pattern = "dense",
                .value_pattern = "smooth",
                .series_count = 1,
                .batch_size = batch_size,
                .operations = config.points,
                .points = config.points,
                .elapsed_ns = elapsed,
                .file_size = try fileSize(path),
            }));
        }
    }

    inline for (std.meta.tags(TimestampPattern)) |timestamp_pattern| {
        inline for (std.meta.tags(ValuePattern)) |value_pattern| {
            const pattern_count = if (config.quick) config.points else @min(config.points, 500_000);
            const pattern_dataset = try makeDataset(
                allocator,
                pattern_count,
                timestamp_pattern,
                value_pattern,
            );
            defer pattern_dataset.deinit(allocator);
            const path = ".profile-internal-append-pattern.ctdb";
            deleteFile(path);
            defer deleteFile(path);
            var writer = try chronotail.Appender.create(allocator, path, .compressed);
            var timer = try std.time.Timer.start();
            try writer.appendBatch(
                "telemetry",
                pattern_dataset.timestamps,
                pattern_dataset.values,
            );
            try writer.close();
            const elapsed = timer.read();
            try reporter.emit(rateResult(.{
                .group = "append",
                .name = "pattern",
                .codec = "compressed",
                .timestamp_pattern = @tagName(timestamp_pattern),
                .value_pattern = @tagName(value_pattern),
                .series_count = 1,
                .batch_size = pattern_count,
                .operations = pattern_count,
                .points = pattern_count,
                .elapsed_ns = elapsed,
                .file_size = try fileSize(path),
            }));
        }
    }

    const series_counts = [_]usize{ 1, 4, 8, 64, 256 };
    for (series_counts) |series_count| {
        const path = ".profile-internal-series.ctdb";
        deleteFile(path);
        defer deleteFile(path);
        var writer = try chronotail.Appender.create(allocator, path, .raw);
        var names: [256][16]u8 = undefined;
        var name_lengths: [256]usize = undefined;
        for (0..series_count) |series_index| {
            name_lengths[series_index] = (try std.fmt.bufPrint(
                &names[series_index],
                "series-{d}",
                .{series_index},
            )).len;
        }
        var timer = try std.time.Timer.start();
        for (0..config.points) |point_index| {
            const series_index = point_index % series_count;
            try writer.append(
                names[series_index][0..name_lengths[series_index]],
                @intCast(point_index / series_count),
                @floatFromInt(point_index),
            );
        }
        try writer.close();
        const elapsed = timer.read();
        try reporter.emit(rateResult(.{
            .group = "append",
            .name = "series-cardinality",
            .codec = "raw",
            .series_count = series_count,
            .batch_size = 1,
            .operations = config.points,
            .points = config.points,
            .elapsed_ns = elapsed,
            .file_size = try fileSize(path),
        }));
    }
}

fn runStorageMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: storage\n", .{});
    const count = if (config.quick) config.points else @min(config.points, 500_000);
    inline for (std.meta.tags(TimestampPattern)) |timestamp_pattern| {
        inline for (std.meta.tags(ValuePattern)) |value_pattern| {
            const dataset = try makeDataset(
                allocator,
                count,
                timestamp_pattern,
                value_pattern,
            );
            defer dataset.deinit(allocator);
            inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
                const path = ".profile-internal-storage.ctdb";
                deleteFile(path);
                defer deleteFile(path);
                var writer = try chronotail.Appender.create(allocator, path, codec);
                try writer.appendBatch("telemetry", dataset.timestamps, dataset.values);
                try writer.close();
                var reader = try chronotail.Reader.open(allocator, path);
                const counts = try reader.codecCounts("telemetry");
                reader.close();
                const size = try fileSize(path);
                try reporter.emit(.{
                    .group = "storage",
                    .name = "encoding",
                    .codec = @tagName(codec),
                    .timestamp_pattern = @tagName(timestamp_pattern),
                    .value_pattern = @tagName(value_pattern),
                    .points = count,
                    .file_size = size,
                    .bytes_per_point = @as(f64, @floatFromInt(size)) /
                        @as(f64, @floatFromInt(count)),
                    .raw_blocks = counts[0],
                    .compressed_blocks = counts[1],
                });
            }
        }
    }
}

fn runQueryMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: queries\n", .{});
    const combinations = [_]struct { TimestampPattern, ValuePattern }{
        .{ .dense, .smooth },
        .{ .dense, .random },
        .{ .sparse, .spiky },
        .{ .irregular, .smooth },
    };
    const widths = [_]usize{ 1, 10, 100, 1_000, 10_000, 100_000 };
    for (combinations) |patterns| {
        const dataset = try makeDataset(allocator, config.points, patterns[0], patterns[1]);
        defer dataset.deinit(allocator);
        inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
            const path = ".profile-internal-query.ctdb";
            deleteFile(path);
            defer deleteFile(path);
            try writeDataset(allocator, path, codec, dataset, 4_096);
            var reader = try chronotail.Reader.open(allocator, path);
            defer reader.close();

            const middle = config.points / 2;
            const cold = try reader.profileRange(
                "telemetry",
                dataset.timestamps[middle],
                dataset.timestamps[@min(middle + 99, config.points - 1)],
            );
            const warm = try reader.profileRange(
                "telemetry",
                dataset.timestamps[middle],
                dataset.timestamps[@min(middle + 99, config.points - 1)],
            );
            try reporter.emit(.{
                .group = "query-profile",
                .name = "first-touch",
                .codec = @tagName(codec),
                .timestamp_pattern = @tagName(patterns[0]),
                .value_pattern = @tagName(patterns[1]),
                .width = 100,
                .detail_a = cold.block_lookup_ns + cold.file_read_ns +
                    cold.checksum_ns + cold.record_decode_ns,
                .detail_b = warm.block_lookup_ns + warm.file_read_ns +
                    warm.checksum_ns + warm.record_decode_ns,
            });

            for (widths) |requested_width| {
                const width = @min(requested_width, config.points);
                const query_count = queryCount(config, width, codec);
                const timestamps = try allocator.alloc(i64, width);
                defer allocator.free(timestamps);
                const values = try allocator.alloc(f64, width);
                defer allocator.free(values);
                const latencies = try allocator.alloc(u64, query_count);
                defer allocator.free(latencies);
                var random_state: u64 = 0xd1b54a32d192ed03;
                var digest: u64 = 0;
                var query_timer = try std.time.Timer.start();
                var total_timer = try std.time.Timer.start();
                for (latencies) |*latency| {
                    random_state = nextRandom(random_state);
                    const start_index = random_state % (config.points - width + 1);
                    query_timer.reset();
                    const found = try reader.rangeInto(
                        "telemetry",
                        dataset.timestamps[start_index],
                        dataset.timestamps[start_index + width - 1],
                        timestamps,
                        values,
                    );
                    latency.* = query_timer.read();
                    if (found != width) return error.UnexpectedQueryResult;
                    digest +%= @bitCast(values[width - 1]);
                }
                const elapsed = total_timer.read();
                std.mem.doNotOptimizeAway(digest);
                std.sort.heap(u64, latencies, {}, std.sort.asc(u64));
                try reporter.emit(rateResult(withLatencies(.{
                    .group = "query",
                    .name = "range",
                    .codec = @tagName(codec),
                    .timestamp_pattern = @tagName(patterns[0]),
                    .value_pattern = @tagName(patterns[1]),
                    .width = width,
                    .operations = query_count,
                    .points = query_count * width,
                    .elapsed_ns = elapsed,
                }, latencies)));
            }

            const count_queries = queryCount(config, 100, codec);
            var count_state: u64 = 0x9e3779b97f4a7c15;
            var count_digest: usize = 0;
            var count_timer = try std.time.Timer.start();
            for (0..count_queries) |_| {
                count_state = nextRandom(count_state);
                const start_index = count_state % (config.points - 99);
                count_digest +%= try reader.range(
                    "telemetry",
                    dataset.timestamps[start_index],
                    dataset.timestamps[start_index + 99],
                    null,
                );
            }
            const count_elapsed = count_timer.read();
            std.mem.doNotOptimizeAway(count_digest);
            try reporter.emit(rateResult(.{
                .group = "query",
                .name = "range-count-only",
                .codec = @tagName(codec),
                .timestamp_pattern = @tagName(patterns[0]),
                .value_pattern = @tagName(patterns[1]),
                .width = 100,
                .operations = count_queries,
                .points = count_queries * 100,
                .elapsed_ns = count_elapsed,
            }));

            const full_scans: usize = if (config.quick) 3 else 20;
            var digest: usize = 0;
            var timer = try std.time.Timer.start();
            for (0..full_scans) |_| {
                digest +%= try reader.range(
                    "telemetry",
                    dataset.timestamps[0],
                    dataset.timestamps[config.points - 1],
                    null,
                );
            }
            const elapsed = timer.read();
            std.mem.doNotOptimizeAway(digest);
            try reporter.emit(rateResult(.{
                .group = "query",
                .name = "full-scan-count",
                .codec = @tagName(codec),
                .timestamp_pattern = @tagName(patterns[0]),
                .value_pattern = @tagName(patterns[1]),
                .width = config.points,
                .operations = full_scans,
                .points = full_scans * config.points,
                .elapsed_ns = elapsed,
            }));
        }
    }
}

fn runSeriesLookupMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: series-lookups\n", .{});
    const series_counts = [_]usize{ 1, 4, 8, 64, 256 };
    for (series_counts) |series_count| {
        const path = ".profile-internal-series-query.ctdb";
        deleteFile(path);
        defer deleteFile(path);
        var names: [256][16]u8 = undefined;
        var name_lengths: [256]usize = undefined;
        var writer = try chronotail.Appender.create(allocator, path, .raw);
        const points_per_series = @max(1_000, config.points / series_count);
        for (0..series_count) |series_index| {
            name_lengths[series_index] = (try std.fmt.bufPrint(
                &names[series_index],
                "series-{d}",
                .{series_index},
            )).len;
            for (0..points_per_series) |point_index| {
                try writer.append(
                    names[series_index][0..name_lengths[series_index]],
                    @intCast(point_index),
                    @floatFromInt(point_index),
                );
            }
        }
        try writer.close();
        var reader = try chronotail.Reader.open(allocator, path);
        defer reader.close();
        var timestamps: [1]i64 = undefined;
        var values: [1]f64 = undefined;
        var handles: [256]chronotail.SeriesHandle = undefined;
        for (0..series_count) |series_index| {
            handles[series_index] = try reader.prepare(
                names[series_index][0..name_lengths[series_index]],
            );
        }
        const query_count: usize = if (config.quick) 20_000 else 500_000;
        var state: u64 = 0xa0761d6478bd642f;
        var digest: u64 = 0;
        var timer = try std.time.Timer.start();
        for (0..query_count) |_| {
            state = nextRandom(state);
            const series_index = state % series_count;
            state = nextRandom(state);
            const point_index = state % points_per_series;
            const found = try reader.rangeInto(
                names[series_index][0..name_lengths[series_index]],
                @intCast(point_index),
                @intCast(point_index),
                &timestamps,
                &values,
            );
            if (found != 1) return error.UnexpectedQueryResult;
            digest +%= @bitCast(values[0]);
        }
        const elapsed = timer.read();
        std.mem.doNotOptimizeAway(digest);
        try reporter.emit(rateResult(.{
            .group = "query",
            .name = "series-lookup-point",
            .codec = "raw",
            .series_count = series_count,
            .width = 1,
            .operations = query_count,
            .points = query_count,
            .elapsed_ns = elapsed,
        }));

        state = 0xa0761d6478bd642f;
        digest = 0;
        timer.reset();
        for (0..query_count) |_| {
            state = nextRandom(state);
            const series_index = state % series_count;
            state = nextRandom(state);
            const point_index = state % points_per_series;
            const found = try reader.rangePreparedInto(
                handles[series_index],
                @intCast(point_index),
                @intCast(point_index),
                &timestamps,
                &values,
            );
            if (found != 1) return error.UnexpectedQueryResult;
            digest +%= @bitCast(values[0]);
        }
        const prepared_elapsed = timer.read();
        std.mem.doNotOptimizeAway(digest);
        try reporter.emit(rateResult(.{
            .group = "query",
            .name = "prepared-series-point",
            .codec = "raw",
            .series_count = series_count,
            .width = 1,
            .operations = query_count,
            .points = query_count,
            .elapsed_ns = prepared_elapsed,
        }));
    }
}

fn runAggregateMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: aggregates\n", .{});
    const dataset = try makeDataset(allocator, config.points, .dense, .smooth);
    defer dataset.deinit(allocator);
    const widths = [_]usize{ 100, 10_000, config.points };
    inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
        const path = ".profile-internal-aggregate.ctdb";
        deleteFile(path);
        defer deleteFile(path);
        try writeDataset(allocator, path, codec, dataset, 4_096);
        var reader = try chronotail.Reader.open(allocator, path);
        defer reader.close();
        const handle = try reader.prepare("telemetry");
        for (widths) |requested_width| {
            const width = @min(requested_width, config.points);
            const query_count = queryCount(config, width, codec);
            var state: u64 = 0x8ebc6af09c88c6e3;
            var digest: u64 = 0;
            var timer = try std.time.Timer.start();
            for (0..query_count) |_| {
                state = nextRandom(state);
                const start_index = state % (config.points - width + 1);
                const result = try reader.aggregatePrepared(
                    handle,
                    dataset.timestamps[start_index],
                    dataset.timestamps[start_index + width - 1],
                );
                if (result.count != width) return error.UnexpectedQueryResult;
                digest +%= @bitCast(result.sum);
            }
            const elapsed = timer.read();
            std.mem.doNotOptimizeAway(digest);
            try reporter.emit(rateResult(.{
                .group = "aggregate",
                .name = "summary-tree",
                .codec = @tagName(codec),
                .width = width,
                .operations = query_count,
                .points = query_count * width,
                .elapsed_ns = elapsed,
            }));
        }

        // A resolution wider than a data page exercises subtree-summary skipping;
        // tiny windows deliberately devolve to boundary-page decoding.
        const window_count: usize = 10;
        const resolution: u64 = @intCast(config.points / window_count);
        const windows = try allocator.alloc(chronotail.Aggregate, window_count);
        defer allocator.free(windows);
        const iterations: usize = if (config.quick) 100 else 10_000;
        var digest: u64 = 0;
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const found = try reader.aggregateWindowsPrepared(
                handle,
                dataset.timestamps[0],
                dataset.timestamps[dataset.timestamps.len - 1],
                resolution,
                windows,
            );
            if (found != window_count) return error.UnexpectedQueryResult;
            digest +%= @bitCast(windows[window_count - 1].sum);
        }
        const elapsed = timer.read();
        std.mem.doNotOptimizeAway(digest);
        try reporter.emit(rateResult(.{
            .group = "aggregate",
            .name = "resolution-windows",
            .codec = @tagName(codec),
            .width = resolution,
            .operations = iterations * window_count,
            .points = iterations * config.points,
            .elapsed_ns = elapsed,
        }));
    }
}

fn runCheckpointMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: checkpoints\n", .{});
    const checkpoint_count: usize = if (config.quick) 70 else 260;
    const points_per_checkpoint: usize = if (config.quick) 256 else 4_096;
    const timestamps = try allocator.alloc(i64, points_per_checkpoint);
    defer allocator.free(timestamps);
    const values = try allocator.alloc(f64, points_per_checkpoint);
    defer allocator.free(values);
    const latencies = try allocator.alloc(u64, checkpoint_count);
    defer allocator.free(latencies);

    inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
        const path = ".profile-internal-checkpoint.ctdb";
        deleteFile(path);
        defer deleteFile(path);
        var writer = try chronotail.Appender.create(allocator, path, codec);
        var next_timestamp: i64 = 0;
        var checkpoint_timer = try std.time.Timer.start();
        var total_timer = try std.time.Timer.start();
        var snapshot_latencies: [5]u64 = undefined;
        var snapshot_count: usize = 0;
        var delta_latencies: [260]u64 = undefined;
        var delta_count: usize = 0;
        for (latencies, 0..) |*latency, checkpoint_index| {
            for (timestamps, values) |*timestamp, *value| {
                timestamp.* = next_timestamp;
                value.* = 42.0 + @as(f64, @floatFromInt(@mod(next_timestamp, 1_000))) * 0.001;
                next_timestamp += 1;
            }
            try writer.appendBatch("telemetry", timestamps, values);
            checkpoint_timer.reset();
            try writer.checkpoint(false);
            latency.* = checkpoint_timer.read();
            if (checkpoint_index % 64 == 0) {
                snapshot_latencies[snapshot_count] = latency.*;
                snapshot_count += 1;
            } else {
                delta_latencies[delta_count] = latency.*;
                delta_count += 1;
            }
        }
        const elapsed = total_timer.read();
        try writer.close();
        std.sort.heap(u64, latencies, {}, std.sort.asc(u64));
        try reporter.emit(rateResult(withLatencies(.{
            .group = "checkpoint",
            .name = "unsynced",
            .codec = @tagName(codec),
            .batch_size = points_per_checkpoint,
            .operations = checkpoint_count,
            .points = checkpoint_count * points_per_checkpoint,
            .elapsed_ns = elapsed,
            .file_size = try fileSize(path),
        }, latencies)));
        std.sort.heap(u64, snapshot_latencies[0..snapshot_count], {}, std.sort.asc(u64));
        std.sort.heap(u64, delta_latencies[0..delta_count], {}, std.sort.asc(u64));
        try reporter.emit(withLatencies(.{
            .group = "checkpoint",
            .name = "snapshot-only",
            .codec = @tagName(codec),
            .batch_size = points_per_checkpoint,
            .operations = snapshot_count,
        }, snapshot_latencies[0..snapshot_count]));
        try reporter.emit(withLatencies(.{
            .group = "checkpoint",
            .name = "delta-only",
            .codec = @tagName(codec),
            .batch_size = points_per_checkpoint,
            .operations = delta_count,
        }, delta_latencies[0..delta_count]));
    }

    const path = ".profile-internal-checkpoint-sync.ctdb";
    deleteFile(path);
    defer deleteFile(path);
    var writer = try chronotail.Appender.create(allocator, path, .raw);
    const sync_count: usize = if (config.quick) 4 else 16;
    var sync_latencies: [16]u64 = undefined;
    var sync_elapsed: u64 = 0;
    var timestamp_base: i64 = 0;
    for (sync_latencies[0..sync_count]) |*latency| {
        for (timestamps, values, 0..) |*timestamp, *value, index| {
            timestamp.* = timestamp_base + @as(i64, @intCast(index));
            value.* = @floatFromInt(index);
        }
        timestamp_base += @intCast(points_per_checkpoint);
        try writer.appendBatch("telemetry", timestamps, values);
        var timer = try std.time.Timer.start();
        try writer.checkpoint(true);
        latency.* = timer.read();
        sync_elapsed += latency.*;
    }
    try writer.close();
    std.sort.heap(u64, sync_latencies[0..sync_count], {}, std.sort.asc(u64));
    try reporter.emit(rateResult(withLatencies(.{
        .group = "checkpoint",
        .name = "fsync",
        .codec = "raw",
        .batch_size = points_per_checkpoint,
        .operations = sync_count,
        .points = sync_count * points_per_checkpoint,
        .elapsed_ns = sync_elapsed,
    }, sync_latencies[0..sync_count])));
}

fn runControlPlaneMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: control-plane\n", .{});
    const dataset = try makeDataset(allocator, config.points, .dense, .smooth);
    defer dataset.deinit(allocator);
    const path = ".profile-internal-control.ctdb";
    deleteFile(path);
    defer deleteFile(path);
    try writeDataset(allocator, path, .compressed, dataset, 4_096);

    const open_count: usize = if (config.quick) 50 else 500;
    const open_latencies = try allocator.alloc(u64, open_count);
    defer allocator.free(open_latencies);
    for (open_latencies) |*latency| {
        var timer = try std.time.Timer.start();
        var reader = try chronotail.Reader.open(allocator, path);
        latency.* = timer.read();
        reader.close();
    }
    std.sort.heap(u64, open_latencies, {}, std.sort.asc(u64));
    try reporter.emit(withLatencies(.{
        .group = "control-plane",
        .name = "reader-open",
        .codec = "compressed",
        .operations = open_count,
    }, open_latencies));

    var reader = try chronotail.Reader.open(allocator, path);
    defer reader.close();
    const refresh_count: usize = if (config.quick) 10_000 else 1_000_000;
    var changed: usize = 0;
    var timer = try std.time.Timer.start();
    for (0..refresh_count) |_| if (try reader.refresh()) {
        changed += 1;
    };
    const refresh_elapsed = timer.read();
    std.mem.doNotOptimizeAway(changed);
    try reporter.emit(rateResult(.{
        .group = "control-plane",
        .name = "refresh-unchanged",
        .operations = refresh_count,
        .elapsed_ns = refresh_elapsed,
    }));

    inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |verify_codec| {
        const verify_path = ".profile-internal-verify.ctdb";
        deleteFile(verify_path);
        defer deleteFile(verify_path);
        try writeDataset(allocator, verify_path, verify_codec, dataset, 4_096);
        timer.reset();
        const report = try chronotail.verifyPath(allocator, verify_path);
        const verify_elapsed = timer.read();
        std.mem.doNotOptimizeAway(report);
        try reporter.emit(rateResult(.{
            .group = "control-plane",
            .name = "verify",
            .codec = @tagName(verify_codec),
            .operations = 1,
            .points = config.points,
            .elapsed_ns = verify_elapsed,
            .file_size = try fileSize(verify_path),
        }));
    }

    var changed_writer = try chronotail.Appender.open(allocator, path, .compressed);
    const last_timestamp = dataset.timestamps[dataset.timestamps.len - 1];
    try changed_writer.append("telemetry", last_timestamp + 1, 43.0);
    try changed_writer.checkpoint(false);
    timer.reset();
    const did_change = try reader.refresh();
    const changed_elapsed = timer.read();
    if (!did_change) return error.ExpectedRefresh;
    try reporter.emit(rateResult(.{
        .group = "control-plane",
        .name = "refresh-changed",
        .operations = 1,
        .elapsed_ns = changed_elapsed,
    }));
    try changed_writer.close();

    const trailing_sizes = [_]usize{ 64 * 1024, 1024 * 1024, 16 * 1024 * 1024 };
    for (trailing_sizes) |trailing_size| {
        try appendZeros(path, trailing_size);
        timer.reset();
        var recovered = try chronotail.Reader.open(allocator, path);
        const recovery_elapsed = timer.read();
        recovered.close();
        try reporter.emit(rateResult(.{
            .group = "control-plane",
            .name = "recover-trailing-data",
            .operations = 1,
            .elapsed_ns = recovery_elapsed,
            .detail_a = trailing_size,
        }));
    }
}

fn runAllocationMatrix(config: Config, reporter: *Reporter) !void {
    std.debug.print("phase: allocations\n", .{});
    var counter = CountingAllocator{ .backing = std.heap.page_allocator };
    const allocator = counter.allocator();
    const count = if (config.quick) 20_000 else config.points;
    const dataset = try makeDataset(allocator, count, .dense, .smooth);
    defer dataset.deinit(allocator);
    const path = ".profile-internal-allocations.ctdb";
    deleteFile(path);
    defer deleteFile(path);
    var writer = try chronotail.Appender.create(allocator, path, .raw);
    try writer.prepareSeries("telemetry", count);
    counter.resetMeasurements();
    try writer.appendBatch("telemetry", dataset.timestamps, dataset.values);
    try emitAllocationResult(reporter, "append-after-create", count, count, &counter);
    try writer.close();

    var reader = try chronotail.Reader.open(allocator, path);
    const handle = try reader.prepare("telemetry");
    const timestamps: [100]i64 = undefined;
    const values: [100]f64 = undefined;
    var output_timestamps = timestamps;
    var output_values = values;
    counter.resetMeasurements();
    var digest: usize = 0;
    for (0..10_000) |index| {
        const start: i64 = @intCast(index % (count - 100));
        digest +%= try reader.rangeInto(
            "telemetry",
            start,
            start + 99,
            &output_timestamps,
            &output_values,
        );
    }
    std.mem.doNotOptimizeAway(digest);
    try emitAllocationResult(reporter, "warm-query", 10_000, 1_000_000, &counter);

    counter.resetMeasurements();
    digest = 0;
    for (0..10_000) |query_index| {
        const start: i64 = @intCast(query_index % (count - 100));
        digest +%= try reader.rangePreparedInto(
            handle,
            start,
            start + 99,
            &output_timestamps,
            &output_values,
        );
    }
    std.mem.doNotOptimizeAway(digest);
    try emitAllocationResult(reporter, "prepared-query", 10_000, 1_000_000, &counter);

    counter.resetMeasurements();
    var cursor = try reader.cursorPrepared(handle, 0, @intCast(count - 1));
    digest = 0;
    while (true) {
        const found = try reader.cursorNext(&cursor, &output_timestamps, &output_values);
        if (found == 0) break;
        digest +%= @bitCast(output_values[found - 1]);
    }
    std.mem.doNotOptimizeAway(digest);
    try emitAllocationResult(
        reporter,
        "persistent-cursor",
        (count + output_values.len - 1) / output_values.len,
        count,
        &counter,
    );

    counter.resetMeasurements();
    digest = 0;
    const borrow_iterations: usize = if (config.quick) 10_000 else 100_000;
    for (0..borrow_iterations) |borrow_index| {
        const point_index = borrow_index % count;
        const borrowed = try reader.borrowRawPage(handle, @intCast(point_index));
        digest +%= @bitCast(borrowed.values[point_index % borrowed.values.len]);
    }
    std.mem.doNotOptimizeAway(digest);
    try emitAllocationResult(
        reporter,
        "borrow-raw-page",
        borrow_iterations,
        borrow_iterations,
        &counter,
    );

    counter.resetMeasurements();
    digest = 0;
    const aggregate_iterations: usize = if (config.quick) 10_000 else 100_000;
    for (0..aggregate_iterations) |_| {
        const aggregate = try reader.aggregatePrepared(handle, 0, @intCast(count - 1));
        digest +%= @bitCast(aggregate.sum);
    }
    std.mem.doNotOptimizeAway(digest);
    try emitAllocationResult(
        reporter,
        "aggregate-summary",
        aggregate_iterations,
        aggregate_iterations * count,
        &counter,
    );

    counter.resetMeasurements();
    digest = 0;
    var windows: [10]chronotail.Aggregate = undefined;
    const resolution: u64 = @intCast(count / windows.len);
    const window_iterations: usize = if (config.quick) 1_000 else 10_000;
    for (0..window_iterations) |_| {
        const found = try reader.aggregateWindowsPrepared(
            handle,
            0,
            @intCast(count - 1),
            resolution,
            &windows,
        );
        if (found != windows.len) return error.UnexpectedQueryResult;
        digest +%= @bitCast(windows[windows.len - 1].sum);
    }
    std.mem.doNotOptimizeAway(digest);
    try emitAllocationResult(
        reporter,
        "aggregate-windows",
        window_iterations * windows.len,
        window_iterations * count,
        &counter,
    );

    counter.resetMeasurements();
    const refresh_iterations: usize = if (config.quick) 10_000 else 100_000;
    for (0..refresh_iterations) |_| {
        if (try reader.refresh()) return error.UnexpectedRefresh;
    }
    try emitAllocationResult(
        reporter,
        "unchanged-refresh",
        refresh_iterations,
        0,
        &counter,
    );
    reader.close();
}

fn emitAllocationResult(
    reporter: *Reporter,
    name: []const u8,
    operations: usize,
    points: usize,
    counter: *const CountingAllocator,
) !void {
    try reporter.emit(.{
        .group = "allocation",
        .name = name,
        .codec = "raw",
        .operations = operations,
        .points = points,
        .allocation_calls = counter.allocation_calls,
        .resize_calls = counter.resize_calls,
        .remap_calls = counter.remap_calls,
        .free_calls = counter.free_calls,
        .allocated_bytes = counter.allocated_bytes,
        .live_bytes = counter.live_bytes,
        .peak_live_bytes = counter.peak_live_bytes,
    });
}

const ReaderThreadContext = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    points: usize,
    iterations: usize,
    thread_index: usize,
    operations: u64 = 0,
    digest: u64 = 0,
    failure: ?anyerror = null,
};

fn readerThread(context: *ReaderThreadContext) void {
    var reader = chronotail.Reader.open(context.allocator, context.path) catch |err| {
        context.failure = err;
        return;
    };
    defer reader.close();
    var timestamps: [100]i64 = undefined;
    var values: [100]f64 = undefined;
    var state: u64 = 0xd1b54a32d192ed03 +% context.thread_index;
    for (0..context.iterations) |_| {
        state = nextRandom(state);
        const start: i64 = @intCast(state % (context.points - 99));
        const found = reader.rangeInto(
            "telemetry",
            start,
            start + 99,
            &timestamps,
            &values,
        ) catch |err| {
            context.failure = err;
            return;
        };
        if (found != 100) {
            context.failure = error.UnexpectedQueryResult;
            return;
        }
        context.digest +%= @bitCast(values[99]);
        context.operations += 1;
    }
}

fn runParallelReaderMatrix(
    allocator: std.mem.Allocator,
    config: Config,
    reporter: *Reporter,
) !void {
    std.debug.print("phase: parallel-readers\n", .{});
    const dataset = try makeDataset(allocator, config.points, .dense, .smooth);
    defer dataset.deinit(allocator);
    const path = ".profile-internal-parallel.ctdb";
    deleteFile(path);
    defer deleteFile(path);
    try writeDataset(allocator, path, .raw, dataset, 4_096);
    const reader_counts = [_]usize{ 1, 2, 4, 8, 16, 32 };
    for (reader_counts) |reader_count| {
        const total_iterations: usize = if (config.quick) 20_000 else 1_000_000;
        const iterations = @max(1, total_iterations / reader_count);
        var contexts: [32]ReaderThreadContext = undefined;
        var threads: [32]std.Thread = undefined;
        var timer = try std.time.Timer.start();
        for (0..reader_count) |thread_index| {
            contexts[thread_index] = .{
                .allocator = allocator,
                .path = path,
                .points = config.points,
                .iterations = iterations,
                .thread_index = thread_index,
            };
            threads[thread_index] = try std.Thread.spawn(
                .{},
                readerThread,
                .{&contexts[thread_index]},
            );
        }
        var operations: u64 = 0;
        var digest: u64 = 0;
        for (0..reader_count) |thread_index| {
            threads[thread_index].join();
            if (contexts[thread_index].failure) |err| return err;
            operations += contexts[thread_index].operations;
            digest +%= contexts[thread_index].digest;
        }
        const elapsed = timer.read();
        std.mem.doNotOptimizeAway(digest);
        try reporter.emit(rateResult(.{
            .group = "concurrency",
            .name = "parallel-readers",
            .codec = "raw",
            .series_count = reader_count,
            .width = 100,
            .operations = operations,
            .points = operations * 100,
            .elapsed_ns = elapsed,
        }));
    }
}

fn makeDataset(
    allocator: std.mem.Allocator,
    count: usize,
    timestamp_pattern: TimestampPattern,
    value_pattern: ValuePattern,
) !Dataset {
    const timestamps = try allocator.alloc(i64, count);
    errdefer allocator.free(timestamps);
    const values = try allocator.alloc(f64, count);
    errdefer allocator.free(values);
    var state: u64 = 0xa0761d6478bd642f;
    var timestamp: i64 = -1;
    for (timestamps, values, 0..) |*stored_timestamp, *value, index| {
        state = nextRandom(state);
        timestamp += switch (timestamp_pattern) {
            .dense => 1,
            .sparse => 1_000,
            .irregular => @intCast(state % 100 + 1),
        };
        stored_timestamp.* = timestamp;
        value.* = switch (value_pattern) {
            .constant => 42.0,
            .smooth => 42.0 + @as(f64, @floatFromInt(index % 1_000)) * 0.001,
            .spiky => if (index % 1_000 == 0)
                @as(f64, @floatFromInt(index))
            else
                42.0,
            .random => blk: {
                state = nextRandom(state);
                break :blk @bitCast(state);
            },
        };
    }
    return .{ .timestamps = timestamps, .values = values };
}

fn writeDataset(
    allocator: std.mem.Allocator,
    path: []const u8,
    codec: chronotail.Codec,
    dataset: Dataset,
    batch_size: usize,
) !void {
    deleteFile(path);
    var writer = try chronotail.Appender.create(allocator, path, codec);
    var offset: usize = 0;
    while (offset < dataset.timestamps.len) {
        const end = @min(offset + batch_size, dataset.timestamps.len);
        try writer.appendBatch(
            "telemetry",
            dataset.timestamps[offset..end],
            dataset.values[offset..end],
        );
        offset = end;
    }
    try writer.close();
}

fn queryCount(config: Config, width: usize, codec: chronotail.Codec) usize {
    const target_points: usize = if (config.quick)
        1_000_000
    else if (codec == .compressed)
        20_000_000
    else
        50_000_000;
    const maximum: usize = if (config.quick) 20_000 else 500_000;
    return std.math.clamp(target_points / width, 20, maximum);
}

fn withLatencies(result: Result, latencies: []const u64) Result {
    var updated = result;
    updated.p50_ns = percentile(latencies, 50);
    updated.p95_ns = percentile(latencies, 95);
    updated.p99_ns = percentile(latencies, 99);
    updated.max_ns = latencies[latencies.len - 1];
    return updated;
}

fn percentile(sorted: []const u64, percent: usize) u64 {
    return sorted[@min(sorted.len - 1, (sorted.len * percent) / 100)];
}

fn rateResult(result: Result) Result {
    var updated = result;
    if (result.elapsed_ns == 0) return updated;
    const seconds = @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_s;
    updated.operations_per_second = @as(f64, @floatFromInt(result.operations)) / seconds;
    updated.points_per_second = @as(f64, @floatFromInt(result.points)) / seconds;
    if (result.points > 0 and result.file_size > 0) {
        updated.bytes_per_point = @as(f64, @floatFromInt(result.file_size)) /
            @as(f64, @floatFromInt(result.points));
    }
    return updated;
}

fn appendZeros(path: []const u8, count: usize) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    var zeros: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var remaining = count;
    while (remaining > 0) {
        const amount = @min(remaining, zeros.len);
        try file.writeAll(zeros[0..amount]);
        remaining -= amount;
    }
}

fn fileSize(path: []const u8) !u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.getEndPos();
}

fn deleteFile(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

fn nextRandom(state: u64) u64 {
    return state *% 6364136223846793005 +% 1442695040888963407;
}
