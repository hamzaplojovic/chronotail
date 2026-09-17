const std = @import("std");
const chronotail = @import("chronotail");

const max_series = 8;
const probability_scale = 1_000_000;

const ValuePattern = enum { smooth, random, constant, spiky };
const TimestampPattern = enum { dense, sparse, irregular };
const Fault = enum {
    process_crash,
    power_loss,
    short_write,
    write_failure,
    truncation,
    corruption,
};

const SimConfig = struct {
    operation_count: u64,
    series_count: u32,
    checkpoint_probability: u32,
    reopen_probability: u32,
    refresh_probability: u32,
    range_query_probability: u32,
    short_write_probability: u32,
    write_failure_probability: u32,
    truncation_probability: u32,
    corruption_probability: u32,
    crash_probability: u32,
    max_batch_size: usize,
    max_range_width: usize,
    value_pattern: ValuePattern,
    timestamp_pattern: TimestampPattern,
    codec: chronotail.Codec,
};

const Stats = struct {
    operations: u64 = 0,
    crashes: u64 = 0,
    short_writes: u64 = 0,
    failed_writes: u64 = 0,
    truncations: u64 = 0,
    corruptions: u64 = 0,
    checkpoint_reopens: u64 = 0,
    invariant_failures: u64 = 0,
    digest: u64 = 14695981039346656037,

    fn add(self: *Stats, other: Stats) void {
        self.operations += other.operations;
        self.crashes += other.crashes;
        self.short_writes += other.short_writes;
        self.failed_writes += other.failed_writes;
        self.truncations += other.truncations;
        self.corruptions += other.corruptions;
        self.checkpoint_reopens += other.checkpoint_reopens;
        self.invariant_failures += other.invariant_failures;
        self.digest ^= other.digest;
    }
};

const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }

    fn below(self: *Rng, limit: u64) u64 {
        return if (limit == 0) 0 else self.next() % limit;
    }

    fn chance(self: *Rng, probability: u32) bool {
        return self.below(probability_scale) < probability;
    }
};

fn derive(root: u64, domain: u64) Rng {
    var rng = Rng{ .state = root ^ domain };
    return .{ .state = rng.next() };
}

const MemoryStorage = struct {
    allocator: std.mem.Allocator,
    dirty: std.ArrayList(u8) = .empty,
    durable: std.ArrayList(u8) = .empty,
    faults_enabled: bool = false,
    fault_rng: Rng,
    config: SimConfig,
    last_fault: ?Fault = null,
    fault_on_sync: bool = false,
    stats: *Stats,

    fn deinit(self: *MemoryStorage) void {
        self.dirty.deinit(self.allocator);
        self.durable.deinit(self.allocator);
    }

    fn file(self: *MemoryStorage) MemoryFile {
        return .{ .storage = self };
    }

    fn beforeWrite(self: *MemoryStorage, bytes: []const u8, offset: u64) !?usize {
        self.last_fault = null;
        self.fault_on_sync = false;
        if (!self.faults_enabled) return null;
        if (self.fault_rng.chance(self.config.crash_probability)) {
            const power = (self.fault_rng.next() & 1) == 0;
            self.last_fault = if (power) .power_loss else .process_crash;
            self.stats.crashes += 1;
            return error.SimulatedCrash;
        }
        if (self.fault_rng.chance(self.config.write_failure_probability)) {
            self.last_fault = .write_failure;
            self.stats.failed_writes += 1;
            return error.SimulatedWriteFailure;
        }
        if (bytes.len > 1 and self.fault_rng.chance(self.config.short_write_probability)) {
            const amount = 1 + self.fault_rng.below(bytes.len - 1);
            try self.writeBytes(bytes[0..amount], offset);
            self.last_fault = .short_write;
            self.stats.short_writes += 1;
            return error.SimulatedShortWrite;
        }
        return null;
    }

    fn writeBytes(self: *MemoryStorage, bytes: []const u8, offset: u64) !void {
        const start: usize = @intCast(offset);
        const end = start + bytes.len;
        if (end > self.dirty.items.len) {
            const old_len = self.dirty.items.len;
            try self.dirty.resize(self.allocator, end);
            @memset(self.dirty.items[old_len..], 0);
        }
        @memcpy(self.dirty.items[start..end], bytes);
    }

    fn sync(self: *MemoryStorage) !void {
        self.last_fault = null;
        self.fault_on_sync = false;
        if (self.faults_enabled and self.fault_rng.chance(self.config.crash_probability)) {
            const power = (self.fault_rng.next() & 1) == 0;
            self.last_fault = if (power) .power_loss else .process_crash;
            self.fault_on_sync = true;
            self.stats.crashes += 1;
            return error.SimulatedCrash;
        }
        try self.durable.resize(self.allocator, self.dirty.items.len);
        @memcpy(self.durable.items, self.dirty.items);
    }

    fn crash(self: *MemoryStorage, power_loss: bool) !void {
        if (power_loss) {
            try self.dirty.resize(self.allocator, self.durable.items.len);
            @memcpy(self.dirty.items, self.durable.items);
        }
        self.last_fault = null;
    }
};

const MemoryFile = struct {
    storage: *MemoryStorage,

    pub fn pwriteAll(self: MemoryFile, bytes: []const u8, offset: u64) !void {
        _ = try self.storage.beforeWrite(bytes, offset);
        try self.storage.writeBytes(bytes, offset);
    }

    pub fn preadAll(self: MemoryFile, output: []u8, offset: u64) !usize {
        const start: usize = @intCast(offset);
        if (start >= self.storage.dirty.items.len) return 0;
        const amount = @min(output.len, self.storage.dirty.items.len - start);
        @memcpy(output[0..amount], self.storage.dirty.items[start .. start + amount]);
        return amount;
    }

    pub fn getEndPos(self: MemoryFile) !u64 {
        return self.storage.dirty.items.len;
    }

    pub fn sync(self: MemoryFile) !void {
        try self.storage.sync();
    }

    pub fn close(_: MemoryFile) void {}
};

const SimAppender = chronotail.AppenderFor(MemoryFile);
const SimReader = chronotail.ReaderFor(MemoryFile);

const Point = struct { timestamp: i64, value: f64 };
const ModelSeries = struct {
    name: []u8,
    points: std.ArrayList(Point) = .empty,
};
const Snapshot = struct {
    counts: [max_series]usize = [_]usize{0} ** max_series,
    end_size: usize,
};

const Model = struct {
    allocator: std.mem.Allocator,
    series: [max_series]ModelSeries = undefined,
    count: usize,
    history: std.ArrayList(Snapshot) = .empty,
    current_generation: usize = 0,
    durable_generation: usize = 0,
    reader_counts: [max_series]usize = [_]usize{0} ** max_series,

    fn init(allocator: std.mem.Allocator, count: usize, rng: *Rng) !Model {
        var model = Model{ .allocator = allocator, .count = count };
        var initialized: usize = 0;
        errdefer {
            for (model.series[0..initialized]) |*series| {
                allocator.free(series.name);
                series.points.deinit(allocator);
            }
        }
        for (0..count) |i| {
            const name = try std.fmt.allocPrint(
                allocator,
                "series-{d}-{x}",
                .{ i, rng.next() & 0xffff },
            );
            model.series[i] = .{ .name = name };
            initialized += 1;
        }
        return model;
    }

    fn deinit(self: *Model) void {
        for (self.series[0..self.count]) |*series| {
            self.allocator.free(series.name);
            series.points.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);
    }

    fn snapshot(self: *Model, end_size: usize, durable: bool) !void {
        var item = Snapshot{ .end_size = end_size };
        for (0..self.count) |i| item.counts[i] = self.series[i].points.items.len;
        try self.history.append(self.allocator, item);
        self.current_generation = self.history.items.len - 1;
        if (durable) self.durable_generation = self.current_generation;
    }

    fn restore(self: *Model, generation: usize) void {
        const committed = self.history.items[generation];
        for (0..self.count) |i| self.series[i].points.shrinkRetainingCapacity(committed.counts[i]);
        self.history.shrinkRetainingCapacity(generation + 1);
        self.current_generation = generation;
        if (self.durable_generation > generation) self.durable_generation = generation;
        self.reader_counts = committed.counts;
    }
};

fn deriveConfig(seed: u64, operations_override: ?u64) SimConfig {
    var rng = derive(seed, 0x434f4e464947);
    return .{
        .operation_count = operations_override orelse 100_000,
        .series_count = @intCast(1 + rng.below(max_series)),
        .checkpoint_probability = @intCast(1500 + rng.below(3500)),
        .reopen_probability = @intCast(200 + rng.below(800)),
        .refresh_probability = @intCast(3000 + rng.below(7000)),
        .range_query_probability = @intCast(10_000 + rng.below(20_000)),
        .short_write_probability = @intCast(100 + rng.below(500)),
        .write_failure_probability = @intCast(100 + rng.below(500)),
        .truncation_probability = @intCast(20 + rng.below(80)),
        .corruption_probability = @intCast(20 + rng.below(80)),
        .crash_probability = @intCast(100 + rng.below(500)),
        .max_batch_size = @intCast(1 + rng.below(16)),
        .max_range_width = @intCast(1 + rng.below(128)),
        .value_pattern = @enumFromInt(rng.below(4)),
        .timestamp_pattern = @enumFromInt(rng.below(3)),
        .codec = if ((rng.next() & 1) == 0) .raw else .compressed,
    };
}

fn nextValue(pattern: ValuePattern, index: usize, rng: *Rng) f64 {
    return switch (pattern) {
        .constant => 42.5,
        .smooth => 20.0 + @as(f64, @floatFromInt(index % 1000)) * 0.001,
        .random => @bitCast(rng.next()),
        .spiky => if (rng.below(100) == 0) @as(f64, @floatFromInt(rng.below(1_000_000))) else 1.0,
    };
}

fn runSeed(
    allocator: std.mem.Allocator,
    seed: u64,
    operations_override: ?u64,
    quiet: bool,
    output_path: ?[]const u8,
) !Stats {
    const config = deriveConfig(seed, operations_override);
    var workload_rng = derive(seed, 0x574f524b4c4f4144);
    const fault_rng = derive(seed, 0x4641554c5453);
    var corruption_rng = derive(seed, 0x434f5252555054);
    var stats = Stats{};
    var storage = MemoryStorage{
        .allocator = allocator,
        .fault_rng = fault_rng,
        .config = config,
        .stats = &stats,
    };
    defer storage.deinit();
    var model = try Model.init(allocator, config.series_count, &workload_rng);
    defer model.deinit();

    var writer = try SimAppender.createOn(allocator, storage.file(), config.codec);
    try writer.checkpoint(true);
    try model.snapshot(storage.dirty.items.len, true);
    var reader = try SimReader.openOn(allocator, storage.file());
    storage.faults_enabled = true;

    for (0..config.operation_count) |operation| {
        stats.operations += 1;
        hashStat(&stats, workload_rng.state ^ operation);

        const has_corruptible_bytes =
            storage.dirty.items.len > chronotail.file_header.len + 1;
        if (corruption_rng.chance(config.corruption_probability) and has_corruptible_bytes) {
            const body_size = storage.dirty.items.len - chronotail.file_header.len;
            const offset = chronotail.file_header.len + corruption_rng.below(body_size);
            const old = storage.dirty.items[offset];
            storage.dirty.items[offset] ^= @as(u8, 1) << @as(u3, @intCast(corruption_rng.below(8)));
            stats.corruptions += 1;
            const series_index: usize = @intCast(corruption_rng.below(model.count));
            verifyRange(
                &reader,
                &model,
                series_index,
                config.max_range_width,
                &corruption_rng,
            ) catch |err| switch (err) {
                error.RangeCountMismatch,
                error.RangeValueMismatch,
                error.TimestampInvariant,
                => return reportFailure(seed, operation, config, .corruption, err),
                else => {},
            };
            storage.dirty.items[offset] = old;
        }

        if (workload_rng.chance(config.truncation_probability) and
            model.history.items.len > 1)
        {
            const target_generation = model.current_generation - 1;
            const target_size = model.history.items[target_generation].end_size;
            if (target_size < storage.dirty.items.len) {
                const truncated_size = target_size +
                    @min(7, storage.dirty.items.len - target_size);
                storage.dirty.shrinkRetainingCapacity(truncated_size);
                if (storage.durable.items.len > truncated_size)
                    storage.durable.shrinkRetainingCapacity(truncated_size);
                stats.truncations += 1;
                storage.last_fault = .truncation;
                recover(&writer, &reader, &storage, &model, config.codec, false) catch |err|
                    return reportFailure(seed, operation, config, storage.last_fault, err);
            }
            continue;
        }

        const selector = workload_rng.below(probability_scale);
        const checkpoint_limit = config.checkpoint_probability;
        const reopen_limit = checkpoint_limit + config.reopen_probability;
        const refresh_limit = reopen_limit + config.refresh_probability;
        const range_limit = refresh_limit + config.range_query_probability;
        if (selector < checkpoint_limit) {
            const do_sync = (workload_rng.next() & 1) == 0;
            storage.last_fault = null;
            writer.checkpoint(do_sync) catch |err| {
                if (storage.last_fault == null)
                    return reportFailure(seed, operation, config, null, err);
                if (storage.last_fault == .process_crash and storage.fault_on_sync)
                    try model.snapshot(storage.dirty.items.len, false);
                recover(
                    &writer,
                    &reader,
                    &storage,
                    &model,
                    config.codec,
                    storage.last_fault == .power_loss,
                ) catch |recover_err|
                    return reportFailure(
                        seed,
                        operation,
                        config,
                        storage.last_fault,
                        recover_err,
                    );
                continue;
            };
            try model.snapshot(storage.dirty.items.len, do_sync);
        } else if (selector < reopen_limit) {
            writer.checkpoint(false) catch |err| {
                if (storage.last_fault == null)
                    return reportFailure(seed, operation, config, null, err);
                recover(
                    &writer,
                    &reader,
                    &storage,
                    &model,
                    config.codec,
                    storage.last_fault == .power_loss,
                ) catch |recover_err|
                    return reportFailure(
                        seed,
                        operation,
                        config,
                        storage.last_fault,
                        recover_err,
                    );
                continue;
            };
            try model.snapshot(storage.dirty.items.len, false);
            writer.close() catch |err| return reportFailure(seed, operation, config, null, err);
            writer = try SimAppender.openOn(allocator, storage.file(), config.codec);
            reader.close();
            reader = try SimReader.openOn(allocator, storage.file());
            model.reader_counts = model.history.items[model.current_generation].counts;
            stats.checkpoint_reopens += 1;
        } else if (selector < refresh_limit) {
            const changed = reader.refresh() catch |err|
                return reportFailure(seed, operation, config, null, err);
            if (changed) model.reader_counts = model.history.items[model.current_generation].counts;
        } else if (selector < range_limit) {
            const series_index: usize = @intCast(workload_rng.below(model.count));
            verifyRange(
                &reader,
                &model,
                series_index,
                config.max_range_width,
                &workload_rng,
            ) catch |err|
                return reportFailure(seed, operation, config, storage.last_fault, err);
        } else {
            const series_index: usize = @intCast(workload_rng.below(model.count));
            const batch_size: usize = @intCast(
                1 + workload_rng.below(config.max_batch_size),
            );
            var timestamps: [16]i64 = undefined;
            var values: [16]f64 = undefined;
            var temporary_last = if (model.series[series_index].points.items.len == 0)
                @as(i64, 0)
            else
                model.series[series_index].points.items[
                    model.series[series_index].points.items.len - 1
                ].timestamp;
            for (0..batch_size) |i| {
                const gap: i64 = switch (config.timestamp_pattern) {
                    .dense => 1,
                    .sparse => @intCast(100 + workload_rng.below(10_000)),
                    .irregular => @intCast(1 + workload_rng.below(1_000_000)),
                };
                temporary_last += gap;
                timestamps[i] = temporary_last;
                values[i] = nextValue(
                    config.value_pattern,
                    model.series[series_index].points.items.len + i,
                    &workload_rng,
                );
            }
            storage.last_fault = null;
            writer.appendBatch(
                model.series[series_index].name,
                timestamps[0..batch_size],
                values[0..batch_size],
            ) catch |err| {
                if (storage.last_fault == null)
                    return reportFailure(seed, operation, config, null, err);
                recover(
                    &writer,
                    &reader,
                    &storage,
                    &model,
                    config.codec,
                    storage.last_fault == .power_loss,
                ) catch |recover_err|
                    return reportFailure(
                        seed,
                        operation,
                        config,
                        storage.last_fault,
                        recover_err,
                    );
                continue;
            };
            for (timestamps[0..batch_size], values[0..batch_size]) |timestamp, value|
                try model.series[series_index].points.append(allocator, .{
                    .timestamp = timestamp,
                    .value = value,
                });
        }
    }

    storage.faults_enabled = false;
    writer.abort();
    reader.close();
    if (output_path) |path| {
        const output = try std.fs.cwd().createFile(path, .{});
        defer output.close();
        try output.writeAll(storage.dirty.items);
    }
    if (!quiet) printSeedResult(seed, config, stats);
    return stats;
}

fn recover(
    writer: *SimAppender,
    reader: *SimReader,
    storage: *MemoryStorage,
    model: *Model,
    codec: chronotail.Codec,
    power_loss: bool,
) !void {
    writer.abort();
    reader.close();
    try storage.crash(power_loss);
    var generation = if (power_loss) model.durable_generation else model.current_generation;
    while (generation > 0 and
        model.history.items[generation].end_size > storage.dirty.items.len)
        generation -= 1;
    model.restore(generation);
    writer.* = try SimAppender.openOn(model.allocator, storage.file(), codec);
    reader.* = try SimReader.openOn(model.allocator, storage.file());
    model.reader_counts = model.history.items[generation].counts;
}

fn verifyRange(
    reader: *SimReader,
    model: *const Model,
    series_index: usize,
    max_width: usize,
    rng: *Rng,
) !void {
    const available = model.reader_counts[series_index];
    if (available == 0) return;
    const width = @min(available, 1 + rng.below(@min(available, max_width)));
    const begin: usize = @intCast(rng.below(available - width + 1));
    const expected = model.series[series_index].points.items[begin .. begin + width];
    var timestamps: [128]i64 = undefined;
    var values: [128]f64 = undefined;
    const found = try reader.rangeInto(
        model.series[series_index].name,
        expected[0].timestamp,
        expected[expected.len - 1].timestamp,
        timestamps[0..width],
        values[0..width],
    );
    if (found != width) return error.RangeCountMismatch;
    for (expected, 0..) |point, i| {
        const value_bits: u64 = @bitCast(values[i]);
        const expected_value_bits: u64 = @bitCast(point.value);
        if (timestamps[i] != point.timestamp or value_bits != expected_value_bits)
            return error.RangeValueMismatch;
        if (i > 0 and timestamps[i] <= timestamps[i - 1]) return error.TimestampInvariant;
    }
}

fn reportFailure(
    seed: u64,
    operation: u64,
    config: SimConfig,
    fault: ?Fault,
    err: anyerror,
) anyerror {
    std.debug.print(
        "FAILED\nseed: {d}\noperation: {d}\nconfig: {any}\nfault: {any}\nerror: {s}\n",
        .{ seed, operation, config, fault, @errorName(err) },
    );
    return error.InvariantFailure;
}

fn hashStat(stats: *Stats, value: u64) void {
    stats.digest ^= value;
    stats.digest *%= 1099511628211;
}

fn printSeedResult(seed: u64, config: SimConfig, stats: Stats) void {
    std.debug.print(
        "seed {d} passed: operations={d} config={any} stats={any}\n",
        .{ seed, stats.operations, config, stats },
    );
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var seed: u64 = 1;
    var seed_count: u64 = 1;
    var operations: ?u64 = null;
    var explicit_seed = false;
    var output_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            i += 1;
            seed = try std.fmt.parseInt(u64, args[i], 10);
            explicit_seed = true;
        } else if (std.mem.eql(u8, args[i], "--seeds") and i + 1 < args.len) {
            i += 1;
            seed_count = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--operations") and i + 1 < args.len) {
            i += 1;
            operations = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else return error.InvalidArguments;
    }

    if (output_path != null and seed_count != 1) return error.OutputRequiresSingleSeed;
    var timer = try std.time.Timer.start();
    var total = Stats{};
    for (0..seed_count) |index| {
        const current_seed = if (explicit_seed) seed + index else index + 1;
        const result = try runSeed(
            allocator,
            current_seed,
            operations,
            seed_count > 1,
            output_path,
        );
        total.add(result);
    }
    const elapsed = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
    std.debug.print(
        "PASSED\nseeds passed: {d}\noperations executed: {d}\n" ++
            "simulated crashes: {d}\nshort writes: {d}\nfailed writes: {d}\n" ++
            "truncations: {d}\ncorruptions: {d}\ncheckpoint/reopen cycles: {d}\n" ++
            "invariant failures: {d}\ntotal runtime: {d:.3}s\n",
        .{
            seed_count,
            total.operations,
            total.crashes,
            total.short_writes,
            total.failed_writes,
            total.truncations,
            total.corruptions,
            total.checkpoint_reopens,
            total.invariant_failures,
            elapsed,
        },
    );
}
