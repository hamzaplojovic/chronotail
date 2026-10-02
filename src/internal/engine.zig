const std = @import("std");
const checksum = @import("checksum.zig");
const format = @import("format.zig");
const index = @import("index.zig");
const manifest = @import("manifest.zig");
const page = @import("page.zig");

pub const file_header = format.file_header;
pub const block_size = format.page_size;
pub const block_header_size = format.page_header_size;
pub const record_size: usize = 16;
pub const records_per_block = page.records_max;
pub const compression_min_savings_percent: usize = 5;

pub const Codec = enum(u8) { raw = 0, compressed = 1 };

pub const Durability = enum(u8) {
    memory = 0,
    disk = 1,
};

pub const QueryProfile = struct {
    block_lookup_ns: u64 = 0,
    file_read_ns: u64 = 0,
    checksum_ns: u64 = 0,
    record_decode_ns: u64 = 0,
};

pub const SeriesHandle = struct { index: u32, generation: u64 };
pub const Point = page.Point;

pub const LookupMode = enum { exact, predecessor, successor, nearest };
const LookupDirection = enum { predecessor, successor };

pub const ChartBucketBounds = struct { start: i64, end: i64 };

pub const ChartRoles = packed struct {
    first: bool = false,
    minimum: bool = false,
    maximum: bool = false,
    last: bool = false,
};

pub const ChartBreaks = packed struct {
    query_start: bool = false,
    empty_bucket: bool = false,
    excluded_interval: bool = false,
    time_gap: bool = false,
    nan: bool = false,
};

pub const ChartSample = struct {
    point: Point,
    roles: ChartRoles,
    break_before: ChartBreaks,
};

pub const ChartBucket = struct {
    stored_count: u64 = 0,
    numeric_count: u64 = 0,
    sample_count: u8 = 0,
    samples: [4]ChartSample = undefined,
    has_nan: bool = false,
    has_internal_time_gap: bool = false,
};

pub const ChartProgress = struct {
    required_buckets: usize,
    written_buckets: usize,
    complete: bool,
};

fn chartIsNan(value: f64) bool {
    const bits: u64 = @bitCast(value);
    return bits & 0x7ff0000000000000 == 0x7ff0000000000000 and
        bits & 0x000fffffffffffff != 0;
}

const ChartCandidate = struct {
    point: Point,
    nan_prefix: u64,
    gap_prefix: u64,
};

// Private source-test accounting: records, not scalar decoder instructions.
// Page validation and selection are distinct passes; no timing/public API.
const ChartWork = struct {
    index_visits: u64 = 0,
    page_loads: u64 = 0,
    authenticated_bytes: u64 = 0,
    validation_records: u64 = 0,
    selection_records: u64 = 0,
    emitted_points: u64 = 0,
};

const ChartReduction = struct {
    bounds: []const ChartBucketBounds,
    output: []ChartBucket,
    max_gap: ?u64,
    bucket_index: usize = 0,
    bucket: ChartBucket = .{},
    // Role order is first/minimum/maximum/last, not chronological order.
    candidates: [4]?ChartCandidate = .{ null, null, null, null },
    observed_timestamp: ?i64 = null,
    nan_prefix: u64 = 0,
    gap_prefix: u64 = 0,
    emitted: ?ChartCandidate = null,
    pending_empty: bool = false,
    pending_excluded: bool = false,

    fn advanceBefore(self: *ChartReduction, timestamp: i64) !void {
        while (self.bucket_index < self.bounds.len and
            self.bounds[self.bucket_index].end < timestamp) try self.finishBucket();
    }

    fn observe(self: *ChartReduction, point: Point) !void {
        const is_nan = chartIsNan(point.value);
        if (is_nan) {
            self.nan_prefix = std.math.add(u64, self.nan_prefix, 1) catch return error.DatabaseTooLarge;
            self.bucket.has_nan = true;
        }
        if (self.observed_timestamp) |previous| {
            if (self.max_gap) |limit| if (timestampDistance(point.timestamp, previous) > limit) {
                self.gap_prefix = std.math.add(u64, self.gap_prefix, 1) catch return error.DatabaseTooLarge;
                // A cross-bucket original pair is a connection event only.
                if (self.bucket.stored_count != 0) self.bucket.has_internal_time_gap = true;
            };
        }
        self.observed_timestamp = point.timestamp;
        const candidate = ChartCandidate{
            .point = point,
            .nan_prefix = self.nan_prefix,
            .gap_prefix = self.gap_prefix,
        };
        self.bucket.stored_count = std.math.add(u64, self.bucket.stored_count, 1) catch return error.DatabaseTooLarge;
        if (self.candidates[0] == null) self.candidates[0] = candidate;
        self.candidates[3] = candidate;
        if (!is_nan) {
            self.bucket.numeric_count = std.math.add(u64, self.bucket.numeric_count, 1) catch return error.DatabaseTooLarge;
            // Strict updates preserve earliest numeric ties, including zero bits.
            if (self.candidates[1] == null or point.value < self.candidates[1].?.point.value)
                self.candidates[1] = candidate;
            if (self.candidates[2] == null or point.value > self.candidates[2].?.point.value)
                self.candidates[2] = candidate;
        }
    }

    fn finishBucket(self: *ChartReduction) !void {
        var ordered: [4]struct { candidate: ChartCandidate, roles: ChartRoles } = undefined;
        var count: usize = 0;
        for (self.candidates, 0..) |maybe_candidate, role| {
            const candidate = maybe_candidate orelse continue;
            var position: usize = 0;
            while (position < count and ordered[position].candidate.point.timestamp < candidate.point.timestamp)
                position += 1;
            if (position == count or ordered[position].candidate.point.timestamp != candidate.point.timestamp) {
                var move = count;
                while (move > position) : (move -= 1) ordered[move] = ordered[move - 1];
                ordered[position] = .{ .candidate = candidate, .roles = .{} };
                count += 1;
            }
            switch (role) {
                0 => ordered[position].roles.first = true,
                1 => ordered[position].roles.minimum = true,
                2 => ordered[position].roles.maximum = true,
                3 => ordered[position].roles.last = true,
                else => unreachable,
            }
        }
        for (ordered[0..count], 0..) |selected, sample_index| {
            const candidate = selected.candidate;
            const breaks: ChartBreaks = if (self.emitted) |previous| .{
                .empty_bucket = self.pending_empty,
                .excluded_interval = self.pending_excluded,
                .time_gap = candidate.gap_prefix > previous.gap_prefix,
                .nan = chartIsNan(previous.point.value) or candidate.nan_prefix > previous.nan_prefix,
            } else .{
                .query_start = true,
                .nan = chartIsNan(candidate.point.value),
            };
            self.bucket.samples[sample_index] = .{
                .point = candidate.point,
                .roles = selected.roles,
                .break_before = breaks,
            };
            self.emitted = candidate;
            self.pending_empty = false;
            self.pending_excluded = false;
        }
        self.bucket.sample_count = @intCast(count);
        self.output[self.bucket_index] = self.bucket;
        if (count == 0) self.pending_empty = true;
        const previous_end = self.bounds[self.bucket_index].end;
        self.bucket_index += 1;
        if (self.bucket_index < self.bounds.len and
            @as(i128, self.bounds[self.bucket_index].start) != @as(i128, previous_end) + 1)
        {
            self.pending_excluded = true;
            self.observed_timestamp = null;
        }
        self.bucket = .{};
        self.candidates = .{ null, null, null, null };
    }
};

// One live pair of byte cursors, shared by mapped/generic and unaligned tests.
fn chartSelectPage(
    view: page.View,
    reduction: *ChartReduction,
    comptime measured: bool,
    work: if (measured) *ChartWork else void,
) !void {
    // Start at zero: no hidden restart-prefix decodes. Page geometry bounds
    // outside-coverage decoding; omitted values never enter event state.
    var timestamps = view.timestampCursor(0);
    var values = view.valueCursor(0);
    var point_index: u32 = 0;
    while (point_index < view.statistics.count) : (point_index += 1) {
        const point = Point{ .timestamp = timestamps.next(), .value = values.next() };
        if (measured) work.selection_records += 1;
        try reduction.advanceBefore(point.timestamp);
        if (reduction.bucket_index == reduction.bounds.len) break;
        if (point.timestamp >= reduction.bounds[reduction.bucket_index].start) try reduction.observe(point);
    }
}

fn timestampDistance(a: i64, b: i64) u64 {
    const difference = @as(i128, a) - @as(i128, b);
    return @intCast(if (difference < 0) -difference else difference);
}

// Both decoded nodes and mapped views have authenticated, ordered summaries.
fn lookupEntryAt(node: anytype, entry_index: usize) index.Entry {
    if (comptime @TypeOf(node.*) == index.Node) {
        return node.entries[entry_index];
    } else {
        return node.entryAt(entry_index);
    }
}

fn lookupEntryIndex(node: anytype, timestamp: i64, direction: LookupDirection) ?usize {
    var selected: usize = node.lowerBound(timestamp);
    switch (direction) {
        .successor => if (selected == node.count) return null,
        .predecessor => {
            if (selected == node.count) return selected - 1;
            if (lookupEntryAt(node, selected).summary.timestamp_min > timestamp) {
                if (selected == 0) return null;
                selected -= 1;
            }
        },
    }
    return selected;
}

fn lookupPagePoint(view: page.View, timestamp: i64, direction: LookupDirection) ?Point {
    var selected = view.lowerBound(timestamp);
    switch (direction) {
        .successor => if (selected == view.statistics.count) return null,
        .predecessor => {
            if (selected == view.statistics.count) {
                selected -= 1;
            } else if (view.timestampAt(selected) > timestamp) {
                if (selected == 0) return null;
                selected -= 1;
            }
        },
    }
    return .{ .timestamp = view.timestampAt(selected), .value = view.valueAt(selected) };
}

pub const BorrowedRawPage = struct {
    timestamps: []const i64,
    values: []const f64,
    timestamp_min: i64,
    timestamp_max: i64,
};

pub const Aggregate = struct {
    count: u64 = 0,
    minimum: f64 = std.math.nan(f64),
    maximum: f64 = std.math.nan(f64),
    sum: f64 = 0,
    first: f64 = std.math.nan(f64),
    last: f64 = std.math.nan(f64),
};

const SeriesDirectory = std.StringHashMapUnmanaged(u32);
const page_write_batch_max = 4;

const LoadedSnapshot = struct {
    root: format.Root,
    root_identity: checksum.Identity,
    catalog: manifest.Manifest,

    fn deinit(self: *LoadedSnapshot, allocator: std.mem.Allocator) void {
        self.catalog.deinit(allocator);
    }
};

const RootCandidate = struct {
    root: format.Root,
    identity: checksum.Identity,
};

fn validateControl(file: anytype, physical_size: u64) ![format.control_size]u8 {
    if (physical_size < format.file_header.len) return error.InvalidDatabase;
    if (physical_size < format.control_size) {
        var found: [format.file_header.len]u8 = undefined;
        if (try file.preadAll(&found, 0) != found.len) return error.InvalidDatabase;
        if (std.mem.eql(u8, &found, "CTDB\x06")) return error.FormatV6RequiresMigration;
        return error.InvalidDatabase;
    }
    var control: [format.control_size]u8 = undefined;
    if (try file.preadAll(&control, 0) != control.len) return error.InvalidDatabase;
    if (std.mem.eql(u8, control[0..format.file_header.len], "CTDB\x06"))
        return error.FormatV6RequiresMigration;
    format.validateFileHeader(&control) catch return error.InvalidDatabase;
    return control;
}

fn collectRoots(
    control: *const [format.control_size]u8,
    physical_size: u64,
) [format.root_slot_count]?RootCandidate {
    var candidates = [_]?RootCandidate{null} ** format.root_slot_count;
    for (0..format.root_slot_count) |slot| {
        const offset: usize = @intCast(format.rootSlotOffset(slot) catch unreachable);
        const encoded: *const [format.root_slot_size]u8 =
            @ptrCast(control[offset..][0..format.root_slot_size].ptr);
        const root = format.Root.decode(encoded) catch continue;
        if (root.committed_size < format.control_size or root.committed_size > physical_size)
            continue;
        const manifest_end = std.math.add(
            u64,
            root.manifest.offset,
            root.manifest.size,
        ) catch continue;
        if (manifest_end != root.committed_size) continue;
        candidates[slot] = .{
            .root = root,
            .identity = format.Root.identity(encoded),
        };
    }
    return candidates;
}

fn rootSlotsEmpty(control: *const [format.control_size]u8) bool {
    for (0..format.root_slot_count) |slot| {
        const offset: usize = @intCast(format.rootSlotOffset(slot) catch unreachable);
        for (control[offset..][0..format.root_slot_size]) |byte| {
            if (byte != 0) return false;
        }
    }
    return true;
}

fn newestRoot(candidates: *const [format.root_slot_count]?RootCandidate) ?RootCandidate {
    var best: ?RootCandidate = null;
    for (candidates) |candidate| if (candidate) |value| {
        if (best == null or value.root.generation > best.?.root.generation) best = value;
    };
    return best;
}

fn rootHasValidPredecessor(
    candidates: *const [format.root_slot_count]?RootCandidate,
    candidate: RootCandidate,
) bool {
    if (candidate.root.generation == 1)
        return checksum.equal(candidate.root.previous_identity, checksum.zero);

    var oldest_generation = candidate.root.generation;
    for (candidates) |other| if (other) |value| {
        oldest_generation = @min(oldest_generation, value.root.generation);
        if (value.root.generation == candidate.root.generation - 1) {
            return checksum.equal(candidate.root.previous_identity, value.identity);
        }
    };

    // The predecessor of the oldest retained slot has normally been rotated out.
    return candidate.root.generation == oldest_generation;
}

fn loadManifestForRoot(
    allocator: std.mem.Allocator,
    file: anytype,
    candidate: RootCandidate,
) !manifest.Manifest {
    const size = std.math.cast(usize, candidate.root.manifest.size) orelse
        return error.InvalidDatabase;
    if (size > manifest.size_max) return error.InvalidDatabase;
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    if (try file.preadAll(bytes, candidate.root.manifest.offset) != bytes.len)
        return error.InvalidDatabase;
    var catalog = manifest.decode(
        allocator,
        bytes,
        candidate.root.manifest,
        candidate.root.committed_size,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidDatabase,
    };
    errdefer catalog.deinit(allocator);
    if (catalog.generation != candidate.root.generation) return error.InvalidDatabase;
    return catalog;
}

fn loadSnapshot(
    allocator: std.mem.Allocator,
    file: anytype,
    physical_size: u64,
) !?LoadedSnapshot {
    const control = try validateControl(file, physical_size);
    var candidates = collectRoots(&control, physical_size);
    if (newestRoot(&candidates) == null and rootSlotsEmpty(&control)) return null;
    return @as(?LoadedSnapshot, try loadSnapshotFromCandidates(allocator, file, &candidates));
}

fn loadSnapshotFromCandidates(
    allocator: std.mem.Allocator,
    file: anytype,
    candidates: *[format.root_slot_count]?RootCandidate,
) !LoadedSnapshot {
    var attempts: usize = 0;
    while (attempts < format.root_slot_count) : (attempts += 1) {
        var best_slot: ?usize = null;
        for (candidates.*, 0..) |candidate, slot| if (candidate) |value| {
            if (best_slot == null or
                value.root.generation > candidates.*[best_slot.?].?.root.generation)
            {
                best_slot = slot;
            }
        };
        const slot = best_slot orelse return error.InvalidDatabase;
        const candidate = candidates.*[slot].?;
        if (!rootHasValidPredecessor(candidates, candidate)) {
            candidates.*[slot] = null;
            continue;
        }
        const catalog = loadManifestForRoot(allocator, file, candidate) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                candidates.*[slot] = null;
                continue;
            },
        };
        return .{
            .root = candidate.root,
            .root_identity = candidate.identity,
            .catalog = catalog,
        };
    }
    return error.InvalidDatabase;
}

fn buildSeriesDirectory(allocator: std.mem.Allocator, series: []const manifest.Series) !SeriesDirectory {
    if (series.len > std.math.maxInt(u32)) return error.InvalidDatabase;
    var directory: SeriesDirectory = .empty;
    errdefer directory.deinit(allocator);
    try directory.ensureUnusedCapacity(allocator, @intCast(series.len));
    for (series, 0..) |entry, series_index| {
        const slot = directory.getOrPutAssumeCapacity(entry.name);
        if (slot.found_existing) return error.InvalidDatabase;
        slot.value_ptr.* = @intCast(series_index);
    }
    return directory;
}

fn summaryEqual(a: index.Summary, b: index.Summary) bool {
    return a.timestamp_min == b.timestamp_min and
        a.timestamp_max == b.timestamp_max and
        a.point_count == b.point_count and
        @as(u64, @bitCast(a.value_min)) == @as(u64, @bitCast(b.value_min)) and
        @as(u64, @bitCast(a.value_max)) == @as(u64, @bitCast(b.value_max)) and
        @as(u64, @bitCast(a.value_sum)) == @as(u64, @bitCast(b.value_sum)) and
        @as(u64, @bitCast(a.value_first)) == @as(u64, @bitCast(b.value_first)) and
        @as(u64, @bitCast(a.value_last)) == @as(u64, @bitCast(b.value_last));
}

fn pointerEqual(a: format.Pointer, b: format.Pointer) bool {
    return a.offset == b.offset and a.size == b.size and a.kind == b.kind and
        std.mem.eql(u8, &a.identity, &b.identity);
}

fn minimum(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return b;
    if (std.math.isNan(b)) return a;
    return @min(a, b);
}

fn maximum(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return b;
    if (std.math.isNan(b)) return a;
    return @max(a, b);
}

const WriterSeries = struct {
    id: u32,
    name: []u8,
    root: ?format.Pointer = null,
    summary: ?index.Summary = null,
    candidate_root: ?format.Pointer = null,
    candidate_summary: ?index.Summary = null,
    timestamps: []i64,
    values: []f64,
    owned_buffer: []u64 = &.{},
    pending_count: usize = 0,
    pending_entries: std.ArrayList(index.Entry) = .empty,
    right_spine: std.ArrayList(index.Node) = .empty,
    last_timestamp: ?i64 = null,
    dirty: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        root: ?format.Pointer,
        summary: ?index.Summary,
    ) !WriterSeries {
        const name_words = std.math.divCeil(usize, name.len, @sizeOf(u64)) catch unreachable;
        const buffer = try allocator.alloc(u64, name_words + page.records_max * 2);
        const owned_name = std.mem.sliceAsBytes(buffer)[0..name.len];
        @memcpy(owned_name, name);
        const timestamps = @as([*]i64, @ptrCast(buffer.ptr + name_words))[0..page.records_max];
        const values = @as([*]f64, @ptrCast(buffer.ptr + name_words + page.records_max))[0..page.records_max];
        return .{
            .id = id,
            .name = owned_name,
            .root = root,
            .summary = summary,
            .timestamps = timestamps,
            .values = values,
            .owned_buffer = buffer,
            .last_timestamp = if (summary) |value| value.timestamp_max else null,
        };
    }

    fn initBorrowed(
        id: u32,
        name: []u8,
        root: format.Pointer,
        summary: index.Summary,
        timestamps: []i64,
        values: []f64,
    ) WriterSeries {
        return .{
            .id = id,
            .name = name,
            .root = root,
            .summary = summary,
            .timestamps = timestamps,
            .values = values,
            .last_timestamp = summary.timestamp_max,
        };
    }

    fn deinit(self: *WriterSeries, allocator: std.mem.Allocator) void {
        if (self.owned_buffer.len > 0) allocator.free(self.owned_buffer);
        self.pending_entries.deinit(allocator);
        self.right_spine.deinit(allocator);
    }
};

const WriterManifestIterator = struct {
    series: []WriterSeries,
    index: usize = 0,

    pub fn next(self: *WriterManifestIterator) ?manifest.Series {
        while (self.index < self.series.len) {
            const entry = &self.series[self.index];
            self.index += 1;
            const root = entry.candidate_root orelse entry.root orelse continue;
            const summary = entry.candidate_summary orelse entry.summary orelse continue;
            return .{
                .id = entry.id,
                .name = entry.name,
                .root = root,
                .summary = summary,
            };
        }
        return null;
    }
};

pub fn AppenderFor(comptime File: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        file: File,
        series: std.ArrayList(WriterSeries) = .empty,
        series_directory: SeriesDirectory = .empty,
        dirty_series: std.ArrayList(u32) = .empty,
        manifest_scratch: std.ArrayList(u8) = .empty,
        page_write_scratch: std.ArrayList(u8) = .empty,
        loaded_names: []u8 = &.{},
        loaded_timestamps: []i64 = &.{},
        loaded_values: []f64 = &.{},
        last_series_index: ?u32 = null,
        write_offset: u64,
        committed_size: u64 = format.control_size,
        generation: u64 = 0,
        previous_root_identity: checksum.Identity = checksum.zero,
        manifest_size: usize = manifest.header_size,
        catalog_manifest_size: usize = manifest.header_size,
        manifest_series_count: usize = 0,
        codec: Codec,
        dirty: bool = false,
        poisoned: bool = false,

        pub fn create(allocator: std.mem.Allocator, path: []const u8, codec: Codec) !Self {
            const file = try std.fs.cwd().createFile(path, .{
                .read = true,
                .exclusive = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            });
            return createOn(allocator, file, codec);
        }

        pub fn open(allocator: std.mem.Allocator, path: []const u8, codec: Codec) !Self {
            const file = std.fs.cwd().openFile(path, .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |err| switch (err) {
                error.FileNotFound => return create(allocator, path, codec),
                else => return err,
            };
            return openOn(allocator, file, codec);
        }

        pub fn createOn(allocator: std.mem.Allocator, file: File, codec: Codec) !Self {
            errdefer file.close();
            if (try file.getEndPos() != 0) return error.InvalidDatabase;
            var control: [format.control_size]u8 = undefined;
            format.encodeFileHeader(&control);
            try file.pwriteAll(&control, 0);
            var self = Self{
                .allocator = allocator,
                .file = file,
                .write_offset = format.control_size,
                .codec = codec,
            };
            errdefer self.deinitMemory();

            var manifest_pointer = try manifest.encode(
                &self.manifest_scratch,
                allocator,
                1,
                &.{},
            );
            manifest_pointer.offset = self.write_offset;
            try self.file.pwriteAll(self.manifest_scratch.items, self.write_offset);
            self.write_offset = std.math.add(
                u64,
                self.write_offset,
                self.manifest_scratch.items.len,
            ) catch return error.DatabaseTooLarge;
            const root = format.Root{
                .generation = 1,
                .committed_size = self.write_offset,
                .manifest = manifest_pointer,
                .previous_identity = checksum.zero,
            };
            var encoded_root: [format.root_slot_size]u8 = undefined;
            root.encode(&encoded_root);
            try self.file.pwriteAll(&encoded_root, try format.rootSlotOffset(0));
            self.generation = root.generation;
            self.committed_size = root.committed_size;
            self.previous_root_identity = format.Root.identity(&encoded_root);
            return self;
        }

        pub fn openOn(allocator: std.mem.Allocator, file: File, codec: Codec) !Self {
            errdefer file.close();
            const physical_size = try file.getEndPos();
            if (physical_size == 0) return createOn(allocator, file, codec);
            var loaded = try loadSnapshot(allocator, file, physical_size);
            var self = Self{
                .allocator = allocator,
                .file = file,
                .write_offset = physical_size,
                .codec = codec,
            };
            errdefer self.deinitMemory();
            if (loaded) |*snapshot| {
                defer snapshot.deinit(allocator);
                const series_count = snapshot.catalog.series.items.len;
                try self.series.ensureTotalCapacity(allocator, series_count);
                try self.series_directory.ensureUnusedCapacity(
                    allocator,
                    @intCast(series_count),
                );
                try self.dirty_series.ensureTotalCapacity(allocator, series_count);
                const buffered_points = std.math.mul(
                    usize,
                    series_count,
                    page.records_max,
                ) catch return error.DatabaseTooLarge;
                if (buffered_points > 0) {
                    self.loaded_timestamps = try allocator.alloc(i64, buffered_points);
                    self.loaded_values = try allocator.alloc(f64, buffered_points);
                }
                self.loaded_names = snapshot.catalog.names;
                snapshot.catalog.names = &.{};
                for (snapshot.catalog.series.items, 0..) |entry, loaded_index| {
                    const buffer_start = loaded_index * page.records_max;
                    const writer_series = WriterSeries.initBorrowed(
                        entry.id,
                        entry.name,
                        entry.root,
                        entry.summary,
                        self.loaded_timestamps[buffer_start..][0..page.records_max],
                        self.loaded_values[buffer_start..][0..page.records_max],
                    );
                    self.series.appendAssumeCapacity(writer_series);
                    const series_index = self.series.items.len - 1;
                    const slot = self.series_directory.getOrPutAssumeCapacity(
                        self.series.items[series_index].name,
                    );
                    if (slot.found_existing) return error.InvalidDatabase;
                    slot.value_ptr.* = @intCast(series_index);
                }
                self.generation = snapshot.root.generation;
                self.committed_size = snapshot.root.committed_size;
                self.previous_root_identity = snapshot.root_identity;
                self.manifest_size = std.math.cast(
                    usize,
                    snapshot.root.manifest.size,
                ) orelse return error.DatabaseTooLarge;
                self.catalog_manifest_size = self.manifest_size;
                self.manifest_series_count = series_count;
            }
            return self;
        }

        pub fn append(self: *Self, name: []const u8, timestamp: i64, value: f64) !void {
            const timestamps = [_]i64{timestamp};
            const values = [_]f64{value};
            try self.appendBatch(name, &timestamps, &values);
        }

        pub fn prepareSeries(
            self: *Self,
            name: []const u8,
            maximum_points_before_checkpoint: usize,
        ) !void {
            if (self.poisoned) return error.WriterPoisoned;
            if (maximum_points_before_checkpoint == 0) return error.InvalidArguments;
            if (name.len == 0 or name.len > std.math.maxInt(u16))
                return error.InvalidSeriesName;
            const entry = try self.getOrCreateSeries(name);
            const total = std.math.add(
                usize,
                entry.pending_count,
                maximum_points_before_checkpoint,
            ) catch return error.DatabaseTooLarge;
            const pages = std.math.divCeil(usize, total, page.records_max) catch
                return error.DatabaseTooLarge;
            try entry.pending_entries.ensureUnusedCapacity(self.allocator, pages);
            if (comptime File == std.fs.File) if (pages > 1)
                try self.ensurePageWriteScratch(@min(pages, page_write_batch_max));
        }

        pub fn appendBatch(
            self: *Self,
            name: []const u8,
            timestamps: []const i64,
            values: []const f64,
        ) !void {
            if (self.poisoned) return error.WriterPoisoned;
            if (timestamps.len != values.len) return error.InvalidBatch;
            if (timestamps.len == 0) return;
            if (name.len == 0 or name.len > std.math.maxInt(u16))
                return error.InvalidSeriesName;
            if (!timestampsStrictlyIncreasing(timestamps))
                return error.TimestampNotIncreasing;
            const existing = self.findSeries(name);
            if (existing) |series| if (series.last_timestamp) |last| {
                if (timestamps[0] <= last) return error.TimestampNotIncreasing;
            };

            const target = existing orelse try self.createSeries(name);
            self.markDirty(target);
            errdefer self.poisoned = true;
            var consumed: usize = 0;
            while (consumed < timestamps.len) {
                if (target.pending_count == page.records_max) try self.flushSeries(target);
                const remaining = timestamps.len - consumed;
                if (comptime File == std.fs.File) {
                    const full_pages = @min(
                        remaining / page.records_max,
                        page_write_batch_max,
                    );
                    if (target.pending_count == 0 and full_pages > 1) {
                        const point_count = full_pages * page.records_max;
                        try self.writeFullPages(
                            target,
                            timestamps[consumed..][0..point_count],
                            values[consumed..][0..point_count],
                        );
                        consumed += point_count;
                        continue;
                    }
                }
                if (target.pending_count == 0 and remaining >= page.records_max) {
                    try self.writePage(
                        target,
                        timestamps[consumed..][0..page.records_max],
                        values[consumed..][0..page.records_max],
                    );
                    consumed += page.records_max;
                    continue;
                }
                const amount = @min(
                    page.records_max - target.pending_count,
                    remaining,
                );
                @memcpy(
                    target.timestamps[target.pending_count..][0..amount],
                    timestamps[consumed..][0..amount],
                );
                @memcpy(
                    target.values[target.pending_count..][0..amount],
                    values[consumed..][0..amount],
                );
                target.pending_count += amount;
                consumed += amount;
            }
            target.last_timestamp = timestamps[timestamps.len - 1];
            self.dirty = true;
        }

        pub fn checkpoint(self: *Self, sync: bool) !void {
            return self.checkpointWithDurability(if (sync) .disk else .memory);
        }

        pub fn checkpointWithDurability(self: *Self, durability: Durability) !void {
            if (self.poisoned) return error.WriterPoisoned;
            if (!self.dirty) {
                if (durability == .disk) try self.file.sync();
                return;
            }
            errdefer self.poisoned = true;
            for (self.dirty_series.items) |series_index|
                try self.flushSeries(&self.series.items[series_index]);

            var written_spine: [index.height_max]index.Node = undefined;
            for (self.dirty_series.items) |series_index| {
                const entry = &self.series.items[series_index];
                var cached_spine: ?[]const index.Node = null;
                var output_spine: []index.Node = &written_spine;
                var output_in_place = false;
                var expected_spine_depth: ?usize = null;
                if (comptime File == std.fs.File) if (entry.right_spine.items.len > 0) {
                    const required_depth = try index.appendedSpineDepth(
                        entry.right_spine.items,
                        entry.pending_entries.items.len,
                    );
                    try entry.right_spine.ensureTotalCapacity(self.allocator, required_depth);
                    cached_spine = entry.right_spine.items;
                    output_spine = entry.right_spine.items.ptr[0..entry.right_spine.capacity];
                    output_in_place = true;
                    expected_spine_depth = required_depth;
                };
                const appended = try index.appendWithSpine(
                    self.file,
                    self.allocator,
                    &self.write_offset,
                    self.committed_size,
                    entry.id,
                    if (entry.root) |pointer| .{
                        .pointer = pointer,
                        .summary = entry.summary orelse return error.InvalidDatabase,
                    } else null,
                    cached_spine,
                    entry.pending_entries.items,
                    output_spine,
                );
                if (expected_spine_depth) |expected|
                    std.debug.assert(appended.spine_depth == expected);
                if (comptime File == std.fs.File) {
                    if (output_in_place) {
                        entry.right_spine.items.len = appended.spine_depth;
                    } else {
                        entry.right_spine.clearRetainingCapacity();
                        try entry.right_spine.appendSlice(
                            self.allocator,
                            written_spine[0..appended.spine_depth],
                        );
                    }
                }
                entry.candidate_root = appended.root.pointer;
                entry.candidate_summary = appended.root.summary;
                if (entry.root == null) {
                    const published_series_size = std.math.add(
                        usize,
                        manifest.series_fixed_size,
                        entry.name.len,
                    ) catch return error.ManifestTooLarge;
                    self.manifest_size = std.math.add(
                        usize,
                        self.manifest_size,
                        published_series_size,
                    ) catch return error.ManifestTooLarge;
                    self.manifest_series_count = std.math.add(
                        usize,
                        self.manifest_series_count,
                        1,
                    ) catch return error.ManifestTooLarge;
                }
            }

            const next_generation = std.math.add(u64, self.generation, 1) catch
                return error.DatabaseTooLarge;
            var manifest_iterator = WriterManifestIterator{ .series = self.series.items };
            var manifest_pointer = try manifest.encodeKnownIterator(
                &self.manifest_scratch,
                self.allocator,
                next_generation,
                self.manifest_series_count,
                self.manifest_size,
                &manifest_iterator,
            );
            self.write_offset = std.mem.alignForward(u64, self.write_offset, 8);
            manifest_pointer.offset = self.write_offset;
            try self.file.pwriteAll(self.manifest_scratch.items, self.write_offset);
            self.write_offset = std.math.add(
                u64,
                self.write_offset,
                self.manifest_scratch.items.len,
            ) catch return error.DatabaseTooLarge;

            if (durability == .disk) try self.file.sync();
            const root = format.Root{
                .generation = next_generation,
                .committed_size = self.write_offset,
                .manifest = manifest_pointer,
                .previous_identity = self.previous_root_identity,
            };
            var encoded_root: [format.root_slot_size]u8 = undefined;
            root.encode(&encoded_root);
            const slot: usize = @intCast((next_generation - 1) % format.root_slot_count);
            try self.file.pwriteAll(&encoded_root, try format.rootSlotOffset(slot));
            if (durability == .disk) try self.file.sync();

            self.generation = next_generation;
            self.committed_size = self.write_offset;
            self.previous_root_identity = format.Root.identity(&encoded_root);
            for (self.dirty_series.items) |series_index| {
                const entry = &self.series.items[series_index];
                entry.root = entry.candidate_root;
                entry.summary = entry.candidate_summary;
                entry.candidate_root = null;
                entry.candidate_summary = null;
                entry.pending_entries.clearRetainingCapacity();
                entry.dirty = false;
            }
            self.dirty_series.clearRetainingCapacity();
            self.dirty = false;
        }

        pub fn close(self: *Self) !void {
            defer self.file.close();
            defer self.deinitMemory();
            if (self.dirty and !self.poisoned) try self.checkpoint(false);
            if (self.poisoned) return error.WriterPoisoned;
        }

        pub fn abort(self: *Self) void {
            self.file.close();
            self.deinitMemory();
        }

        fn flushSeries(self: *Self, entry: *WriterSeries) !void {
            if (entry.pending_count == 0) return;
            try self.writePage(
                entry,
                entry.timestamps[0..entry.pending_count],
                entry.values[0..entry.pending_count],
            );
            entry.pending_count = 0;
        }

        fn writePage(
            self: *Self,
            entry: *WriterSeries,
            timestamps: []const i64,
            values: []const f64,
        ) !void {
            var encoded_bytes: [format.page_size]u8 = undefined;
            const encoded = try page.encodeWithOptions(
                &encoded_bytes,
                entry.id,
                timestamps,
                values,
                self.codec == .compressed,
            );
            try entry.pending_entries.ensureUnusedCapacity(self.allocator, 1);
            self.write_offset = std.mem.alignForward(u64, self.write_offset, 8);
            try self.file.pwriteAll(encoded.bytes, self.write_offset);
            const pointer = format.Pointer{
                .offset = self.write_offset,
                .size = @intCast(encoded.bytes.len),
                .kind = .data,
                .identity = encoded.identity,
            };
            entry.pending_entries.appendAssumeCapacity(try index.dataEntry(
                pointer,
                encoded.statistics,
            ));
            self.write_offset = std.math.add(u64, self.write_offset, encoded.bytes.len) catch
                return error.DatabaseTooLarge;
        }

        fn writeFullPages(
            self: *Self,
            entry: *WriterSeries,
            timestamps: []const i64,
            values: []const f64,
        ) !void {
            std.debug.assert(comptime File == std.fs.File);
            std.debug.assert(timestamps.len == values.len);
            std.debug.assert(timestamps.len % page.records_max == 0);
            const page_count = timestamps.len / page.records_max;
            std.debug.assert(page_count > 1 and page_count <= page_write_batch_max);
            try entry.pending_entries.ensureUnusedCapacity(self.allocator, page_count);

            try self.ensurePageWriteScratch(page_count);
            const staging = self.page_write_scratch.items;
            var entries: [page_write_batch_max]index.Entry = undefined;
            const base_offset = std.mem.alignForward(u64, self.write_offset, 8);
            var encoded_size: usize = 0;
            for (0..page_count) |page_index| {
                const aligned_size = std.mem.alignForward(usize, encoded_size, 8);
                @memset(staging[encoded_size..aligned_size], 0);
                encoded_size = aligned_size;
                const output: *[format.page_size]u8 =
                    @ptrCast(staging[encoded_size..][0..format.page_size].ptr);
                const point_offset = page_index * page.records_max;
                const encoded = try page.encodeWithOptions(
                    output,
                    entry.id,
                    timestamps[point_offset..][0..page.records_max],
                    values[point_offset..][0..page.records_max],
                    self.codec == .compressed,
                );
                const pointer_offset = std.math.add(u64, base_offset, encoded_size) catch
                    return error.DatabaseTooLarge;
                entries[page_index] = try index.dataEntry(.{
                    .offset = pointer_offset,
                    .size = @intCast(encoded.bytes.len),
                    .kind = .data,
                    .identity = encoded.identity,
                }, encoded.statistics);
                encoded_size += encoded.bytes.len;
            }
            try self.file.pwriteAll(staging[0..encoded_size], base_offset);
            entry.pending_entries.appendSliceAssumeCapacity(entries[0..page_count]);
            self.write_offset = std.math.add(u64, base_offset, encoded_size) catch
                return error.DatabaseTooLarge;
        }

        fn ensurePageWriteScratch(self: *Self, page_count: usize) !void {
            std.debug.assert(page_count > 1 and page_count <= page_write_batch_max);
            const required_size = page_count * format.page_size;
            if (self.page_write_scratch.items.len < required_size) {
                try self.page_write_scratch.resize(
                    self.allocator,
                    required_size,
                );
            }
        }

        fn getOrCreateSeries(self: *Self, name: []const u8) !*WriterSeries {
            if (self.findSeries(name)) |entry| return entry;
            return self.createSeries(name);
        }

        fn createSeries(self: *Self, name: []const u8) !*WriterSeries {
            if (self.series.items.len == std.math.maxInt(u32))
                return error.DatabaseTooLarge;
            try self.series.ensureUnusedCapacity(self.allocator, 1);
            try self.series_directory.ensureUnusedCapacity(self.allocator, 1);
            // Every prepared series may become dirty before the next checkpoint.
            // Reserve by catalog size, not by the current dirty-list length.
            try self.dirty_series.ensureTotalCapacity(
                self.allocator,
                self.series.items.len + 1,
            );
            const added_manifest_size = std.math.add(
                usize,
                manifest.series_fixed_size,
                name.len,
            ) catch return error.ManifestTooLarge;
            const next_manifest_size = std.math.add(
                usize,
                self.catalog_manifest_size,
                added_manifest_size,
            ) catch return error.ManifestTooLarge;
            if (next_manifest_size > manifest.size_max) return error.ManifestTooLarge;
            const id: u32 = if (self.series.items.len == 0)
                0
            else
                std.math.add(u32, self.series.items[self.series.items.len - 1].id, 1) catch
                    return error.DatabaseTooLarge;
            const created = try WriterSeries.init(self.allocator, id, name, null, null);
            self.series.appendAssumeCapacity(created);
            const series_index = self.series.items.len - 1;
            self.series_directory.putAssumeCapacityNoClobber(
                self.series.items[series_index].name,
                @intCast(series_index),
            );
            self.last_series_index = @intCast(series_index);
            self.catalog_manifest_size = next_manifest_size;
            return &self.series.items[series_index];
        }

        fn markDirty(self: *Self, entry: *WriterSeries) void {
            if (entry.dirty) return;
            const series_index = (@intFromPtr(entry) - @intFromPtr(self.series.items.ptr)) /
                @sizeOf(WriterSeries);
            std.debug.assert(series_index < self.series.items.len);
            self.dirty_series.appendAssumeCapacity(@intCast(series_index));
            entry.dirty = true;
        }

        fn findSeries(self: *Self, name: []const u8) ?*WriterSeries {
            if (self.last_series_index) |series_index| {
                const cached = &self.series.items[series_index];
                if (std.mem.eql(u8, cached.name, name)) return cached;
            }
            const series_index = self.series_directory.get(name) orelse return null;
            self.last_series_index = series_index;
            return &self.series.items[series_index];
        }

        fn deinitMemory(self: *Self) void {
            for (self.series.items) |*entry| entry.deinit(self.allocator);
            self.series.deinit(self.allocator);
            self.series_directory.deinit(self.allocator);
            self.dirty_series.deinit(self.allocator);
            self.manifest_scratch.deinit(self.allocator);
            self.page_write_scratch.deinit(self.allocator);
            if (self.loaded_names.len > 0) self.allocator.free(self.loaded_names);
            if (self.loaded_timestamps.len > 0) self.allocator.free(self.loaded_timestamps);
            if (self.loaded_values.len > 0) self.allocator.free(self.loaded_values);
        }
    };
}

pub const Appender = AppenderFor(std.fs.File);

const VerificationCacheEntry = struct {
    offset: u64 = 0,
    size: u32 = 0,
    kind: format.PointerKind = .data,
    identity: checksum.Identity = checksum.zero,
    valid: bool = false,
};

const verification_cache_size = 1024;
const verification_cache_ways = 8;
const TraversalFrame = struct { node: index.Node, next: u16 = 0 };
const MappedTraversalFrame = struct { view: index.View, next: u16 = 0 };
const RangeBuffers = struct { timestamps: []i64, values: []f64 };
const FileSink = struct {
    file: std.fs.File,
    bytes: [64 * 1024]u8 = undefined,
    used: usize = 0,

    fn writePoint(self: *FileSink, timestamp: i64, value: f64) !void {
        // Decimal formatting may spell subnormal f64 values with more than a
        // thousand fractional digits; 2 KiB bounds every finite value plus
        // the timestamp, separator, sign, and newline.
        var line: [2 * 1024]u8 = undefined;
        const encoded = try std.fmt.bufPrint(&line, "{d} {d}\n", .{ timestamp, value });
        if (encoded.len > self.bytes.len - self.used) try self.flush();
        @memcpy(self.bytes[self.used..][0..encoded.len], encoded);
        self.used += encoded.len;
    }

    fn flush(self: *FileSink) !void {
        if (self.used == 0) return;
        try self.file.writeAll(self.bytes[0..self.used]);
        self.used = 0;
    }
};
const RangeMode = enum { count, buffers, points, file, profile };
const CachedPage = struct { pointer: format.Pointer, view: page.View };
const SeriesRuntime = struct {
    root: ?index.View = null,
    active_leaf: ?index.View = null,
    single_page: ?index.Entry = null,
    active_page: ?CachedPage = null,
};

pub fn ReaderFor(comptime File: type) type {
    return struct {
        const Self = @This();
        const Mapping = if (File == std.fs.File) ?[]align(std.heap.page_size_min) u8 else void;

        pub const Cursor = struct {
            series: SeriesHandle,
            next_timestamp: i64,
            end: i64,
            complete: bool = false,
            initialized: bool = false,
            depth: u8 = 0,
            frames: [index.height_max]MappedTraversalFrame = undefined,
            current_page: ?page.View = null,
            point_index: u32 = 0,
        };

        allocator: std.mem.Allocator,
        file: File,
        series: std.ArrayList(manifest.Series) = .empty,
        series_names: []u8 = &.{},
        series_runtime: std.ArrayList(SeriesRuntime) = .empty,
        series_directory: SeriesDirectory = .empty,
        generation: u64 = 0,
        root_identity: checksum.Identity = checksum.zero,
        committed_size: u64 = format.control_size,
        observed_file_size: u64,
        verification_cache: [verification_cache_size]VerificationCacheEntry =
            [_]VerificationCacheEntry{.{}} ** verification_cache_size,
        mapping: Mapping = if (File == std.fs.File) null else {},

        pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
            const file = try std.fs.cwd().openFile(path, .{});
            errdefer file.close();
            return openFile(allocator, file, true);
        }

        pub fn openOn(allocator: std.mem.Allocator, file: File) !Self {
            errdefer file.close();
            return openFile(allocator, file, false);
        }

        fn openFile(allocator: std.mem.Allocator, file: File, should_map: bool) !Self {
            const physical_size = try file.getEndPos();
            var loaded = try loadSnapshot(allocator, file, physical_size);
            var self = Self{
                .allocator = allocator,
                .file = file,
                .observed_file_size = physical_size,
            };
            errdefer self.deinitMemory();
            if (loaded) |*snapshot| {
                self.series = snapshot.catalog.series;
                snapshot.catalog.series = .empty;
                self.series_names = snapshot.catalog.names;
                snapshot.catalog.names = &.{};
                defer snapshot.deinit(allocator);
                self.series_directory = try buildSeriesDirectory(allocator, self.series.items);
                self.generation = snapshot.root.generation;
                self.root_identity = snapshot.root_identity;
                self.committed_size = snapshot.root.committed_size;
            }
            try self.series_runtime.resize(allocator, self.series.items.len);
            @memset(self.series_runtime.items, .{});
            if (comptime File == std.fs.File) {
                if (should_map) self.mapping = try mapFile(file, self.committed_size);
            }
            return self;
        }

        pub fn refresh(self: *Self) !bool {
            const physical_size = try self.file.getEndPos();
            // A writer publishes a checkpoint by overwriting a root slot after
            // appending its immutable objects. If this reader opened in that
            // interval, publication changes no file size, so trailing bytes
            // require rechecking the control region until a root adopts them.
            if (physical_size == self.observed_file_size and
                self.observed_file_size == self.committed_size) return false;
            const control = try validateControl(self.file, physical_size);
            var candidates = collectRoots(&control, physical_size);
            const newest = newestRoot(&candidates);
            if (newest == null or newest.?.root.generation <= self.generation) {
                return false;
            }

            var loaded = try loadSnapshotFromCandidates(
                self.allocator,
                self.file,
                &candidates,
            );
            defer loaded.deinit(self.allocator);
            if (loaded.root.generation <= self.generation) {
                self.observed_file_size = physical_size;
                return false;
            }
            var directory = try buildSeriesDirectory(self.allocator, loaded.catalog.series.items);
            errdefer directory.deinit(self.allocator);
            var runtime: std.ArrayList(SeriesRuntime) = .empty;
            errdefer runtime.deinit(self.allocator);
            try runtime.resize(self.allocator, loaded.catalog.series.items.len);
            @memset(runtime.items, .{});
            const new_mapping = if (comptime File == std.fs.File)
                try mapFile(self.file, loaded.root.committed_size)
            else {};

            self.unmap();
            self.series_directory.deinit(self.allocator);
            self.series.deinit(self.allocator);
            if (self.series_names.len > 0) self.allocator.free(self.series_names);
            self.series_runtime.deinit(self.allocator);
            self.series = loaded.catalog.series;
            loaded.catalog.series = .empty;
            self.series_names = loaded.catalog.names;
            loaded.catalog.names = &.{};
            self.series_directory = directory;
            self.series_runtime = runtime;
            self.generation = loaded.root.generation;
            self.root_identity = loaded.root_identity;
            self.committed_size = loaded.root.committed_size;
            self.observed_file_size = physical_size;
            self.verification_cache = [_]VerificationCacheEntry{.{}} ** verification_cache_size;
            if (comptime File == std.fs.File) self.mapping = new_mapping;
            return true;
        }

        pub fn prepare(self: *Self, name: []const u8) !SeriesHandle {
            const series_index = self.series_directory.get(name) orelse return error.SeriesNotFound;
            return .{ .index = series_index, .generation = self.generation };
        }

        pub fn latestTimestamp(self: *Self, name: []const u8) !?i64 {
            const handle = try self.prepare(name);
            const entry = try self.resolve(handle);
            try self.verifySeriesRoot(handle.index, entry);
            return entry.summary.timestamp_max;
        }

        /// Return one original stored sample; max_distance is inclusive in timestamp units.
        pub fn lookup(
            self: *Self,
            name: []const u8,
            timestamp: i64,
            mode: LookupMode,
            max_distance: ?u64,
        ) !?Point {
            return self.lookupPrepared(try self.prepare(name), timestamp, mode, max_distance);
        }

        /// Prepared handles remain generation-bound, including for missing results.
        pub fn lookupPrepared(
            self: *Self,
            handle: SeriesHandle,
            timestamp: i64,
            mode: LookupMode,
            max_distance: ?u64,
        ) !?Point {
            const series_entry = try self.resolve(handle);
            const selected: ?Point = switch (mode) {
                .exact => blk: {
                    const point = try self.lookupDirectional(series_entry, handle.index, timestamp, .successor);
                    break :blk if (point != null and point.?.timestamp == timestamp) point else null;
                },
                .predecessor => try self.lookupDirectional(series_entry, handle.index, timestamp, .predecessor),
                .successor => try self.lookupDirectional(series_entry, handle.index, timestamp, .successor),
                .nearest => blk: {
                    const before = try self.lookupDirectional(series_entry, handle.index, timestamp, .predecessor);
                    if (before) |point| if (point.timestamp == timestamp) break :blk before;
                    const after = try self.lookupDirectional(series_entry, handle.index, timestamp, .successor);
                    if (before == null) break :blk after;
                    if (after == null) break :blk before;
                    break :blk if (timestampDistance(before.?.timestamp, timestamp) <=
                        timestampDistance(after.?.timestamp, timestamp)) before else after;
                },
            };
            const point = selected orelse return null;
            if (max_distance) |limit| if (timestampDistance(point.timestamp, timestamp) > limit)
                return null;
            return point;
        }

        fn lookupDirectional(
            self: *Self,
            series_entry: *const manifest.Series,
            series_index: u32,
            timestamp: i64,
            direction: LookupDirection,
        ) !?Point {
            if (comptime File == std.fs.File) if (self.mapping != null) {
                const runtime = &self.series_runtime.items[series_index];
                var node = try self.loadSeriesRoot(runtime, series_entry);
                var depth: usize = 1;
                while (true) {
                    const selected = lookupEntryIndex(&node, timestamp, direction) orelse return null;
                    const entry = node.entryAt(selected);
                    if (node.level == 0) {
                        const view = try self.loadSeriesPage(runtime, series_entry.id, entry);
                        // Cache identity authenticates bytes, not this parent edge.
                        if (view.series_id != series_entry.id or
                            !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                            return error.InvalidDatabase;
                        return lookupPagePoint(view, timestamp, direction);
                    }
                    if (depth == index.height_max) return error.InvalidDatabase;
                    const child = try self.loadMappedIndex(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != node.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    if (child.level == 0) runtime.active_leaf = child;
                    node = child;
                    depth += 1;
                }
            };
            var node = try self.loadNode(series_entry.root);
            if (node.series_id != series_entry.id or
                !summaryEqual(node.summary, series_entry.summary)) return error.InvalidDatabase;
            var depth: usize = 1;
            while (true) {
                const selected = lookupEntryIndex(&node, timestamp, direction) orelse return null;
                const entry = node.entries[selected];
                if (node.level == 0) {
                    var scratch: [format.page_size]u8 = undefined;
                    const view = try self.loadPage(entry.pointer, &scratch);
                    if (view.series_id != series_entry.id or
                        !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                        return error.InvalidDatabase;
                    return lookupPagePoint(view, timestamp, direction);
                }
                if (depth == index.height_max) return error.InvalidDatabase;
                const child = try self.loadNode(entry.pointer);
                if (child.series_id != series_entry.id or child.level + 1 != node.level or
                    !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                node = child;
                depth += 1;
            }
        }

        /// Copy original chart-envelope samples into one complete slot per bound.
        /// Insufficient capacity writes nothing and does not inspect history.
        pub fn envelopeInto(
            self: *Self,
            name: []const u8,
            bounds: []const ChartBucketBounds,
            max_gap: ?u64,
            output: []ChartBucket,
        ) !ChartProgress {
            return self.envelopePreparedInto(try self.prepare(name), bounds, max_gap, output);
        }

        pub fn envelopePreparedInto(
            self: *Self,
            handle: SeriesHandle,
            bounds: []const ChartBucketBounds,
            max_gap: ?u64,
            output: []ChartBucket,
        ) !ChartProgress {
            return self.envelopePreparedInternal(false, handle, bounds, max_gap, output, {});
        }

        fn envelopePreparedInternal(
            self: *Self,
            comptime measured: bool,
            handle: SeriesHandle,
            bounds: []const ChartBucketBounds,
            max_gap: ?u64,
            output: []ChartBucket,
            work: if (measured) *ChartWork else void,
        ) !ChartProgress {
            const series_entry = try self.resolve(handle);
            for (bounds, 0..) |bound, bound_index| {
                if (bound.start > bound.end or
                    (bound_index > 0 and bounds[bound_index - 1].end >= bound.start))
                    return error.InvalidArguments;
            }
            if (output.len < bounds.len) return .{
                .required_buckets = bounds.len,
                .written_buckets = 0,
                .complete = false,
            };
            if (bounds.len != 0) {
                if (comptime File == std.fs.File) {
                    if (self.mapping != null) {
                        try self.envelopeScan(true, measured, handle.index, series_entry, bounds, max_gap, output, work);
                    } else {
                        try self.envelopeScan(false, measured, handle.index, series_entry, bounds, max_gap, output, work);
                    }
                } else {
                    try self.envelopeScan(false, measured, handle.index, series_entry, bounds, max_gap, output, work);
                }
            }
            return .{
                .required_buckets = bounds.len,
                .written_buckets = bounds.len,
                .complete = true,
            };
        }

        fn envelopeScan(
            self: *Self,
            comptime mapped: bool,
            comptime measured: bool,
            series_index: u32,
            series_entry: *const manifest.Series,
            bounds: []const ChartBucketBounds,
            max_gap: ?u64,
            output: []ChartBucket,
            work: if (measured) *ChartWork else void,
        ) !void {
            const Node = if (mapped) index.View else index.Node;
            var frames: [index.height_max]struct { node: Node, next: u16 } = undefined;
            const runtime = &self.series_runtime.items[series_index];
            if (measured) {
                work.index_visits += 1;
                const cached = if (mapped) runtime.root != null or self.cacheContains(series_entry.root) else false;
                if (!cached) work.authenticated_bytes += format.index_node_size;
            }
            const root = if (mapped)
                try self.loadSeriesRoot(runtime, series_entry)
            else
                try self.loadNode(series_entry.root);
            if (root.series_id != series_entry.id or
                !summaryEqual(root.summary, series_entry.summary)) return error.InvalidDatabase;
            frames[0] = .{ .node = root, .next = root.lowerBound(bounds[0].start) };
            var depth: usize = 1;
            var scratch: if (mapped) void else [format.page_size]u8 = undefined;
            var reduction = ChartReduction{ .bounds = bounds, .output = output, .max_gap = max_gap };
            while (depth > 0 and reduction.bucket_index < bounds.len) {
                const frame = &frames[depth - 1];
                if (frame.next == frame.node.count) {
                    depth -= 1;
                    continue;
                }
                const entry = lookupEntryAt(&frame.node, frame.next);
                frame.next += 1;
                try reduction.advanceBefore(entry.summary.timestamp_min);
                if (reduction.bucket_index == bounds.len) break;
                // Disjoint authenticated timestamp coverage cannot contribute.
                if (entry.summary.timestamp_max < bounds[reduction.bucket_index].start) continue;
                if (frame.node.level != 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    if (measured) {
                        work.index_visits += 1;
                        const cached = if (mapped) self.cacheContains(entry.pointer) else false;
                        if (!cached) work.authenticated_bytes += format.index_node_size;
                    }
                    const child = if (mapped)
                        try self.loadMappedIndex(entry.pointer)
                    else
                        try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.node.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    frames[depth] = .{
                        .node = child,
                        .next = child.lowerBound(bounds[reduction.bucket_index].start),
                    };
                    depth += 1;
                    continue;
                }
                const known_page = if (mapped)
                    (if (runtime.active_page) |cached| pointerEqual(cached.pointer, entry.pointer) else false) or
                        self.cacheContains(entry.pointer)
                else
                    false;
                const view = if (mapped)
                    try self.loadSeriesPage(runtime, series_entry.id, entry)
                else
                    try self.loadPage(entry.pointer, &scratch);
                if (view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary)) return error.InvalidDatabase;
                if (measured) {
                    work.page_loads += 1;
                    if (!known_page) {
                        work.authenticated_bytes += entry.pointer.size;
                        work.validation_records += view.statistics.count;
                    }
                }
                try chartSelectPage(view, &reduction, measured, work);
            }
            while (reduction.bucket_index < bounds.len) try reduction.finishBucket();
            if (measured) for (output[0..bounds.len]) |bucket| {
                work.emitted_points += bucket.sample_count;
            };
        }

        pub fn codecCounts(self: *Self, name: []const u8) ![2]usize {
            return self.countCodecs(try self.prepare(name));
        }

        pub fn range(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            output: ?std.fs.File,
        ) !usize {
            const handle = try self.prepare(name);
            if (output) |file| {
                var sink = FileSink{ .file = file };
                const count = try self.rangePreparedInternal(handle, start, end, .file, &sink);
                try sink.flush();
                return count;
            }
            return self.rangePreparedInternal(handle, start, end, .count, {});
        }

        pub fn rangeInto(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            timestamps: []i64,
            values: []f64,
        ) !usize {
            const handle = try self.prepare(name);
            return self.rangePreparedInto(handle, start, end, timestamps, values);
        }

        pub fn rangePreparedInto(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
            timestamps: []i64,
            values: []f64,
        ) !usize {
            if (timestamps.len != values.len) return error.InvalidBatch;
            if (timestamps.len == 0)
                return self.rangePreparedInternal(handle, start, end, .count, {});
            var buffers = RangeBuffers{ .timestamps = timestamps, .values = values };
            return self.rangePreparedInternal(handle, start, end, .buffers, &buffers);
        }

        pub fn rangePoints(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            points: []Point,
        ) !usize {
            return self.rangePreparedPoints(try self.prepare(name), start, end, points);
        }

        pub fn rangePreparedPoints(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
            points: []Point,
        ) !usize {
            if (points.len == 0)
                return self.rangePreparedInternal(handle, start, end, .count, {});
            return self.rangePreparedInternal(handle, start, end, .points, points);
        }

        pub fn cursor(self: *Self, name: []const u8, start: i64, end: i64) !Cursor {
            return self.cursorPrepared(try self.prepare(name), start, end);
        }

        pub fn cursorPrepared(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
        ) !Cursor {
            _ = try self.resolve(handle);
            return .{
                .series = handle,
                .next_timestamp = start,
                .end = end,
                .complete = end < start,
            };
        }

        pub fn cursorNext(
            self: *Self,
            cursor_state: *Cursor,
            timestamps: []i64,
            values: []f64,
        ) !usize {
            if (timestamps.len != values.len or timestamps.len == 0)
                return error.InvalidBatch;
            const series_entry = try self.resolve(cursor_state.series);
            if (cursor_state.complete) return 0;
            if (comptime File == std.fs.File) if (self.mapping != null) {
                return self.cursorNextMapped(series_entry, cursor_state, timestamps, values);
            };
            const found = try self.rangePreparedInto(
                cursor_state.series,
                cursor_state.next_timestamp,
                cursor_state.end,
                timestamps,
                values,
            );
            const copied = @min(found, timestamps.len);
            if (copied == 0 or found <= timestamps.len) {
                cursor_state.complete = true;
                return copied;
            }
            const last = timestamps[copied - 1];
            if (last == std.math.maxInt(i64)) {
                cursor_state.complete = true;
            } else {
                cursor_state.next_timestamp = last + 1;
            }
            return copied;
        }

        fn cursorNextMapped(
            self: *Self,
            series_entry: *const manifest.Series,
            cursor_state: *Cursor,
            timestamps: []i64,
            values: []f64,
        ) !usize {
            const runtime = &self.series_runtime.items[cursor_state.series.index];
            if (!cursor_state.initialized) {
                const root = try self.loadSeriesRoot(runtime, series_entry);
                cursor_state.frames[0] = .{
                    .view = root,
                    .next = root.lowerBound(cursor_state.next_timestamp),
                };
                cursor_state.depth = 1;
                cursor_state.initialized = true;
            }

            var copied: usize = 0;
            while (copied < timestamps.len) {
                if (cursor_state.current_page) |page_view| {
                    var point_index: usize = cursor_state.point_index;
                    if (point_index >= page_view.statistics.count) {
                        cursor_state.current_page = null;
                        continue;
                    }
                    var timestamp_cursor = page_view.timestampCursor(point_index);
                    var value_cursor = page_view.valueCursor(point_index);
                    while (point_index < page_view.statistics.count and copied < timestamps.len) {
                        const timestamp = timestamp_cursor.next();
                        if (timestamp > cursor_state.end) {
                            cursor_state.complete = true;
                            cursor_state.current_page = null;
                            break;
                        }
                        const value = value_cursor.next();
                        timestamps[copied] = timestamp;
                        values[copied] = value;
                        copied += 1;
                        point_index += 1;
                        if (timestamp == std.math.maxInt(i64)) {
                            cursor_state.complete = true;
                            cursor_state.current_page = null;
                            break;
                        }
                        cursor_state.next_timestamp = timestamp + 1;
                    }
                    cursor_state.point_index = @intCast(point_index);
                    if (point_index == page_view.statistics.count)
                        cursor_state.current_page = null;
                    if (cursor_state.complete or copied == timestamps.len) break;
                    continue;
                }

                if (cursor_state.depth == 0) {
                    cursor_state.complete = true;
                    break;
                }
                var frame = &cursor_state.frames[cursor_state.depth - 1];
                if (frame.next >= frame.view.count) {
                    cursor_state.depth -= 1;
                    continue;
                }
                const entry = frame.view.entryAt(frame.next);
                frame.next += 1;
                if (entry.summary.timestamp_min > cursor_state.end) {
                    cursor_state.complete = true;
                    break;
                }
                if (frame.view.level > 0) {
                    if (cursor_state.depth == cursor_state.frames.len)
                        return error.InvalidDatabase;
                    const child = try self.loadMappedIndex(entry.pointer);
                    if (child.series_id != series_entry.id or
                        child.level + 1 != frame.view.level or
                        !summaryEqual(child.summary, entry.summary))
                        return error.InvalidDatabase;
                    if (child.level == 0) runtime.active_leaf = child;
                    cursor_state.frames[cursor_state.depth] = .{
                        .view = child,
                        .next = child.lowerBound(cursor_state.next_timestamp),
                    };
                    cursor_state.depth += 1;
                    continue;
                }

                const page_view = try self.loadSeriesPage(runtime, series_entry.id, entry);
                const point_index = page_view.lowerBound(cursor_state.next_timestamp);
                if (point_index == page_view.statistics.count) continue;
                cursor_state.current_page = page_view;
                cursor_state.point_index = @intCast(point_index);
            }
            return copied;
        }

        pub fn borrowRawPage(
            self: *Self,
            handle: SeriesHandle,
            timestamp: i64,
        ) !BorrowedRawPage {
            if (comptime File != std.fs.File) return error.BorrowedViewUnavailable;
            if (@import("builtin").cpu.arch.endian() != .little)
                return error.BorrowedViewUnavailable;
            const series_entry = try self.resolve(handle);
            const entry = try self.findMappedPage(series_entry, handle.index, timestamp);
            const runtime = &self.series_runtime.items[handle.index];
            const view = try self.loadSeriesPage(runtime, series_entry.id, entry);
            if (timestamp < view.statistics.timestamp_min or
                timestamp > view.statistics.timestamp_max) return error.TimestampNotFound;
            const timestamps = view.rawTimestamps() orelse return error.PageNotRaw;
            const values = view.rawValues() orelse return error.PageNotRaw;
            return .{
                .timestamps = timestamps,
                .values = values,
                .timestamp_min = view.statistics.timestamp_min,
                .timestamp_max = view.statistics.timestamp_max,
            };
        }

        pub fn profileRange(self: *Self, name: []const u8, start: i64, end: i64) !QueryProfile {
            var profile = QueryProfile{};
            const handle = try self.prepare(name);
            _ = try self.rangePreparedInternal(handle, start, end, .profile, &profile);
            return profile;
        }

        pub fn aggregate(self: *Self, name: []const u8, start: i64, end: i64) !Aggregate {
            return self.aggregatePrepared(try self.prepare(name), start, end);
        }

        pub fn aggregatePrepared(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
        ) !Aggregate {
            const series_entry = try self.resolve(handle);
            if (end < start) return .{};
            var result = Aggregate{};
            if (start <= series_entry.summary.timestamp_min and
                end >= series_entry.summary.timestamp_max)
            {
                try self.verifySeriesRoot(handle.index, series_entry);
                mergeAggregateSummary(&result, series_entry.summary);
                return result;
            }
            if (comptime File == std.fs.File) if (self.mapping != null)
                return self.aggregateMapped(handle.index, series_entry, start, end);
            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            if (frames[0].node.series_id != series_entry.id or
                !summaryEqual(frames[0].node.summary, series_entry.summary))
                return error.InvalidDatabase;
            frames[0].next = frames[0].node.lowerBound(start);
            var depth: usize = 1;
            var page_scratch: [format.page_size]u8 = undefined;
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.node.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.node.entries[frame.next];
                frame.next += 1;
                if (entry.summary.timestamp_max < start) continue;
                if (entry.summary.timestamp_min > end) {
                    frame.next = frame.node.count;
                    continue;
                }
                if (entry.summary.timestamp_min >= start and entry.summary.timestamp_max <= end) {
                    mergeAggregateSummary(&result, entry.summary);
                    continue;
                }
                if (frame.node.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.node.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    frames[depth] = .{ .node = child, .next = child.lowerBound(start) };
                    depth += 1;
                } else {
                    const view = try self.loadPage(entry.pointer, &page_scratch);
                    if (view.series_id != series_entry.id or
                        !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                        return error.InvalidDatabase;
                    var point_index = view.lowerBound(start);
                    if (point_index == view.statistics.count) continue;
                    var timestamp_cursor = view.timestampCursor(point_index);
                    var value_cursor = view.valueCursor(point_index);
                    while (point_index < view.statistics.count) : (point_index += 1) {
                        if (timestamp_cursor.next() > end) break;
                        mergeAggregateValue(&result, value_cursor.next());
                    }
                }
            }
            return result;
        }

        fn aggregateMapped(
            self: *Self,
            series_index: u32,
            series_entry: *const manifest.Series,
            start: i64,
            end: i64,
        ) !Aggregate {
            const runtime = &self.series_runtime.items[series_index];
            const root = try self.loadSeriesRoot(runtime, series_entry);
            const first = if (runtime.active_leaf) |leaf|
                if (start >= leaf.summary.timestamp_min and end <= leaf.summary.timestamp_max)
                    leaf
                else
                    root
            else
                root;
            var frames: [index.height_max]MappedTraversalFrame = undefined;
            frames[0] = .{ .view = first, .next = first.lowerBound(start) };
            var depth: usize = 1;
            var result = Aggregate{};
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.view.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.view.entryAt(frame.next);
                frame.next += 1;
                if (entry.summary.timestamp_min > end) {
                    frame.next = frame.view.count;
                    continue;
                }
                if (entry.summary.timestamp_min >= start and entry.summary.timestamp_max <= end) {
                    mergeAggregateSummary(&result, entry.summary);
                    continue;
                }
                if (frame.view.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadMappedIndex(entry.pointer);
                    if (child.series_id != series_entry.id or
                        child.level + 1 != frame.view.level or
                        !summaryEqual(child.summary, entry.summary))
                        return error.InvalidDatabase;
                    if (child.level == 0) runtime.active_leaf = child;
                    frames[depth] = .{ .view = child, .next = child.lowerBound(start) };
                    depth += 1;
                    continue;
                }
                const view = try self.loadSeriesPage(runtime, series_entry.id, entry);
                var point_index = view.lowerBound(start);
                if (point_index == view.statistics.count) continue;
                var timestamp_cursor = view.timestampCursor(point_index);
                var value_cursor = view.valueCursor(point_index);
                while (point_index < view.statistics.count) : (point_index += 1) {
                    if (timestamp_cursor.next() > end) break;
                    mergeAggregateValue(&result, value_cursor.next());
                }
            }
            return result;
        }

        pub fn aggregateWindows(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            resolution: u64,
            output: []Aggregate,
        ) !usize {
            return self.aggregateWindowsPrepared(
                try self.prepare(name),
                start,
                end,
                resolution,
                output,
            );
        }

        pub fn aggregateWindowsPrepared(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
            resolution: u64,
            output: []Aggregate,
        ) !usize {
            const series_entry = try self.resolve(handle);
            if (resolution == 0) return error.InvalidArguments;
            if (end < start) return 0;
            const span: u128 = @intCast(@as(i128, end) - start);
            const bucket_count_u128 = span / resolution + 1;
            if (bucket_count_u128 > std.math.maxInt(usize))
                return error.DatabaseTooLarge;
            const bucket_count: usize = @intCast(bucket_count_u128);
            const filled = @min(bucket_count, output.len);
            if (filled == 0) return bucket_count;
            @memset(output[0..filled], Aggregate{});
            const scan_end = if (filled == bucket_count)
                end
            else blk: {
                // Since filled < bucket_count, this product is no larger than
                // end - start and therefore fits both u128 and i128.
                const covered_span = @as(u128, filled) * resolution;
                break :blk @as(i64, @intCast(
                    @as(i128, start) + @as(i128, @intCast(covered_span)) - 1,
                ));
            };

            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            if (frames[0].node.series_id != series_entry.id or
                !summaryEqual(frames[0].node.summary, series_entry.summary))
                return error.InvalidDatabase;
            frames[0].next = frames[0].node.lowerBound(start);
            var depth: usize = 1;
            var page_scratch: [format.page_size]u8 = undefined;
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.node.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.node.entries[frame.next];
                frame.next += 1;
                if (entry.summary.timestamp_max < start) continue;
                if (entry.summary.timestamp_min > scan_end) {
                    frame.next = frame.node.count;
                    continue;
                }
                if (entry.summary.timestamp_min >= start and
                    entry.summary.timestamp_max <= scan_end)
                {
                    const bucket_min = aggregateBucket(
                        start,
                        resolution,
                        entry.summary.timestamp_min,
                    );
                    const bucket_max = aggregateBucket(
                        start,
                        resolution,
                        entry.summary.timestamp_max,
                    );
                    if (bucket_min == bucket_max) {
                        mergeAggregateSummary(&output[bucket_min], entry.summary);
                        continue;
                    }
                }
                if (frame.node.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or
                        child.level + 1 != frame.node.level or
                        !summaryEqual(child.summary, entry.summary))
                        return error.InvalidDatabase;
                    frames[depth] = .{ .node = child, .next = child.lowerBound(start) };
                    depth += 1;
                    continue;
                }

                const view = try self.loadPage(entry.pointer, &page_scratch);
                if (view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                    return error.InvalidDatabase;
                var point_index = view.lowerBound(start);
                if (point_index == view.statistics.count) continue;
                var timestamp_cursor = view.timestampCursor(point_index);
                var value_cursor = view.valueCursor(point_index);
                while (point_index < view.statistics.count) : (point_index += 1) {
                    const timestamp = timestamp_cursor.next();
                    if (timestamp > scan_end) break;
                    const bucket_index = aggregateBucket(start, resolution, timestamp);
                    mergeAggregateValue(&output[bucket_index], value_cursor.next());
                }
            }
            return bucket_count;
        }

        pub fn close(self: *Self) void {
            self.unmap();
            self.file.close();
            self.deinitMemory();
        }

        fn rangePreparedInternal(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
            comptime mode: RangeMode,
            sink: switch (mode) {
                .count => void,
                .buffers => *RangeBuffers,
                .points => []Point,
                .file => *FileSink,
                .profile => *QueryProfile,
            },
        ) !usize {
            if (end < start) return 0;
            if (comptime File == std.fs.File) if (self.mapping != null) {
                return self.rangeMapped(handle, start, end, mode, sink);
            };
            var timer = if (comptime mode == .profile) try std.time.Timer.start() else {};
            const series_entry = try self.resolve(handle);
            if (comptime mode == .profile) sink.block_lookup_ns += timer.lap();
            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            if (frames[0].node.series_id != series_entry.id or
                !summaryEqual(frames[0].node.summary, series_entry.summary))
            {
                return error.InvalidDatabase;
            }
            if (comptime mode == .count or mode == .profile) {
                if (start <= series_entry.summary.timestamp_min and
                    end >= series_entry.summary.timestamp_max)
                {
                    return @intCast(series_entry.summary.point_count);
                }
            }
            frames[0].next = frames[0].node.lowerBound(start);
            var depth: usize = 1;
            var matches: usize = 0;
            var page_scratch: [format.page_size]u8 = undefined;
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.node.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.node.entries[frame.next];
                frame.next += 1;
                if (entry.summary.timestamp_max < start) continue;
                if (entry.summary.timestamp_min > end) {
                    frame.next = frame.node.count;
                    continue;
                }
                const summarize_covered = switch (mode) {
                    .count, .profile => true,
                    .buffers => matches >= sink.timestamps.len,
                    .points => matches >= sink.len,
                    .file => false,
                };
                if (summarize_covered and entry.summary.timestamp_min >= start and
                    entry.summary.timestamp_max <= end)
                {
                    matches = std.math.add(
                        usize,
                        matches,
                        @intCast(entry.summary.point_count),
                    ) catch return error.DatabaseTooLarge;
                    continue;
                }
                if (frame.node.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.node.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    frames[depth] = .{ .node = child, .next = child.lowerBound(start) };
                    depth += 1;
                    continue;
                }
                if (comptime mode == .profile) timer.reset();
                const view = try self.loadPage(entry.pointer, &page_scratch);
                if (comptime mode == .profile) sink.file_read_ns += timer.lap();
                if (view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                {
                    return error.InvalidDatabase;
                }
                switch (mode) {
                    .buffers => {
                        const output_offset = @min(matches, sink.timestamps.len);
                        matches += try view.rangeInto(
                            start,
                            end,
                            sink.timestamps[output_offset..],
                            sink.values[output_offset..],
                        );
                        continue;
                    },
                    .points => {
                        const output_offset = @min(matches, sink.len);
                        matches += try view.rangePoints(start, end, sink[output_offset..]);
                        continue;
                    },
                    .count => {
                        matches += view.countRange(start, end);
                        continue;
                    },
                    .profile => {
                        matches += view.countRange(start, end);
                        sink.record_decode_ns += timer.lap();
                        continue;
                    },
                    .file => {},
                }
                var point_index = view.lowerBound(start);
                if (point_index == view.statistics.count) continue;
                var timestamp_cursor = view.timestampCursor(point_index);
                var value_cursor = view.valueCursor(point_index);
                while (point_index < view.statistics.count) : (point_index += 1) {
                    const timestamp = timestamp_cursor.next();
                    if (timestamp > end) break;
                    const value = value_cursor.next();
                    try sink.writePoint(timestamp, value);
                    matches += 1;
                }
            }
            return matches;
        }

        fn rangeMapped(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
            comptime mode: RangeMode,
            sink: switch (mode) {
                .count => void,
                .buffers => *RangeBuffers,
                .points => []Point,
                .file => *FileSink,
                .profile => *QueryProfile,
            },
        ) !usize {
            var timer = if (comptime mode == .profile) try std.time.Timer.start() else {};
            const series_entry = try self.resolve(handle);
            if (comptime mode == .profile) sink.block_lookup_ns += timer.lap();
            var frames: [index.height_max]MappedTraversalFrame = undefined;
            const runtime = &self.series_runtime.items[handle.index];
            const root = try self.loadSeriesRoot(runtime, series_entry);
            if (comptime mode == .count or mode == .profile) {
                if (start <= series_entry.summary.timestamp_min and
                    end >= series_entry.summary.timestamp_max)
                {
                    return @intCast(series_entry.summary.point_count);
                }
            }
            if (runtime.single_page) |entry| {
                if (entry.summary.timestamp_max < start or entry.summary.timestamp_min > end)
                    return 0;
                if (comptime mode == .count or mode == .profile) {
                    if (entry.summary.timestamp_min >= start and
                        entry.summary.timestamp_max <= end)
                        return @intCast(entry.summary.point_count);
                }
                const page_view = try self.loadSeriesPage(runtime, series_entry.id, entry);
                switch (mode) {
                    .buffers => return page_view.rangeInto(
                        start,
                        end,
                        sink.timestamps,
                        sink.values,
                    ),
                    .points => return page_view.rangePoints(start, end, sink),
                    .count => return page_view.countRange(start, end),
                    .profile => return page_view.countRange(start, end),
                    .file => {},
                }
                var point_index = page_view.lowerBound(start);
                if (point_index == page_view.statistics.count) return 0;
                var timestamp_cursor = page_view.timestampCursor(point_index);
                var value_cursor = page_view.valueCursor(point_index);
                var single_matches: usize = 0;
                while (point_index < page_view.statistics.count) : (point_index += 1) {
                    const timestamp = timestamp_cursor.next();
                    if (timestamp > end) break;
                    const value = value_cursor.next();
                    try sink.writePoint(timestamp, value);
                    single_matches += 1;
                }
                return single_matches;
            }
            const first = if (runtime.active_leaf) |leaf|
                if (start >= leaf.summary.timestamp_min and end <= leaf.summary.timestamp_max)
                    leaf
                else
                    root
            else
                root;
            frames[0] = .{ .view = first, .next = first.lowerBound(start) };
            var depth: usize = 1;
            var matches: usize = 0;
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.view.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.view.entryAt(frame.next);
                frame.next += 1;
                if (entry.summary.timestamp_min > end) {
                    frame.next = frame.view.count;
                    continue;
                }
                const summarize_covered = switch (mode) {
                    .count, .profile => true,
                    .buffers => matches >= sink.timestamps.len,
                    .points => matches >= sink.len,
                    .file => false,
                };
                if (summarize_covered and entry.summary.timestamp_min >= start and
                    entry.summary.timestamp_max <= end)
                {
                    matches = std.math.add(
                        usize,
                        matches,
                        @intCast(entry.summary.point_count),
                    ) catch return error.DatabaseTooLarge;
                    continue;
                }
                if (frame.view.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadMappedIndex(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.view.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    if (child.level == 0) runtime.active_leaf = child;
                    frames[depth] = .{ .view = child, .next = child.lowerBound(start) };
                    depth += 1;
                    continue;
                }
                if (comptime mode == .profile) timer.reset();
                const page_view = try self.loadSeriesPage(runtime, series_entry.id, entry);
                if (comptime mode == .profile) sink.file_read_ns += timer.lap();
                switch (mode) {
                    .buffers => {
                        const output_offset = @min(matches, sink.timestamps.len);
                        matches += try page_view.rangeInto(
                            start,
                            end,
                            sink.timestamps[output_offset..],
                            sink.values[output_offset..],
                        );
                        continue;
                    },
                    .points => {
                        const output_offset = @min(matches, sink.len);
                        matches += try page_view.rangePoints(start, end, sink[output_offset..]);
                        continue;
                    },
                    .count => {
                        matches += page_view.countRange(start, end);
                        continue;
                    },
                    .profile => {
                        matches += page_view.countRange(start, end);
                        sink.record_decode_ns += timer.lap();
                        continue;
                    },
                    .file => {},
                }
                var point_index = page_view.lowerBound(start);
                if (point_index == page_view.statistics.count) continue;
                var timestamp_cursor = page_view.timestampCursor(point_index);
                var value_cursor = page_view.valueCursor(point_index);
                while (point_index < page_view.statistics.count) : (point_index += 1) {
                    const timestamp = timestamp_cursor.next();
                    if (timestamp > end) break;
                    const value = value_cursor.next();
                    try sink.writePoint(timestamp, value);
                    matches += 1;
                }
            }
            return matches;
        }

        fn loadMappedIndex(self: *Self, pointer: format.Pointer) !index.View {
            if (comptime File != std.fs.File) unreachable;
            if (pointer.kind != .index or pointer.size != format.index_node_size)
                return error.InvalidDatabase;
            const mapped = self.mapping orelse return error.InvalidDatabase;
            const offset = std.math.cast(usize, pointer.offset) orelse return error.InvalidDatabase;
            const end = std.math.add(usize, offset, format.index_node_size) catch
                return error.InvalidDatabase;
            if (end > mapped.len) return error.InvalidDatabase;
            const bytes: *const [format.index_node_size]u8 = @ptrCast(mapped[offset..end].ptr);
            const known = if (comptime File == std.fs.File)
                self.cacheContains(pointer)
            else
                false;
            const decoded = index.view(bytes, pointer, self.committed_size, !known);
            const result = decoded catch |err| switch (err) {
                error.ChecksumMismatch => return err,
                else => return error.InvalidDatabase,
            };
            if (comptime File == std.fs.File) if (!known) self.cacheInsert(pointer);
            return result;
        }

        fn loadSeriesRoot(
            self: *Self,
            runtime: *SeriesRuntime,
            series_entry: *const manifest.Series,
        ) !index.View {
            if (runtime.root) |root| return root;
            const root = try self.loadMappedIndex(series_entry.root);
            if (root.series_id != series_entry.id or
                !summaryEqual(root.summary, series_entry.summary))
                return error.InvalidDatabase;
            runtime.root = root;
            if (root.level == 0 and root.count == 1)
                runtime.single_page = root.entryAt(0);
            return root;
        }

        fn verifySeriesRoot(
            self: *Self,
            series_index: u32,
            series_entry: *const manifest.Series,
        ) !void {
            if (comptime File == std.fs.File) if (self.mapping != null) {
                const runtime = &self.series_runtime.items[series_index];
                _ = try self.loadSeriesRoot(runtime, series_entry);
                return;
            };
            const root = try self.loadNode(series_entry.root);
            if (root.series_id != series_entry.id or
                !summaryEqual(root.summary, series_entry.summary))
                return error.InvalidDatabase;
        }

        fn loadSeriesPage(
            self: *Self,
            runtime: *SeriesRuntime,
            series_id: u32,
            entry: index.Entry,
        ) !page.View {
            if (comptime File != std.fs.File) unreachable;
            if (runtime.active_page) |cached| {
                if (pointerEqual(cached.pointer, entry.pointer)) {
                    if (cached.view.series_id != series_id or
                        !summaryEqual(index.Summary.fromPage(cached.view.statistics), entry.summary))
                        return error.InvalidDatabase;
                    return cached.view;
                }
            }
            const view = try self.loadMappedPage(entry.pointer);
            if (view.series_id != series_id or
                !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                return error.InvalidDatabase;
            runtime.active_page = .{ .pointer = entry.pointer, .view = view };
            return view;
        }

        fn findMappedPage(
            self: *Self,
            series_entry: *const manifest.Series,
            series_index: u32,
            timestamp: i64,
        ) !index.Entry {
            if (comptime File != std.fs.File) return error.BorrowedViewUnavailable;
            if (self.mapping == null) return error.BorrowedViewUnavailable;
            const runtime = &self.series_runtime.items[series_index];
            const root = try self.loadSeriesRoot(runtime, series_entry);
            var node = if (runtime.active_leaf) |leaf|
                if (timestamp >= leaf.summary.timestamp_min and
                    timestamp <= leaf.summary.timestamp_max)
                    leaf
                else
                    root
            else
                root;
            var depth: usize = 0;
            while (true) {
                if (depth == index.height_max) return error.InvalidDatabase;
                const entry_index = node.lowerBound(timestamp);
                if (entry_index >= node.count) return error.TimestampNotFound;
                const entry = node.entryAt(entry_index);
                if (node.level == 0) return entry;
                const child = try self.loadMappedIndex(entry.pointer);
                if (child.series_id != series_entry.id or child.level + 1 != node.level or
                    !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                if (child.level == 0) runtime.active_leaf = child;
                node = child;
                depth += 1;
            }
        }

        fn countCodecs(self: *Self, handle: SeriesHandle) ![2]usize {
            const series_entry = try self.resolve(handle);
            var counts = [_]usize{ 0, 0 };
            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            if (frames[0].node.series_id != series_entry.id or
                !summaryEqual(frames[0].node.summary, series_entry.summary))
                return error.InvalidDatabase;
            var depth: usize = 1;
            var page_scratch: [format.page_size]u8 = undefined;
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.node.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.node.entries[frame.next];
                frame.next += 1;
                if (frame.node.level == 0) {
                    const view = try self.loadPage(entry.pointer, &page_scratch);
                    if (view.series_id != series_entry.id or
                        !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                        return error.InvalidDatabase;
                    counts[
                        if (view.timestamp_codec == .raw and view.value_codec == .raw)
                            0
                        else
                            1
                    ] += 1;
                } else {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or
                        child.level + 1 != frame.node.level or
                        !summaryEqual(child.summary, entry.summary))
                        return error.InvalidDatabase;
                    frames[depth] = .{ .node = child };
                    depth += 1;
                }
            }
            return counts;
        }

        fn loadNode(self: *Self, pointer: format.Pointer) !index.Node {
            if (pointer.kind != .index or pointer.size != format.index_node_size)
                return error.InvalidDatabase;
            // Production views address one immutable mmap snapshot. Generic
            // storage is re-read on every access and may change between reads
            // (the simulator deliberately does this), so it must authenticate
            // every returned byte sequence instead of reusing mmap identity.
            const known = if (comptime File == std.fs.File)
                self.cacheContains(pointer)
            else
                false;
            var scratch: [format.index_node_size]u8 = undefined;
            const bytes: *const [format.index_node_size]u8 = if (comptime File == std.fs.File) blk: {
                if (self.mapping) |mapped| {
                    const offset = std.math.cast(usize, pointer.offset) orelse
                        return error.InvalidDatabase;
                    const end = std.math.add(usize, offset, format.index_node_size) catch
                        return error.InvalidDatabase;
                    if (end > mapped.len) return error.InvalidDatabase;
                    break :blk @ptrCast(mapped[offset..end].ptr);
                }
                if (try self.file.preadAll(&scratch, pointer.offset) != scratch.len)
                    return error.InvalidDatabase;
                break :blk &scratch;
            } else blk: {
                if (try self.file.preadAll(&scratch, pointer.offset) != scratch.len)
                    return error.InvalidDatabase;
                break :blk &scratch;
            };
            const decoded = if (known)
                index.decodeKnown(bytes, pointer, self.committed_size)
            else
                index.decode(bytes, pointer, self.committed_size);
            const node = decoded catch |err| switch (err) {
                error.ChecksumMismatch => return err,
                else => return error.InvalidDatabase,
            };
            if (comptime File == std.fs.File) if (!known) self.cacheInsert(pointer);
            return node;
        }

        fn loadMappedPage(self: *Self, pointer: format.Pointer) !page.View {
            if (comptime File != std.fs.File) unreachable;
            if (pointer.kind != .data or pointer.size > format.page_size or
                pointer.size < format.page_header_size) return error.InvalidDatabase;
            const mapped = self.mapping orelse return error.InvalidDatabase;
            const offset = std.math.cast(usize, pointer.offset) orelse
                return error.InvalidDatabase;
            const end = std.math.add(usize, offset, pointer.size) catch
                return error.InvalidDatabase;
            if (end > mapped.len) return error.InvalidDatabase;
            const bytes = mapped[offset..end];
            const known = self.cacheContains(pointer);
            const decoded = if (known)
                page.decodeKnown(bytes, pointer.identity)
            else
                page.decode(bytes, pointer.identity);
            const view = decoded catch |err| switch (err) {
                error.ChecksumMismatch => return err,
                else => return error.InvalidDatabase,
            };
            if (!known) self.cacheInsert(pointer);
            return view;
        }

        fn loadPage(
            self: *Self,
            pointer: format.Pointer,
            scratch: *[format.page_size]u8,
        ) !page.View {
            if (comptime File == std.fs.File) if (self.mapping != null)
                return self.loadMappedPage(pointer);
            if (pointer.kind != .data or pointer.size > format.page_size or
                pointer.size < format.page_header_size) return error.InvalidDatabase;
            const size: usize = pointer.size;
            const bytes: []const u8 = if (comptime File == std.fs.File) blk: {
                if (try self.file.preadAll(scratch[0..size], pointer.offset) != size)
                    return error.InvalidDatabase;
                break :blk scratch[0..size];
            } else blk: {
                if (try self.file.preadAll(scratch[0..size], pointer.offset) != size)
                    return error.InvalidDatabase;
                break :blk scratch[0..size];
            };
            const known = if (comptime File == std.fs.File)
                self.cacheContains(pointer)
            else
                false;
            const decoded = if (known)
                page.decodeKnown(bytes, pointer.identity)
            else
                page.decode(bytes, pointer.identity);
            const view = decoded catch |err| switch (err) {
                error.ChecksumMismatch => return err,
                else => return error.InvalidDatabase,
            };
            if (comptime File == std.fs.File) if (!known) self.cacheInsert(pointer);
            return view;
        }

        fn cacheSlot(pointer: format.Pointer) usize {
            const identity_word = std.mem.readInt(u64, pointer.identity[0..8], .little);
            var mixed = pointer.offset ^ (pointer.offset >> 12) ^ identity_word;
            mixed *%= 0x9e3779b97f4a7c15;
            return @intCast(mixed % verification_cache_size);
        }

        fn cacheContains(self: *const Self, pointer: format.Pointer) bool {
            const base = cacheSlot(pointer);
            for (0..verification_cache_ways) |way| {
                const entry = self.verification_cache[(base + way) % verification_cache_size];
                if (!entry.valid) return false;
                if (entry.offset == pointer.offset and entry.size == pointer.size and
                    entry.kind == pointer.kind and std.mem.eql(u8, &entry.identity, &pointer.identity))
                {
                    return true;
                }
            }
            return false;
        }

        fn cacheInsert(self: *Self, pointer: format.Pointer) void {
            const base = cacheSlot(pointer);
            var slot = base;
            for (0..verification_cache_ways) |way| {
                const candidate = (base + way) % verification_cache_size;
                if (!self.verification_cache[candidate].valid) {
                    slot = candidate;
                    break;
                }
            }
            self.verification_cache[slot] = .{
                .offset = pointer.offset,
                .size = pointer.size,
                .kind = pointer.kind,
                .identity = pointer.identity,
                .valid = true,
            };
        }

        fn resolve(self: *Self, handle: SeriesHandle) !*const manifest.Series {
            if (handle.generation != self.generation or handle.index >= self.series.items.len)
                return error.StaleSeriesHandle;
            return &self.series.items[handle.index];
        }

        fn mapFile(file: File, size: u64) !Mapping {
            if (comptime File != std.fs.File) return {};
            const length = std.math.cast(usize, size) orelse return error.FileTooBig;
            return try std.posix.mmap(
                null,
                length,
                std.posix.PROT.READ,
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
        }

        fn unmap(self: *Self) void {
            if (comptime File == std.fs.File) if (self.mapping) |mapped| {
                std.posix.munmap(mapped);
                self.mapping = null;
            };
        }

        fn deinitMemory(self: *Self) void {
            self.series.deinit(self.allocator);
            if (self.series_names.len > 0) self.allocator.free(self.series_names);
            self.series_runtime.deinit(self.allocator);
            self.series_directory.deinit(self.allocator);
        }
    };
}

pub const Reader = ReaderFor(std.fs.File);

fn aggregateBucket(start: i64, resolution: u64, timestamp: i64) usize {
    std.debug.assert(timestamp >= start);
    const distance: u128 = @intCast(@as(i128, timestamp) - start);
    return @intCast(distance / resolution);
}

fn mergeAggregateSummary(result: *Aggregate, summary: index.Summary) void {
    if (result.count == 0) result.first = summary.value_first;
    result.last = summary.value_last;
    result.minimum = minimum(result.minimum, summary.value_min);
    result.maximum = maximum(result.maximum, summary.value_max);
    result.sum += summary.value_sum;
    result.count += summary.point_count;
}

fn mergeAggregateValue(result: *Aggregate, value: f64) void {
    if (result.count == 0) result.first = value;
    result.last = value;
    if (!std.math.isNan(value)) {
        result.minimum = minimum(result.minimum, value);
        result.maximum = maximum(result.maximum, value);
        result.sum += value;
    }
    result.count += 1;
}

fn timestampsStrictlyIncreasing(timestamps: []const i64) bool {
    if (timestamps.len < 2) return true;
    const Vector = @Vector(4, i64);
    var position: usize = 1;
    while (position + 4 <= timestamps.len) : (position += 4) {
        const previous: Vector = timestamps[position - 1 ..][0..4].*;
        const current: Vector = timestamps[position..][0..4].*;
        if (@reduce(.Or, current <= previous)) return false;
    }
    while (position < timestamps.len) : (position += 1) {
        if (timestamps[position] <= timestamps[position - 1]) return false;
    }
    return true;
}

pub const VerificationReport = struct {
    checkpoint: u64,
    series_count: u64,
    record_count: u64,
    block_count: u64,
    compressed_blocks: u64,
    logical_size: u64,
    physical_size: u64,
    trailing_bytes: u64,
    oldest_timestamp: ?i64,
    newest_timestamp: ?i64,
};

const VerifyInterval = struct { start: u64, end: u64 };

pub fn verifyPath(allocator: std.mem.Allocator, path: []const u8) !VerificationReport {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const physical_size = try file.getEndPos();
    var loaded = (try loadSnapshot(allocator, file, physical_size)) orelse
        return error.NoCheckpoint;
    defer loaded.deinit(allocator);

    var report = VerificationReport{
        .checkpoint = loaded.root.generation,
        .series_count = loaded.catalog.series.items.len,
        .record_count = 0,
        .block_count = 0,
        .compressed_blocks = 0,
        .logical_size = 0,
        .physical_size = physical_size,
        .trailing_bytes = physical_size - loaded.root.committed_size,
        .oldest_timestamp = null,
        .newest_timestamp = null,
    };
    var intervals: std.ArrayList(VerifyInterval) = .empty;
    defer intervals.deinit(allocator);
    try intervals.append(allocator, .{
        .start = loaded.root.manifest.offset,
        .end = loaded.root.committed_size,
    });

    for (loaded.catalog.series.items) |series_entry| {
        report.oldest_timestamp = if (report.oldest_timestamp) |old|
            @min(old, series_entry.summary.timestamp_min)
        else
            series_entry.summary.timestamp_min;
        report.newest_timestamp = if (report.newest_timestamp) |old|
            @max(old, series_entry.summary.timestamp_max)
        else
            series_entry.summary.timestamp_max;
        try verifySeries(
            file,
            allocator,
            loaded.root.committed_size,
            series_entry,
            &intervals,
            &report,
        );
    }
    report.logical_size = std.math.mul(u64, report.record_count, record_size) catch
        return error.DatabaseTooLarge;
    std.sort.heap(VerifyInterval, intervals.items, {}, struct {
        fn lessThan(_: void, a: VerifyInterval, b: VerifyInterval) bool {
            return a.start < b.start;
        }
    }.lessThan);
    for (intervals.items, 0..) |interval, interval_index| {
        if (interval.start < format.control_size or interval.end > loaded.root.committed_size or
            interval.start >= interval.end) return error.InvalidDatabase;
        if (interval_index > 0 and interval.start < intervals.items[interval_index - 1].end)
            return error.OverlappingFileRegions;
    }
    return report;
}

fn verifySeries(
    file: std.fs.File,
    allocator: std.mem.Allocator,
    committed_size: u64,
    series_entry: manifest.Series,
    intervals: *std.ArrayList(VerifyInterval),
    report: *VerificationReport,
) !void {
    const VerifyFrame = struct { node: index.Node, next: u16 = 0 };
    var root_bytes: [format.index_node_size]u8 = undefined;
    if (try file.preadAll(&root_bytes, series_entry.root.offset) != root_bytes.len)
        return error.InvalidDatabase;
    const root = index.decode(&root_bytes, series_entry.root, committed_size) catch |err| switch (err) {
        error.ChecksumMismatch => return err,
        else => return error.InvalidDatabase,
    };
    if (root.series_id != series_entry.id or !summaryEqual(root.summary, series_entry.summary))
        return error.InvalidDatabase;
    try intervals.append(allocator, .{
        .start = series_entry.root.offset,
        .end = series_entry.root.offset + series_entry.root.size,
    });
    var frames: [index.height_max]VerifyFrame = undefined;
    frames[0] = .{ .node = root };
    var depth: usize = 1;
    var node_bytes: [format.index_node_size]u8 = undefined;
    var page_bytes: [format.page_size]u8 = undefined;
    while (depth > 0) {
        var frame = &frames[depth - 1];
        if (frame.next >= frame.node.count) {
            depth -= 1;
            continue;
        }
        const entry = frame.node.entries[frame.next];
        frame.next += 1;
        if (frame.node.level > 0) {
            if (try file.preadAll(&node_bytes, entry.pointer.offset) != node_bytes.len)
                return error.InvalidDatabase;
            const child = index.decode(&node_bytes, entry.pointer, committed_size) catch |err| switch (err) {
                error.ChecksumMismatch => return err,
                else => return error.InvalidDatabase,
            };
            if (child.series_id != series_entry.id or child.level + 1 != frame.node.level or
                !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
            try intervals.append(allocator, .{
                .start = entry.pointer.offset,
                .end = entry.pointer.offset + entry.pointer.size,
            });
            if (depth == frames.len) return error.InvalidDatabase;
            frames[depth] = .{ .node = child };
            depth += 1;
        } else {
            const size: usize = entry.pointer.size;
            if (size > page_bytes.len or
                try file.preadAll(page_bytes[0..size], entry.pointer.offset) != size)
                return error.InvalidDatabase;
            const view = page.decode(page_bytes[0..size], entry.pointer.identity) catch |err| switch (err) {
                error.ChecksumMismatch => return err,
                else => return error.InvalidDatabase,
            };
            if (view.series_id != series_entry.id or
                !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                return error.InvalidDatabase;
            try intervals.append(allocator, .{
                .start = entry.pointer.offset,
                .end = entry.pointer.offset + entry.pointer.size,
            });
            report.record_count += view.statistics.count;
            report.block_count += 1;
            if (view.timestamp_codec != .raw or view.value_codec != .raw)
                report.compressed_blocks += 1;
        }
    }
}

pub fn encodeRecord(timestamp: i64, value: f64) [record_size]u8 {
    var result: [record_size]u8 = undefined;
    std.mem.writeInt(i64, result[0..8], timestamp, .little);
    std.mem.writeInt(u64, result[8..16], @bitCast(value), .little);
    return result;
}

test "strict timestamp validation covers vector tails" {
    try std.testing.expect(timestampsStrictlyIncreasing(&.{ 1, 2, 3, 4, 5, 6, 7 }));
    try std.testing.expect(!timestampsStrictlyIncreasing(&.{ 1, 2, 3, 4, 4, 6, 7 }));
    try std.testing.expect(!timestampsStrictlyIncreasing(&.{ 1, 2, 3, 4, 5, 4, 7 }));
}

// Deliberately linear and independent of index/page search and distance helpers.
fn referenceLookup(
    timestamps: []const i64,
    values: []const f64,
    target: i64,
    mode: LookupMode,
    max_distance: ?u64,
) ?Point {
    var result: ?Point = null;
    var best_distance: i128 = std.math.maxInt(i128);
    for (timestamps, values) |timestamp, value| {
        const eligible = switch (mode) {
            .exact => timestamp == target,
            .predecessor => timestamp <= target,
            .successor => timestamp >= target,
            .nearest => true,
        };
        if (!eligible) continue;
        const delta = @as(i128, timestamp) - target;
        const distance = if (delta < 0) -delta else delta;
        // Ascending input plus strict improvement gives predecessor ties.
        if (distance < best_distance) {
            best_distance = distance;
            result = .{ .timestamp = timestamp, .value = value };
        }
    }
    if (max_distance) |limit| if (best_distance > limit) return null;
    return result;
}

fn expectLookupPoint(expected: ?Point, actual: ?Point) !void {
    if (expected) |point| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqual(point.timestamp, actual.?.timestamp);
        try std.testing.expectEqual(@as(u64, @bitCast(point.value)), @as(u64, @bitCast(actual.?.value)));
    } else {
        try std.testing.expect(actual == null);
    }
}

const LookupTestFile = struct {
    file: std.fs.File,
    reads: *usize,

    pub fn getEndPos(self: @This()) !u64 {
        return self.file.getEndPos();
    }

    pub fn preadAll(self: @This(), bytes: []u8, offset: u64) !usize {
        self.reads.* += 1;
        return self.file.preadAll(bytes, offset);
    }

    pub fn close(self: @This()) void {
        self.file.close();
    }
};

fn checkLookupTarget(reader: anytype, timestamps: []const i64, values: []const f64, target: i64) !void {
    const handle = try reader.prepare("signal");
    const reads_per_path: usize = if (comptime @TypeOf(reader.*) == ReaderFor(LookupTestFile))
        @as(usize, (try reader.loadNode(reader.series.items[handle.index].root)).level) + 2
    else
        0;
    inline for (std.meta.tags(LookupMode)) |mode| {
        var limits = [_]?u64{ null, 0, 1, 2, 9, std.math.maxInt(u64), null, null, null };
        if (referenceLookup(timestamps, values, target, mode, null)) |selected| {
            const delta = @as(i128, selected.timestamp) - target;
            const distance: u64 = @intCast(if (delta < 0) -delta else delta);
            limits[6] = distance;
            limits[7] = if (distance > 0) distance - 1 else 0;
            limits[8] = if (distance < std.math.maxInt(u64)) distance + 1 else distance;
        }
        for (limits) |limit| {
            const expected = referenceLookup(timestamps, values, target, mode, limit);
            if (comptime @TypeOf(reader.*) == ReaderFor(LookupTestFile)) reader.file.reads.* = 0;
            try expectLookupPoint(expected, try reader.lookupPrepared(handle, target, mode, limit));
            if (comptime @TypeOf(reader.*) == ReaderFor(LookupTestFile)) {
                const paths: usize = if (mode == .nearest) 2 else 1;
                try std.testing.expect(reader.file.reads.* <= paths * reads_per_path);
            }
            try expectLookupPoint(expected, try reader.lookup("signal", target, mode, limit));
        }
    }
}

test "temporal lookup reference covers extrema ties missing tolerance and exact value bits" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const timestamps = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -100, -10, 0, 10, 100, std.math.maxInt(i64) - 1, std.math.maxInt(i64) };
    const values = [_]f64{ -0.0, 0.0, -2.5, 42, @bitCast(@as(u64, 1)), 1.5, 7, 3, 9 };
    const targets = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, std.math.minInt(i64) + 2, -101, -100, -99, -55, -10, -5, -1, 0, 1, 5, 10, 55, 99, 100, 101, std.math.maxInt(i64) - 2, std.math.maxInt(i64) - 1, std.math.maxInt(i64) };
    inline for (.{ Codec.raw, Codec.compressed }) |codec| {
        const filename = if (codec == .raw) "extreme-raw.ctdb" else "extreme-compressed.ctdb";
        var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile(filename, .{ .read = true }), codec);
        defer writer.abort();
        try writer.prepareSeries("unpublished", 1);
        try writer.appendBatch("signal", &timestamps, &values);
        try writer.append("single", std.math.minInt(i64), -0.0);
        try writer.appendBatch("bounded", &.{ -10, 10 }, &.{ 0, 2 });
        try writer.appendBatch("regular", &.{ -20, -10, 0, 10, 20 }, &.{ 1, 1, 1, 1, 1 });
        try writer.checkpoint(false);
        const path = try temporary.dir.realpathAlloc(std.testing.allocator, filename);
        defer std.testing.allocator.free(path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var mapped = try Reader.open(failing.allocator(), path);
        defer mapped.close();
        var reads: usize = 0;
        var generic = try ReaderFor(LookupTestFile).openOn(failing.allocator(), .{ .file = try temporary.dir.openFile(filename, .{}), .reads = &reads });
        defer generic.close();
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        const deallocations = failing.deallocations;
        for (targets) |target| {
            try checkLookupTarget(&mapped, &timestamps, &values, target);
            try checkLookupTarget(&generic, &timestamps, &values, target);
        }
        inline for (.{ &mapped, &generic }) |reader| {
            try std.testing.expectError(error.SeriesNotFound, reader.lookup("unknown", 0, .exact, null));
            try std.testing.expectError(error.SeriesNotFound, reader.lookup("unpublished", 0, .nearest, null));
            try std.testing.expectError(error.StaleSeriesHandle, reader.lookupPrepared(.{ .index = std.math.maxInt(u32), .generation = reader.generation }, 0, .nearest, 0));
            try std.testing.expectError(error.StaleSeriesHandle, reader.lookupPrepared(.{ .index = 0, .generation = reader.generation - 1 }, 0, .exact, 0));
            try std.testing.expect((try reader.lookup("bounded", -11, .predecessor, null)) == null);
            try std.testing.expect((try reader.lookup("bounded", 11, .successor, null)) == null);
            inline for (std.meta.tags(LookupMode)) |mode| {
                for ([_]i64{ -21, -20, -15, 0, 15, 20, 21 }) |target| {
                    try expectLookupPoint(referenceLookup(&.{ -20, -10, 0, 10, 20 }, &.{ 1, 1, 1, 1, 1 }, target, mode, null), try reader.lookup("regular", target, mode, null));
                }
            }
            try std.testing.expect((try reader.lookup("single", std.math.maxInt(i64), .predecessor, std.math.maxInt(u64) - 1)) == null);
            try expectLookupPoint(.{ .timestamp = std.math.minInt(i64), .value = -0.0 }, try reader.lookup("single", std.math.maxInt(i64), .nearest, std.math.maxInt(u64)));
        }
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(failing.fail_index, failing.alloc_index);
        try std.testing.expectEqual(failing.resize_fail_index, failing.resize_index);
        try std.testing.expectEqual(deallocations, failing.deallocations);
    }
}

test "temporal lookup crosses pages and index children without scanning history" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const per_page = 131;
    const pages = index.entry_capacity + 3;
    var timestamps: [per_page * pages]i64 = undefined;
    var values: [timestamps.len]f64 = undefined;
    var timestamp: i64 = -20000;
    for (&timestamps, &values, 0..) |*stored_timestamp, *value, point_index| {
        timestamp += @intCast(2 + point_index % 11);
        stored_timestamp.* = timestamp;
        value.* = 20 + @as(f64, @floatFromInt(point_index % 100)) * 0.001;
    }
    inline for (.{ Codec.raw, Codec.compressed }) |codec| {
        const filename = if (codec == .raw) "boundary-raw.ctdb" else "boundary-compressed.ctdb";
        var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile(filename, .{ .read = true }), codec);
        defer writer.abort();
        for (0..pages) |page_index| {
            const start = page_index * per_page;
            try writer.appendBatch("signal", timestamps[start..][0..per_page], values[start..][0..per_page]);
            try writer.checkpoint(false);
        }
        const path = try temporary.dir.realpathAlloc(std.testing.allocator, filename);
        defer std.testing.allocator.free(path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var mapped = try Reader.open(failing.allocator(), path);
        defer mapped.close();
        var reads: usize = 0;
        var generic = try ReaderFor(LookupTestFile).openOn(failing.allocator(), .{ .file = try temporary.dir.openFile(filename, .{}), .reads = &reads });
        defer generic.close();
        const root = try generic.loadNode(generic.series.items[0].root);
        try std.testing.expect(root.level > 0);
        const codecs = try generic.codecCounts("signal");
        try std.testing.expectEqual(@as(usize, pages), codecs[if (codec == .raw) 0 else 1]);
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        const deallocations = failing.deallocations;
        for (0..pages) |page_index| {
            const first = page_index * per_page;
            const targets = [_]i64{ timestamps[first] - 1, timestamps[first], timestamps[first] + 1, timestamps[first + 127], timestamps[first + 128] - 1, timestamps[first + 130], timestamps[first + 130] + 1 };
            for (targets) |target| {
                try checkLookupTarget(&mapped, &timestamps, &values, target);
                try checkLookupTarget(&generic, &timestamps, &values, target);
            }
        }
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(failing.fail_index, failing.alloc_index);
        try std.testing.expectEqual(failing.resize_fail_index, failing.resize_index);
        try std.testing.expectEqual(deallocations, failing.deallocations);
    }
}

test "temporal lookup refresh invalidates handles and preserves copied points" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile("refresh.ctdb", .{ .read = true });
    var writer = try Appender.createOn(std.testing.allocator, file, .compressed);
    defer writer.abort();
    try writer.append("signal", 10, -0.0);
    try writer.checkpoint(false);
    const path = try temporary.dir.realpathAlloc(std.testing.allocator, "refresh.ctdb");
    defer std.testing.allocator.free(path);
    var mapped = try Reader.open(std.testing.allocator, path);
    defer mapped.close();
    var reads: usize = 0;
    var generic = try ReaderFor(LookupTestFile).openOn(std.testing.allocator, .{ .file = try temporary.dir.openFile("refresh.ctdb", .{}), .reads = &reads });
    defer generic.close();
    const mapped_handle = try mapped.prepare("signal");
    const generic_handle = try generic.prepare("signal");
    const copied = try mapped.lookupPrepared(mapped_handle, 10, .exact, null);
    try std.testing.expect(!try mapped.refresh());
    try std.testing.expect(!try generic.refresh());
    try writer.append("signal", 20, 2);
    try writer.checkpoint(false);
    inline for (.{ &mapped, &generic }, .{ mapped_handle, generic_handle }) |reader, old_handle| {
        try expectLookupPoint(.{ .timestamp = 10, .value = -0.0 }, try reader.lookup("signal", 20, .nearest, null));
        try std.testing.expect(try reader.refresh());
        inline for (std.meta.tags(LookupMode)) |mode| {
            try std.testing.expectError(error.StaleSeriesHandle, reader.lookupPrepared(old_handle, std.math.minInt(i64), mode, 0));
        }
        try checkLookupTarget(reader, &.{ 10, 20 }, &.{ -0.0, 2 }, 15);
        try checkLookupTarget(reader, &.{ 10, 20 }, &.{ -0.0, 2 }, 20);
    }
    try expectLookupPoint(.{ .timestamp = 10, .value = -0.0 }, copied);
}

test "temporal lookup uses byte cursors for generic unaligned pages and reauthenticates" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile("generic.ctdb", .{ .read = true }), .raw);
    defer writer.abort();
    try writer.appendBatch("signal", &.{ -10, 0, 10 }, &.{ -0.0, 0, 1.5 });
    try writer.checkpoint(false);
    var reads: usize = 0;
    var reader = try ReaderFor(LookupTestFile).openOn(std.testing.allocator, .{ .file = try temporary.dir.openFile("generic.ctdb", .{}), .reads = &reads });
    defer reader.close();
    const handle = try reader.prepare("signal");
    const series_entry = &reader.series.items[handle.index];
    var node = try reader.loadNode(series_entry.root);
    const pointer = node.entries[0].pointer;
    var buffer: [format.page_size + 8]u8 align(8) = undefined;
    const scratch: *[format.page_size]u8 = @ptrCast(buffer[1..][0..format.page_size].ptr);
    const view = try reader.loadPage(pointer, scratch);
    try std.testing.expect(view.rawTimestamps() == null);
    try std.testing.expect(view.rawValues() == null);
    for ([_]i64{ -11, -10, -5, 0, 5, 10, 11 }) |target| {
        try expectLookupPoint(referenceLookup(&.{ -10, 0, 10 }, &.{ -0.0, 0, 1.5 }, target, .predecessor, null), lookupPagePoint(view, target, .predecessor));
        try expectLookupPoint(referenceLookup(&.{ -10, 0, 10 }, &.{ -0.0, 0, 1.5 }, target, .successor, null), lookupPagePoint(view, target, .successor));
        try checkLookupTarget(&reader, &.{ -10, 0, 10 }, &.{ -0.0, 0, 1.5 }, target);
    }
    const mutable = try temporary.dir.openFile("generic.ctdb", .{ .mode = .read_write });
    defer mutable.close();
    // Warm reads must not suppress authentication when generic bytes mutate.
    try mutable.pwriteAll(&.{0xff}, pointer.offset + format.page_header_size);
    try std.testing.expectError(error.ChecksumMismatch, reader.lookupPrepared(handle, 0, .exact, null));
    try mutable.pwriteAll(view.bytes, pointer.offset);
    // A valid identity does not establish series identity, even for missing queries.
    node.series_id += 1;
    var encoded: [format.index_node_size]u8 = undefined;
    try index.encode(&node, &encoded);
    try mutable.pwriteAll(&encoded, series_entry.root.offset);
    series_entry.root.identity = checksum.calculate(&encoded);
    try std.testing.expectError(error.InvalidDatabase, reader.lookupPrepared(handle, -11, .predecessor, null));
    try std.testing.expectError(error.InvalidDatabase, reader.lookupPrepared(handle, 11, .successor, 0));
}

test "temporal lookup validates cached page against each authenticated index entry" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile("cached.ctdb", .{ .read = true });
    var writer = try Appender.createOn(std.testing.allocator, file, .raw);
    defer writer.abort();
    try writer.append("signal", -10, 1);
    try writer.checkpoint(false);
    try writer.append("signal", 10, 2);
    try writer.checkpoint(false);
    const pointer = writer.series.items[0].root.?;
    var encoded: [format.index_node_size]u8 = undefined;
    try std.testing.expectEqual(encoded.len, try file.preadAll(&encoded, pointer.offset));
    var node = try index.decode(&encoded, pointer, writer.committed_size);
    try std.testing.expectEqual(@as(u16, 2), node.count);
    // Forge a valid index identity with conflicting summaries for one page.
    node.entries[1].pointer = node.entries[0].pointer;
    try index.encode(&node, &encoded);
    try file.pwriteAll(&encoded, pointer.offset);
    const path = try temporary.dir.realpathAlloc(std.testing.allocator, "cached.ctdb");
    defer std.testing.allocator.free(path);
    var reader = try Reader.open(std.testing.allocator, path);
    defer reader.close();
    const handle = try reader.prepare("signal");
    // Supply the forged authenticated manifest edge before the first traversal.
    reader.series.items[handle.index].root.identity = checksum.calculate(&encoded);
    try expectLookupPoint(.{ .timestamp = -10, .value = 1 }, try reader.lookupPrepared(handle, -10, .exact, null));
    inline for (std.meta.tags(LookupMode)) |mode| {
        try std.testing.expectError(error.InvalidDatabase, reader.lookupPrepared(handle, 10, mode, null));
    }
}

// Build and re-sign the complete fixture before opening any mapped reader.
// No reader/catalog injection or mutation of mapped bytes is required.
fn writeCachedPageEdgeFixture(directory: std.fs.Dir, codec: Codec, conflicting: bool) !void {
    {
        const file = try directory.createFile("cached-edge.ctdb", .{ .read = true });
        var writer = try Appender.createOn(std.testing.allocator, file, codec);
        var open = true;
        defer if (open) writer.abort();
        try writer.append("signal", -10, 1);
        try writer.checkpoint(false);
        try writer.appendBatch("signal", &.{ 10, 20 }, &.{ 2, 3 });
        try writer.checkpoint(false);
        open = false;
        try writer.close();
    }
    if (!conflicting) return;

    const file = try directory.openFile("cached-edge.ctdb", .{ .mode = .read_write });
    defer file.close();
    const physical_size = try file.getEndPos();
    var snapshot = (try loadSnapshot(std.testing.allocator, file, physical_size)) orelse
        return error.MissingFixtureSnapshot;
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), snapshot.root.generation);
    try std.testing.expectEqual(@as(usize, 1), snapshot.catalog.series.items.len);

    const series = &snapshot.catalog.series.items[0];
    var node_bytes: [format.index_node_size]u8 = undefined;
    try std.testing.expectEqual(node_bytes.len, try file.preadAll(&node_bytes, series.root.offset));
    var node = try index.decode(&node_bytes, series.root, snapshot.root.committed_size);
    try std.testing.expectEqual(@as(u8, 0), node.level);
    try std.testing.expectEqual(@as(u16, 2), node.count);
    // Retain two ordered, nonoverlapping summaries but point both at the first
    // page. Byte authentication remains valid; the second page edge is false.
    node.entries[1].pointer = node.entries[0].pointer;
    try index.encode(&node, &node_bytes);
    series.root.identity = checksum.calculate(&node_bytes);
    _ = try index.decode(&node_bytes, series.root, snapshot.root.committed_size);
    try std.testing.expect(summaryEqual(node.summary, series.summary));
    try file.pwriteAll(&node_bytes, series.root.offset);

    var manifest_bytes: std.ArrayList(u8) = .empty;
    defer manifest_bytes.deinit(std.testing.allocator);
    var manifest_pointer = try manifest.encode(
        &manifest_bytes,
        std.testing.allocator,
        snapshot.root.generation,
        snapshot.catalog.series.items,
    );
    try std.testing.expectEqual(snapshot.root.manifest.size, manifest_pointer.size);
    manifest_pointer.offset = snapshot.root.manifest.offset;
    try file.pwriteAll(manifest_bytes.items, manifest_pointer.offset);

    const control = try validateControl(file, physical_size);
    const candidates = collectRoots(&control, physical_size);
    const root = format.Root{
        .generation = snapshot.root.generation,
        .committed_size = snapshot.root.committed_size,
        .manifest = manifest_pointer,
        .previous_identity = snapshot.root.previous_identity,
    };
    var encoded_root: [format.root_slot_size]u8 = undefined;
    root.encode(&encoded_root);
    var replaced = false;
    for (candidates, 0..) |candidate, slot| {
        if (candidate) |value| {
            if (!checksum.equal(value.identity, snapshot.root_identity)) continue;
            try std.testing.expect(rootHasValidPredecessor(&candidates, value));
            try file.pwriteAll(&encoded_root, try format.rootSlotOffset(slot));
            replaced = true;
        }
    }
    try std.testing.expect(replaced);
    // Reader.open must select the re-signed newest generation, not a fallback.
    var authenticated = (try loadSnapshot(std.testing.allocator, file, physical_size)) orelse
        return error.MissingFixtureSnapshot;
    defer authenticated.deinit(std.testing.allocator);
    try std.testing.expectEqual(root.generation, authenticated.root.generation);
    try std.testing.expect(checksum.equal(
        authenticated.catalog.series.items[0].root.identity,
        series.root.identity,
    ));
}

fn openCachedPageEdgeFixture(directory: std.fs.Dir, allocator: std.mem.Allocator) !Reader {
    const path = try directory.realpathAlloc(std.testing.allocator, "cached-edge.ctdb");
    defer std.testing.allocator.free(path);
    return Reader.open(allocator, path);
}

fn warmCachedPageEdge(reader: *Reader, handle: SeriesHandle) !void {
    var timestamps: [1]i64 = undefined;
    var values: [1]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reader.rangePreparedInto(
        handle,
        -10,
        -10,
        &timestamps,
        &values,
    ));
    try std.testing.expectEqual(@as(i64, -10), timestamps[0]);
    try std.testing.expectEqual(@as(f64, 1), values[0]);
}

test "mapped cached page range validates every authenticated edge" {
    for ([_]Codec{ .raw, .compressed }) |codec| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try writeCachedPageEdgeFixture(temporary.dir, codec, true);
        var reader = try openCachedPageEdgeFixture(temporary.dir, std.testing.allocator);
        defer reader.close();
        try std.testing.expectEqual(@as(u64, 3), reader.generation);
        try std.testing.expect(reader.mapping != null);
        const handle = try reader.prepare("signal");
        var timestamps: [1]i64 = undefined;
        var values: [1]f64 = undefined;

        // A cold edge already fails: the regression concerns the cache hit.
        try std.testing.expectError(error.InvalidDatabase, reader.rangePreparedInto(
            handle,
            10,
            15,
            &timestamps,
            &values,
        ));
        try warmCachedPageEdge(&reader, handle);
        try std.testing.expectError(error.InvalidDatabase, reader.rangePreparedInto(
            handle,
            10,
            15,
            &timestamps,
            &values,
        ));
        var points: [1]Point = undefined;
        try std.testing.expectError(error.InvalidDatabase, reader.rangePreparedPoints(handle, 10, 15, &points));
        try std.testing.expectError(error.InvalidDatabase, reader.range("signal", 10, 15, null));
        try std.testing.expectError(error.InvalidDatabase, reader.borrowRawPage(handle, 10));
        try warmCachedPageEdge(&reader, handle);
    }
}

test "mapped cached page cursor validates every authenticated edge" {
    for ([_]Codec{ .raw, .compressed }) |codec| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try writeCachedPageEdgeFixture(temporary.dir, codec, true);
        var reader = try openCachedPageEdgeFixture(temporary.dir, std.testing.allocator);
        defer reader.close();
        try std.testing.expectEqual(@as(u64, 3), reader.generation);
        const handle = try reader.prepare("signal");
        var cursor = try reader.cursorPrepared(handle, -10, 20);
        var timestamps: [1]i64 = undefined;
        var values: [1]f64 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try reader.cursorNext(&cursor, &timestamps, &values));
        try std.testing.expectEqual(@as(i64, -10), timestamps[0]);
        try std.testing.expectEqual(@as(f64, 1), values[0]);
        // The cursor itself warms the first page before selecting the false edge.
        try std.testing.expectError(error.InvalidDatabase, reader.cursorNext(&cursor, &timestamps, &values));
    }
}

test "mapped cached page partial aggregate validates every authenticated edge" {
    for ([_]Codec{ .raw, .compressed }) |codec| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try writeCachedPageEdgeFixture(temporary.dir, codec, true);
        var reader = try openCachedPageEdgeFixture(temporary.dir, std.testing.allocator);
        defer reader.close();
        try std.testing.expectEqual(@as(u64, 3), reader.generation);
        const handle = try reader.prepare("signal");
        try warmCachedPageEdge(&reader, handle);
        // [10,15] only partly covers [10,20], so this loads rather than summarizes.
        try std.testing.expectError(error.InvalidDatabase, reader.aggregatePrepared(handle, 10, 15));
    }
}

test "mapped cached page matching edges preserve bounded allocation-free reads" {
    for ([_]Codec{ .raw, .compressed }) |codec| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try writeCachedPageEdgeFixture(temporary.dir, codec, false);
        var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var reader = try openCachedPageEdgeFixture(temporary.dir, allocations.allocator());
        defer reader.close();
        const handle = try reader.prepare("signal");
        allocations.fail_index = allocations.alloc_index;
        allocations.resize_fail_index = allocations.resize_index;
        try warmCachedPageEdge(&reader, handle);

        var timestamps: [2]i64 = undefined;
        var values: [2]f64 = undefined;
        for (0..3) |capacity| {
            try std.testing.expectEqual(@as(usize, 2), try reader.rangePreparedInto(
                handle,
                10,
                20,
                timestamps[0..capacity],
                values[0..capacity],
            ));
            try std.testing.expectEqualSlices(i64, (&[_]i64{ 10, 20 })[0..capacity], timestamps[0..capacity]);
            try std.testing.expectEqualSlices(f64, (&[_]f64{ 2, 3 })[0..capacity], values[0..capacity]);
        }
        try std.testing.expectEqual(@as(usize, 1), try reader.range("signal", 10, 15, null));
        const aggregate = try reader.aggregatePrepared(handle, 10, 15);
        try std.testing.expectEqual(@as(u64, 1), aggregate.count);
        try std.testing.expectEqual(@as(f64, 2), aggregate.sum);
        if (codec == .raw) {
            const borrowed = try reader.borrowRawPage(handle, 10);
            try std.testing.expectEqualSlices(i64, &.{ 10, 20 }, borrowed.timestamps);
            try std.testing.expectEqualSlices(f64, &.{ 2, 3 }, borrowed.values);
        } else {
            try std.testing.expectError(error.PageNotRaw, reader.borrowRawPage(handle, 10));
        }
        var cursor = try reader.cursorPrepared(handle, -10, 20);
        try std.testing.expectEqual(@as(usize, 2), try reader.cursorNext(&cursor, &timestamps, &values));
        try std.testing.expectEqualSlices(i64, &.{ -10, 10 }, &timestamps);
        try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &values);
        try std.testing.expectEqual(@as(usize, 1), try reader.cursorNext(&cursor, &timestamps, &values));
        try std.testing.expectEqual(@as(i64, 20), timestamps[0]);
        try std.testing.expectEqual(@as(f64, 3), values[0]);
        try std.testing.expectEqual(@as(usize, 0), try reader.cursorNext(&cursor, &timestamps, &values));
        try std.testing.expect(!allocations.has_induced_failure);
    }
}

// Independent materialized reference: rank whole numeric lists, then inspect
// original queried connections. Never reuse the reducer or its event counters.
fn chartReference(
    allocator: std.mem.Allocator,
    points: []const Point,
    bounds: []const ChartBucketBounds,
    max_gap: ?u64,
    output: []ChartBucket,
) !void {
    const Observed = struct { point: Point, bucket: usize, component: usize };
    var observed: std.ArrayList(Observed) = .empty;
    defer observed.deinit(allocator);
    var component: usize = 0;
    for (bounds, 0..) |bound, bucket_index| {
        if (bucket_index > 0 and
            @as(i128, bound.start) != @as(i128, bounds[bucket_index - 1].end) + 1) component += 1;
        for (points) |point| if (point.timestamp >= bound.start and point.timestamp <= bound.end) {
            try observed.append(allocator, .{ .point = point, .bucket = bucket_index, .component = component });
        };
    }
    const numeric = try allocator.alloc(usize, observed.items.len);
    defer allocator.free(numeric);
    const Rank = struct {
        observed: []const Observed,
        descending: bool,
        fn lessThan(self: @This(), a: usize, b: usize) bool {
            const left = self.observed[a].point;
            const right = self.observed[b].point;
            if (left.value == right.value) return left.timestamp < right.timestamp;
            return if (self.descending) left.value > right.value else left.value < right.value;
        }
    };
    var offset: usize = 0;
    var previous_selected: ?usize = null;
    for (bounds, 0..) |_, bucket_index| {
        const begin = offset;
        while (offset < observed.items.len and observed.items[offset].bucket == bucket_index) offset += 1;
        var bucket = ChartBucket{};
        bucket.stored_count = @intCast(offset - begin);
        var numeric_count: usize = 0;
        for (begin..offset) |original_index| {
            const point = observed.items[original_index].point;
            if (chartReferenceNan(point.value)) {
                bucket.has_nan = true;
            } else {
                numeric[numeric_count] = original_index;
                numeric_count += 1;
            }
            if (max_gap) |limit| {
                if (original_index > begin and
                    @as(i128, point.timestamp) - @as(i128, observed.items[original_index - 1].point.timestamp) > limit)
                    bucket.has_internal_time_gap = true;
            }
        }
        bucket.numeric_count = @intCast(numeric_count);
        if (begin == offset) {
            output[bucket_index] = bucket;
            continue;
        }
        var role_indices: [4]?usize = .{ begin, null, null, offset - 1 };
        if (numeric_count != 0) {
            std.mem.sort(usize, numeric[0..numeric_count], Rank{ .observed = observed.items, .descending = false }, Rank.lessThan);
            role_indices[1] = numeric[0];
            std.mem.sort(usize, numeric[0..numeric_count], Rank{ .observed = observed.items, .descending = true }, Rank.lessThan);
            role_indices[2] = numeric[0];
        }
        // Whole identity set sorted independently of role order.
        var identities: [4]usize = undefined;
        var identity_count: usize = 0;
        for (role_indices) |maybe_index| if (maybe_index) |original_index| {
            identities[identity_count] = original_index;
            identity_count += 1;
        };
        std.mem.sort(usize, identities[0..identity_count], {}, std.sort.asc(usize));
        for (identities[0..identity_count], 0..) |original_index, sorted_index| {
            if (sorted_index > 0 and identities[sorted_index - 1] == original_index) continue;
            const point = observed.items[original_index].point;
            var breaks = ChartBreaks{};
            if (previous_selected) |previous| {
                const previous_bucket = observed.items[previous].bucket;
                if (previous_bucket < bucket_index) for (previous_bucket + 1..bucket_index) |between| {
                    if (output[between].stored_count == 0) breaks.empty_bucket = true;
                };
                breaks.excluded_interval = observed.items[previous].component != observed.items[original_index].component;
                for (previous..original_index + 1) |between| {
                    if (chartReferenceNan(observed.items[between].point.value)) breaks.nan = true;
                    if (max_gap) |limit| {
                        if (between > previous and
                            observed.items[between - 1].component == observed.items[between].component and
                            @as(i128, observed.items[between].point.timestamp) -
                                @as(i128, observed.items[between - 1].point.timestamp) > limit) breaks.time_gap = true;
                    }
                }
            } else {
                breaks.query_start = true;
                breaks.nan = chartReferenceNan(point.value);
            }
            bucket.samples[bucket.sample_count] = .{
                .point = point,
                .roles = .{
                    .first = role_indices[0] == original_index,
                    .minimum = role_indices[1] == original_index,
                    .maximum = role_indices[2] == original_index,
                    .last = role_indices[3] == original_index,
                },
                .break_before = breaks,
            };
            bucket.sample_count += 1;
            previous_selected = original_index;
        }
        output[bucket_index] = bucket;
    }
}

fn chartReferenceNan(value: f64) bool {
    const bits: u64 = @bitCast(value);
    return ((bits >> 52) & 2047) == 2047 and (bits & ((@as(u64, 1) << 52) - 1)) != 0;
}

fn expectChartBucket(expected: ChartBucket, actual: ChartBucket) !void {
    try std.testing.expectEqual(expected.stored_count, actual.stored_count);
    try std.testing.expectEqual(expected.numeric_count, actual.numeric_count);
    try std.testing.expectEqual(expected.sample_count, actual.sample_count);
    try std.testing.expectEqual(expected.has_nan, actual.has_nan);
    try std.testing.expectEqual(expected.has_internal_time_gap, actual.has_internal_time_gap);
    for (expected.samples[0..expected.sample_count], actual.samples[0..actual.sample_count]) |left, right| {
        try std.testing.expectEqual(left.point.timestamp, right.point.timestamp);
        try std.testing.expectEqual(@as(u64, @bitCast(left.point.value)), @as(u64, @bitCast(right.point.value)));
        try std.testing.expect(std.meta.eql(left.roles, right.roles));
        try std.testing.expect(std.meta.eql(left.break_before, right.break_before));
    }
}

fn chartSentinel() ChartBucket {
    return .{
        .stored_count = 123456,
        .numeric_count = 234567,
        .sample_count = 4,
        .has_nan = true,
        .has_internal_time_gap = true,
        .samples = [_]ChartSample{.{
            .point = .{ .timestamp = -345678, .value = @bitCast(@as(u64, 0xfff800000000abcd)) },
            .roles = .{ .maximum = true },
            .break_before = .{ .excluded_interval = true },
        }} ** 4,
    };
}

// Refuse and count every allocation/resize/remap attempt after open/prepare.
const ChartTestAllocator = struct {
    inner: std.mem.Allocator = std.testing.allocator,
    locked: bool = false,
    alloc_attempts: usize = 0,
    resize_attempts: usize = 0,
    remap_attempts: usize = 0,
    frees: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.alloc_attempts += 1;
        if (self.locked) return null;
        return self.inner.rawAlloc(len, alignment, return_address);
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.resize_attempts += 1;
        if (self.locked) return false;
        return self.inner.rawResize(bytes, alignment, len, return_address);
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, return_address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.remap_attempts += 1;
        if (self.locked) return null;
        return self.inner.rawRemap(bytes, alignment, len, return_address);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.inner.rawFree(bytes, alignment, return_address);
    }
};

const ChartTestIo = struct {
    offsets: [256]u64 = undefined,
    count: usize = 0,
    bytes: u64 = 0,
    revisits: usize = 0,
};

const ChartTestFile = struct {
    file: std.fs.File,
    io: *ChartTestIo,

    pub fn getEndPos(self: @This()) !u64 {
        return self.file.getEndPos();
    }
    pub fn preadAll(self: @This(), bytes: []u8, offset: u64) !usize {
        if (self.io.count == self.io.offsets.len) return error.ExcessiveChartReads;
        for (self.io.offsets[0..self.io.count]) |previous| if (previous == offset) {
            self.io.revisits += 1;
            break;
        };
        self.io.offsets[self.io.count] = offset;
        self.io.count += 1;
        self.io.bytes += bytes.len;
        return self.file.preadAll(bytes, offset);
    }
    pub fn close(self: @This()) void {
        self.file.close();
    }
};

// Literal expectations transcribed from frozen CT-006 materialized oracle.
// Fixture SHA256 de114d2e76567094f333f63e9cffb6193e6df086022e588e0b6b6e8c2ff5d732.
const ChartOracleFixture = struct { points: []const Point, bounds: []const ChartBucketBounds, max_gap: ?u64, expected: []const ChartBucket };
const chart_oracle_fixtures = [_]ChartOracleFixture{
    // omitted-interval-absent
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) } },
        .bounds = &.{ .{ .start = 0, .end = 0 }, .{ .start = 10, .end = 10 } },
        .max_gap = 6,
        .expected = &.{
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, undefined, undefined, undefined } },
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .excluded_interval = true } }, undefined, undefined, undefined } },
        },
    },
    // omitted-interval-bridge
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .{ .timestamp = 5, .value = @bitCast(@as(u64, 0x4058c00000000000)) }, .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) } },
        .bounds = &.{ .{ .start = 0, .end = 0 }, .{ .start = 10, .end = 10 } },
        .max_gap = 6,
        .expected = &.{
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, undefined, undefined, undefined } },
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .excluded_interval = true } }, undefined, undefined, undefined } },
        },
    },
    // omitted-interval-nan
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .{ .timestamp = 5, .value = @bitCast(@as(u64, 0x7ff0000000000011)) }, .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) } },
        .bounds = &.{ .{ .start = 0, .end = 0 }, .{ .start = 10, .end = 10 } },
        .max_gap = 6,
        .expected = &.{
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, undefined, undefined, undefined } },
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .excluded_interval = true } }, undefined, undefined, undefined } },
        },
    },
    // contiguous-empty-proven-gap
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) } },
        .bounds = &.{ .{ .start = 0, .end = 0 }, .{ .start = 1, .end = 9 }, .{ .start = 10, .end = 10 } },
        .max_gap = 9,
        .expected = &.{
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x3ff0000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, undefined, undefined, undefined } },
            .{ .stored_count = 0, .numeric_count = 0, .sample_count = 0, .has_nan = false, .has_internal_time_gap = false, .samples = .{ undefined, undefined, undefined, undefined } },
            .{ .stored_count = 1, .numeric_count = 1, .sample_count = 1, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4000000000000000)) }, .roles = .{ .first = true, .last = true, .maximum = true, .minimum = true }, .break_before = .{ .empty_bucket = true, .time_gap = true } }, undefined, undefined, undefined } },
        },
    },
    // dense-reduced-chord
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 1, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 2, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 3, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 4, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 5, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 6, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 7, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 8, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 9, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x0000000000000000)) } },
        .bounds = &.{.{ .start = 0, .end = 10 }},
        .max_gap = 1,
        .expected = &.{
            .{ .stored_count = 11, .numeric_count = 11, .sample_count = 2, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .roles = .{ .first = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, .{ .point = .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .roles = .{ .last = true }, .break_before = .{} }, undefined, undefined } },
        },
    },
    // full-i64-gap-18446744073709551615
    .{
        .points = &.{ .{ .timestamp = -9223372036854775808, .value = @bitCast(@as(u64, 0x8000000000000000)) }, .{ .timestamp = 9223372036854775807, .value = @bitCast(@as(u64, 0x7ff0000000000011)) } },
        .bounds = &.{.{ .start = -9223372036854775808, .end = 9223372036854775807 }},
        .max_gap = 18446744073709551615,
        .expected = &.{
            .{ .stored_count = 2, .numeric_count = 1, .sample_count = 2, .has_nan = true, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = -9223372036854775808, .value = @bitCast(@as(u64, 0x8000000000000000)) }, .roles = .{ .first = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, .{ .point = .{ .timestamp = 9223372036854775807, .value = @bitCast(@as(u64, 0x7ff0000000000011)) }, .roles = .{ .last = true }, .break_before = .{ .nan = true } }, undefined, undefined } },
        },
    },
    // full-i64-gap-18446744073709551614
    .{
        .points = &.{ .{ .timestamp = -9223372036854775808, .value = @bitCast(@as(u64, 0x8000000000000000)) }, .{ .timestamp = 9223372036854775807, .value = @bitCast(@as(u64, 0x7ff0000000000011)) } },
        .bounds = &.{.{ .start = -9223372036854775808, .end = 9223372036854775807 }},
        .max_gap = 18446744073709551614,
        .expected = &.{
            .{ .stored_count = 2, .numeric_count = 1, .sample_count = 2, .has_nan = true, .has_internal_time_gap = true, .samples = .{ .{ .point = .{ .timestamp = -9223372036854775808, .value = @bitCast(@as(u64, 0x8000000000000000)) }, .roles = .{ .first = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, .{ .point = .{ .timestamp = 9223372036854775807, .value = @bitCast(@as(u64, 0x7ff0000000000011)) }, .roles = .{ .last = true }, .break_before = .{ .nan = true, .time_gap = true } }, undefined, undefined } },
        },
    },
    // interior-spikes-nan-gap
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 1, .value = @bitCast(@as(u64, 0x4059000000000000)) }, .{ .timestamp = 2, .value = @bitCast(@as(u64, 0xfff8000000000456)) }, .{ .timestamp = 10, .value = @bitCast(@as(u64, 0x4014000000000000)) }, .{ .timestamp = 11, .value = @bitCast(@as(u64, 0xc059000000000000)) }, .{ .timestamp = 12, .value = @bitCast(@as(u64, 0x0000000000000000)) } },
        .bounds = &.{.{ .start = 0, .end = 12 }},
        .max_gap = 3,
        .expected = &.{
            .{ .stored_count = 6, .numeric_count = 5, .sample_count = 4, .has_nan = true, .has_internal_time_gap = true, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .roles = .{ .first = true }, .break_before = .{ .query_start = true } }, .{ .point = .{ .timestamp = 1, .value = @bitCast(@as(u64, 0x4059000000000000)) }, .roles = .{ .maximum = true }, .break_before = .{} }, .{ .point = .{ .timestamp = 11, .value = @bitCast(@as(u64, 0xc059000000000000)) }, .roles = .{ .minimum = true }, .break_before = .{ .nan = true, .time_gap = true } }, .{ .point = .{ .timestamp = 12, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .roles = .{ .last = true }, .break_before = .{} } } },
        },
    },
    // zero-nan-empty
    .{
        .points = &.{ .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x8000000000000000)) }, .{ .timestamp = 1, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .{ .timestamp = 2, .value = @bitCast(@as(u64, 0x7ff8000000000123)) }, .{ .timestamp = 3, .value = @bitCast(@as(u64, 0x7ff0000000000011)) } },
        .bounds = &.{ .{ .start = 0, .end = 1 }, .{ .start = 2, .end = 3 }, .{ .start = 4, .end = 4 } },
        .max_gap = null,
        .expected = &.{
            .{ .stored_count = 2, .numeric_count = 2, .sample_count = 2, .has_nan = false, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 0, .value = @bitCast(@as(u64, 0x8000000000000000)) }, .roles = .{ .first = true, .maximum = true, .minimum = true }, .break_before = .{ .query_start = true } }, .{ .point = .{ .timestamp = 1, .value = @bitCast(@as(u64, 0x0000000000000000)) }, .roles = .{ .last = true }, .break_before = .{} }, undefined, undefined } },
            .{ .stored_count = 2, .numeric_count = 0, .sample_count = 2, .has_nan = true, .has_internal_time_gap = false, .samples = .{ .{ .point = .{ .timestamp = 2, .value = @bitCast(@as(u64, 0x7ff8000000000123)) }, .roles = .{ .first = true }, .break_before = .{ .nan = true } }, .{ .point = .{ .timestamp = 3, .value = @bitCast(@as(u64, 0x7ff0000000000011)) }, .roles = .{ .last = true }, .break_before = .{ .nan = true } }, undefined, undefined } },
            .{ .stored_count = 0, .numeric_count = 0, .sample_count = 0, .has_nan = false, .has_internal_time_gap = false, .samples = .{ undefined, undefined, undefined, undefined } },
        },
    },
};

test "chart envelope independent oracle and 3906 exhaustive short histories" {
    for (chart_oracle_fixtures) |fixture| {
        var reference: [3]ChartBucket = undefined;
        try chartReference(std.testing.allocator, fixture.points, fixture.bounds, fixture.max_gap, reference[0..fixture.bounds.len]);
        for (fixture.expected, reference[0..fixture.bounds.len]) |expected, actual| try expectChartBucket(expected, actual);
    }
    const value_bits = [_]u64{ 0, 0x8000000000000000, 0x3ff0000000000000, 0xbff0000000000000, 0xfff0000000000011 };
    const geometries = [_][]const ChartBucketBounds{
        &.{.{ .start = -10, .end = 30 }},
        &.{ .{ .start = -10, .end = 0 }, .{ .start = 1, .end = 3 }, .{ .start = 4, .end = 30 } },
        &.{ .{ .start = -10, .end = 0 }, .{ .start = 8, .end = 30 } },
    };
    var histories: usize = 0;
    var combinations: usize = 1;
    for (0..6) |len| {
        if (len > 0) combinations *= value_bits.len;
        for (0..combinations) |encoding| {
            var points: [5]Point = undefined;
            var digits = encoding;
            for (points[0..len], 0..) |*point, point_index| {
                point.* = .{ .timestamp = @as(i64, @intCast(point_index)) * 4, .value = @bitCast(value_bits[digits % value_bits.len]) };
                digits /= value_bits.len;
            }
            for (geometries) |bounds| {
                for ([_]?u64{ null, 0, 4 }) |gap| {
                    var expected: [3]ChartBucket = undefined;
                    var actual: [3]ChartBucket = undefined;
                    try chartReference(std.testing.allocator, points[0..len], bounds, gap, expected[0..bounds.len]);
                    var reduction = ChartReduction{ .bounds = bounds, .output = actual[0..bounds.len], .max_gap = gap };
                    for (points[0..len]) |point| {
                        try reduction.advanceBefore(point.timestamp);
                        if (reduction.bucket_index == bounds.len) break;
                        if (point.timestamp >= bounds[reduction.bucket_index].start) try reduction.observe(point);
                    }
                    while (reduction.bucket_index < bounds.len) try reduction.finishBucket();
                    for (expected[0..bounds.len], actual[0..bounds.len]) |left, right| try expectChartBucket(left, right);
                }
            }
            histories += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3906), histories);
}

test "chart envelope frozen oracle mapped generic codecs bits and admission" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_]Codec{ .raw, .compressed }) |codec| {
        const filename = if (codec == .raw) "chart-raw.ctdb" else "chart-compressed.ctdb";
        var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile(filename, .{ .read = true }), codec);
        defer writer.abort();
        var names: [chart_oracle_fixtures.len][16]u8 = undefined;
        var name_slices: [chart_oracle_fixtures.len][]const u8 = undefined;
        for (chart_oracle_fixtures, 0..) |fixture, fixture_index| {
            name_slices[fixture_index] = try std.fmt.bufPrint(&names[fixture_index], "case-{d}", .{fixture_index});
            var timestamps: [16]i64 = undefined;
            var values: [16]f64 = undefined;
            for (fixture.points, 0..) |point, point_index| {
                timestamps[point_index] = point.timestamp;
                values[point_index] = point.value;
            }
            try writer.appendBatch(name_slices[fixture_index], timestamps[0..fixture.points.len], values[0..fixture.points.len]);
        }
        try writer.checkpoint(false);
        const path = try temporary.dir.realpathAlloc(std.testing.allocator, filename);
        defer std.testing.allocator.free(path);
        var allocation = ChartTestAllocator{};
        var mapped = try Reader.open(allocation.allocator(), path);
        defer mapped.close();
        var io = ChartTestIo{};
        var generic = try ReaderFor(ChartTestFile).openOn(allocation.allocator(), .{ .file = try temporary.dir.openFile(filename, .{}), .io = &io });
        defer generic.close();
        var handles: [chart_oracle_fixtures.len]SeriesHandle = undefined;
        for (name_slices, 0..) |name, fixture_index| handles[fixture_index] = try mapped.prepare(name);
        const before = allocation;
        allocation.locked = true;
        inline for (.{ &mapped, &generic }) |reader| {
            for (chart_oracle_fixtures, 0..) |fixture, fixture_index| {
                const handle = try reader.prepare(name_slices[fixture_index]);
                try std.testing.expectEqual(handles[fixture_index], handle);
                var output = [_]ChartBucket{chartSentinel()} ** 4;
                var work = ChartWork{};
                if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) io = .{};
                const short = try reader.envelopePreparedInternal(true, handle, fixture.bounds, fixture.max_gap, output[0 .. fixture.bounds.len - 1], &work);
                try std.testing.expectEqual(ChartProgress{ .required_buckets = fixture.bounds.len, .written_buckets = 0, .complete = false }, short);
                try std.testing.expect(std.meta.eql(work, ChartWork{}));
                for (output) |bucket| try expectChartBucket(chartSentinel(), bucket);
                if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) try std.testing.expectEqual(@as(usize, 0), io.count);
                const progress = try reader.envelopePreparedInto(handle, fixture.bounds, fixture.max_gap, &output);
                try std.testing.expectEqual(ChartProgress{ .required_buckets = fixture.bounds.len, .written_buckets = fixture.bounds.len, .complete = true }, progress);
                for (fixture.expected, output[0..fixture.bounds.len]) |expected, actual| try expectChartBucket(expected, actual);
                try expectChartBucket(chartSentinel(), output[fixture.bounds.len]);
                _ = try reader.envelopeInto(name_slices[fixture_index], fixture.bounds, fixture.max_gap, &output);
                for (fixture.expected, output[0..fixture.bounds.len]) |expected, actual| try expectChartBucket(expected, actual);
            }
            var output = [_]ChartBucket{chartSentinel()} ** 3;
            const handle = try reader.prepare(name_slices[0]);
            if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) io = .{};
            const invalid = [_][]const ChartBucketBounds{
                &.{.{ .start = 2, .end = 1 }},
                &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 3 } },
                &.{ .{ .start = 5, .end = 6 }, .{ .start = 0, .end = 1 } },
            };
            for (invalid) |bounds| {
                try std.testing.expectError(error.InvalidArguments, reader.envelopePreparedInto(handle, bounds, null, &.{}));
                try std.testing.expectError(error.InvalidArguments, reader.envelopePreparedInto(handle, bounds, null, &output));
                try std.testing.expectError(error.SeriesNotFound, reader.envelopeInto("missing", bounds, null, &output));
            }
            try std.testing.expectError(error.SeriesNotFound, reader.envelopeInto("missing", &.{}, null, &output));
            try std.testing.expectError(error.StaleSeriesHandle, reader.envelopePreparedInto(.{ .index = handle.index, .generation = handle.generation - 1 }, &.{}, null, &output));
            try std.testing.expectError(error.StaleSeriesHandle, reader.envelopePreparedInto(.{ .index = std.math.maxInt(u32), .generation = handle.generation }, invalid[0], null, &.{}));
            try std.testing.expectEqual(ChartProgress{ .required_buckets = 0, .written_buckets = 0, .complete = true }, try reader.envelopePreparedInto(handle, &.{}, null, &output));
            for (output) |bucket| try expectChartBucket(chartSentinel(), bucket);
            if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) try std.testing.expectEqual(@as(usize, 0), io.count);
        }
        try std.testing.expectEqual(before.alloc_attempts, allocation.alloc_attempts);
        try std.testing.expectEqual(before.resize_attempts, allocation.resize_attempts);
        try std.testing.expectEqual(before.remap_attempts, allocation.remap_attempts);
        try std.testing.expectEqual(before.frees, allocation.frees);
    }
}

test "chart envelope crosses restarts pages and index children in one scan" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const per_page = 131;
    const pages = index.entry_capacity + 3;
    var points: [pages * per_page]Point = undefined;
    var timestamps: [points.len]i64 = undefined;
    var values: [points.len]f64 = undefined;
    var timestamp: i64 = -20000;
    for (&points, &timestamps, &values, 0..) |*point, *stored_timestamp, *value, point_index| {
        timestamp += @intCast(2 + point_index % 11);
        stored_timestamp.* = timestamp;
        value.* = 20 + @as(f64, @floatFromInt(point_index % 100)) * 0.001;
        point.* = .{ .timestamp = timestamp, .value = value.* };
    }
    // Adjacent bounds spanning each restart and page; all original points enter.
    var bounds: [pages * 3]ChartBucketBounds = undefined;
    for (0..pages) |page_index| {
        const first = page_index * per_page;
        bounds[page_index * 3] = .{
            .start = if (page_index == 0) timestamps[first] else timestamps[first - 1] + 1,
            .end = timestamps[first + 126],
        };
        bounds[page_index * 3 + 1] = .{ .start = timestamps[first + 126] + 1, .end = timestamps[first + 128] };
        bounds[page_index * 3 + 2] = .{ .start = timestamps[first + 128] + 1, .end = timestamps[first + 130] };
    }
    var expected: [bounds.len]ChartBucket = undefined;
    try chartReference(std.testing.allocator, &points, &bounds, 7, &expected);
    for ([_]Codec{ .raw, .compressed }) |codec| {
        const filename = if (codec == .raw) "chart-boundary-raw.ctdb" else "chart-boundary-compressed.ctdb";
        var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile(filename, .{ .read = true }), codec);
        defer writer.abort();
        for (0..pages) |page_index| {
            const first = page_index * per_page;
            try writer.appendBatch("signal", timestamps[first..][0..per_page], values[first..][0..per_page]);
            try writer.checkpoint(false);
        }
        const path = try temporary.dir.realpathAlloc(std.testing.allocator, filename);
        defer std.testing.allocator.free(path);
        var allocation = ChartTestAllocator{};
        var mapped = try Reader.open(allocation.allocator(), path);
        defer mapped.close();
        var io = ChartTestIo{};
        var generic = try ReaderFor(ChartTestFile).openOn(allocation.allocator(), .{ .file = try temporary.dir.openFile(filename, .{}), .io = &io });
        defer generic.close();
        const handle = try mapped.prepare("signal");
        const root = try generic.loadNode(generic.series.items[handle.index].root);
        try std.testing.expectEqual(@as(u8, 1), root.level);
        try std.testing.expectEqual(@as(u16, 2), root.count);
        const codec_counts = try generic.codecCounts("signal");
        try std.testing.expectEqual(@as(usize, pages), codec_counts[if (codec == .raw) 0 else 1]);
        const leaf = try generic.loadNode(root.entries[0].pointer);
        var scratch: [format.page_size]u8 = undefined;
        const first_page = try generic.loadPage(leaf.entries[0].pointer, &scratch);
        try std.testing.expectEqual(@as(u32, per_page), first_page.statistics.count);
        if (codec == .compressed) {
            try std.testing.expectEqual(page.TimestampCodec.delta_varint, first_page.timestamp_codec);
            try std.testing.expectEqual(page.ValueCodec.xor_varint, first_page.value_codec);
        }
        const before = allocation;
        allocation.locked = true;
        inline for (.{ &mapped, &generic }) |reader| {
            var output: [bounds.len]ChartBucket = undefined;
            for (0..2) |pass| {
                io = .{};
                var work = ChartWork{};
                _ = try reader.envelopePreparedInternal(true, try reader.prepare("signal"), &bounds, 7, &output, &work);
                for (expected, output) |left, right| try expectChartBucket(left, right);
                std.debug.print("CT-012 boundary codec={s} storage={s} pass={d} index_visits={d} page_loads={d} auth_bytes={d} validation_records={d} selection_records={d} emitted_points={d} generic_revisits={d}\n", .{
                    @tagName(codec),         if (comptime @TypeOf(reader.*) == Reader) "mapped" else "generic", pass,
                    work.index_visits,       work.page_loads,                                                   work.authenticated_bytes,
                    work.validation_records, work.selection_records,                                            work.emitted_points,
                    io.revisits,
                });
                try std.testing.expectEqual(@as(u64, pages), work.page_loads);
                try std.testing.expectEqual(@as(u64, 3), work.index_visits);
                try std.testing.expectEqual(@as(u64, points.len), work.selection_records);
                try std.testing.expect(work.emitted_points <= bounds.len * 4);
                if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) {
                    try std.testing.expectEqual(@as(usize, 0), io.revisits);
                    try std.testing.expectEqual(work.page_loads + work.index_visits, io.count);
                    try std.testing.expectEqual(work.authenticated_bytes, io.bytes);
                    try std.testing.expectEqual(@as(u64, points.len), work.validation_records);
                } else if (pass == 0) {
                    try std.testing.expectEqual(@as(u64, points.len), work.validation_records);
                } else {
                    // Cache capacity is geometry bounded; count actual revalidation.
                    try std.testing.expect(work.validation_records <= points.len);
                }
            }
            io = .{};
            _ = try reader.envelopeInto("signal", &bounds, 7, &output);
            for (expected, output) |left, right| try expectChartBucket(left, right);
            if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) {
                try std.testing.expectEqual(@as(usize, pages + 3), io.count);
                try std.testing.expectEqual(@as(usize, 0), io.revisits);
            }
            // Timestamp-disjoint pruning: one page, not every page in history.
            const first = [_]ChartBucketBounds{.{ .start = timestamps[127], .end = timestamps[129] }};
            var output_first: [1]ChartBucket = undefined;
            var expected_first: [1]ChartBucket = undefined;
            try chartReference(std.testing.allocator, &points, &first, null, &expected_first);
            io = .{};
            var work = ChartWork{};
            _ = try reader.envelopePreparedInternal(true, try reader.prepare("signal"), &first, null, &output_first, &work);
            try expectChartBucket(expected_first[0], output_first[0]);
            try std.testing.expectEqual(@as(u64, 1), work.page_loads);
            try std.testing.expectEqual(@as(u64, 2), work.index_visits);
            try std.testing.expect(work.selection_records <= per_page);
            if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) try std.testing.expectEqual(@as(usize, 0), io.revisits);
        }
        try std.testing.expectEqual(before.alloc_attempts, allocation.alloc_attempts);
        try std.testing.expectEqual(before.resize_attempts, allocation.resize_attempts);
        try std.testing.expectEqual(before.remap_attempts, allocation.remap_attempts);
        try std.testing.expectEqual(before.frees, allocation.frees);
    }
}

test "chart envelope 1200 buckets preserves product oracle exceptional values" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const offsets = [_]i64{ 0, 1, 2, 3, 4, 12, 13, 14, 15, 19 };
    const bits = [_]u64{ 0, 0x408f400000000000, 0xc08f400000000000, 0x8000000000000000, 1, 0x8000000000000001, 0x7ff8000000000123, 0xfff0000000000000, 0x7ff0000000000000, 0x7ff0000000000011 };
    var points: [12000]Point = undefined;
    var timestamps: [points.len]i64 = undefined;
    var values: [points.len]f64 = undefined;
    var bounds: [1200]ChartBucketBounds = undefined;
    for (&bounds, 0..) |*bound, bucket_index| {
        const start: i64 = @as(i64, @intCast(bucket_index)) * 20;
        for (offsets, bits, 0..) |offset, value_bits, within| {
            const original_index = bucket_index * offsets.len + within;
            points[original_index] = .{ .timestamp = start + offset, .value = @bitCast(value_bits) };
            timestamps[original_index] = start + offset;
            values[original_index] = @bitCast(value_bits);
        }
        bound.* = if (bucket_index % 13 == 0)
            .{ .start = start + 5, .end = start + 10 }
        else if (bucket_index % 17 == 0)
            .{ .start = start + 1, .end = start + 19 }
        else
            .{ .start = start, .end = start + 19 };
    }
    var expected: [bounds.len]ChartBucket = undefined;
    try chartReference(std.testing.allocator, &points, &bounds, 6, &expected);
    var emitted: u64 = 0;
    for (expected) |bucket| emitted += bucket.sample_count;
    // Pinned independent Python product fixture: exact selected identity count.
    try std.testing.expectEqual(@as(u64, 4428), emitted);
    for ([_]Codec{ .raw, .compressed }) |codec| {
        const filename = if (codec == .raw) "chart-product-raw.ctdb" else "chart-product-compressed.ctdb";
        var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile(filename, .{ .read = true }), codec);
        defer writer.abort();
        try writer.appendBatch("signal", &timestamps, &values);
        try writer.checkpoint(false);
        const path = try temporary.dir.realpathAlloc(std.testing.allocator, filename);
        defer std.testing.allocator.free(path);
        var allocation = ChartTestAllocator{};
        var mapped = try Reader.open(allocation.allocator(), path);
        defer mapped.close();
        var io = ChartTestIo{};
        var generic = try ReaderFor(ChartTestFile).openOn(allocation.allocator(), .{ .file = try temporary.dir.openFile(filename, .{}), .io = &io });
        defer generic.close();
        const before = allocation;
        allocation.locked = true;
        inline for (.{ &mapped, &generic }) |reader| {
            var output: [bounds.len]ChartBucket = undefined;
            for (0..2) |pass| {
                var work = ChartWork{};
                io = .{};
                const progress = try reader.envelopePreparedInternal(true, try reader.prepare("signal"), &bounds, 6, &output, &work);
                try std.testing.expectEqual(ChartProgress{ .required_buckets = 1200, .written_buckets = 1200, .complete = true }, progress);
                for (expected, output) |left, right| try expectChartBucket(left, right);
                std.debug.print("CT-012 product codec={s} storage={s} pass={d} index_visits={d} page_loads={d} auth_bytes={d} validation_records={d} selection_records={d} emitted_points={d} generic_revisits={d}\n", .{
                    @tagName(codec),         if (comptime @TypeOf(reader.*) == Reader) "mapped" else "generic", pass,
                    work.index_visits,       work.page_loads,                                                   work.authenticated_bytes,
                    work.validation_records, work.selection_records,                                            work.emitted_points,
                    io.revisits,
                });
                try std.testing.expectEqual(emitted, work.emitted_points);
                try std.testing.expectEqual(@as(u64, points.len), work.selection_records);
                try std.testing.expect(work.page_loads < 1200);
                if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) {
                    try std.testing.expectEqual(@as(usize, 0), io.revisits);
                    try std.testing.expectEqual(work.authenticated_bytes, io.bytes);
                    try std.testing.expectEqual(@as(u64, points.len), work.validation_records);
                }
            }
            io = .{};
            _ = try reader.envelopeInto("signal", &bounds, 6, &output);
            if (comptime @TypeOf(reader.*) == ReaderFor(ChartTestFile)) try std.testing.expectEqual(@as(usize, 0), io.revisits);
            for (expected, output) |left, right| try expectChartBucket(left, right);
        }
        try std.testing.expectEqual(before.alloc_attempts, allocation.alloc_attempts);
        try std.testing.expectEqual(before.resize_attempts, allocation.resize_attempts);
        try std.testing.expectEqual(before.remap_attempts, allocation.remap_attempts);
        try std.testing.expectEqual(before.frees, allocation.frees);
    }
}

test "chart envelope unaligned byte selection and generic warm authentication" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_]Codec{ .raw, .compressed }) |codec| {
        const filename = if (codec == .raw) "chart-unaligned-raw.ctdb" else "chart-unaligned-compressed.ctdb";
        var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile(filename, .{ .read = true }), codec);
        defer writer.abort();
        const timestamps = [_]i64{ -10, 0, 10 };
        const values = [_]f64{ -0.0, @bitCast(@as(u64, 0xfff0000000000005)), 1.5 };
        const points = [_]Point{ .{ .timestamp = -10, .value = values[0] }, .{ .timestamp = 0, .value = values[1] }, .{ .timestamp = 10, .value = values[2] } };
        try writer.appendBatch("signal", &timestamps, &values);
        try writer.checkpoint(false);
        var io = ChartTestIo{};
        var reader = try ReaderFor(ChartTestFile).openOn(std.testing.allocator, .{ .file = try temporary.dir.openFile(filename, .{}), .io = &io });
        defer reader.close();
        const handle = try reader.prepare("signal");
        const series_entry = &reader.series.items[handle.index];
        var node = try reader.loadNode(series_entry.root);
        const pointer = node.entries[0].pointer;
        var bytes: [format.page_size + 8]u8 align(8) = undefined;
        const scratch: *[format.page_size]u8 = @ptrCast(bytes[1..][0..format.page_size].ptr);
        const view = try reader.loadPage(pointer, scratch);
        try std.testing.expect(@intFromPtr(view.bytes.ptr) % 8 != 0);
        try std.testing.expect(view.rawTimestamps() == null);
        try std.testing.expect(view.rawValues() == null);
        const bounds = [_]ChartBucketBounds{ .{ .start = -10, .end = -1 }, .{ .start = 0, .end = 0 }, .{ .start = 1, .end = 10 } };
        var expected: [3]ChartBucket = undefined;
        var actual: [3]ChartBucket = undefined;
        try chartReference(std.testing.allocator, &points, &bounds, 9, &expected);
        var reduction = ChartReduction{ .bounds = &bounds, .output = &actual, .max_gap = 9 };
        try chartSelectPage(view, &reduction, false, {});
        while (reduction.bucket_index < bounds.len) try reduction.finishBucket();
        for (expected, actual) |left, right| try expectChartBucket(left, right);
        _ = try reader.envelopePreparedInto(handle, &bounds, 9, &actual);
        for (expected, actual) |left, right| try expectChartBucket(left, right);
        const mutable = try temporary.dir.openFile(filename, .{ .mode = .read_write });
        defer mutable.close();
        const corrupted = [_]u8{view.bytes[format.page_header_size] ^ 1};
        try mutable.pwriteAll(&corrupted, pointer.offset + format.page_header_size);
        io = .{};
        try std.testing.expect(!(try reader.envelopePreparedInto(handle, &bounds, 9, &.{})).complete);
        try std.testing.expectEqual(@as(usize, 0), io.count);
        try std.testing.expectError(error.ChecksumMismatch, reader.envelopePreparedInto(handle, &bounds, 9, &actual));
        try mutable.pwriteAll(view.bytes, pointer.offset);
        _ = try reader.envelopePreparedInto(handle, &bounds, 9, &actual);
        // Re-signed bytes still require the current manifest series edge.
        node.series_id += 1;
        var encoded: [format.index_node_size]u8 = undefined;
        try index.encode(&node, &encoded);
        try mutable.pwriteAll(&encoded, series_entry.root.offset);
        series_entry.root.identity = checksum.calculate(&encoded);
        const empty_bound = [_]ChartBucketBounds{.{ .start = 100, .end = 101 }};
        try std.testing.expectError(error.InvalidDatabase, reader.envelopePreparedInto(handle, &empty_bound, null, actual[0..1]));
    }
}

test "chart envelope validates immutable cached parent edges and matching control" {
    for ([_]Codec{ .raw, .compressed }) |codec| {
        for ([_]bool{ true, false }) |conflicting| {
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            try writeCachedPageEdgeFixture(temporary.dir, codec, conflicting);
            var allocation = ChartTestAllocator{};
            var mapped = try openCachedPageEdgeFixture(temporary.dir, allocation.allocator());
            defer mapped.close();
            var io = ChartTestIo{};
            var generic = try ReaderFor(ChartTestFile).openOn(allocation.allocator(), .{ .file = try temporary.dir.openFile("cached-edge.ctdb", .{}), .io = &io });
            defer generic.close();
            const bounds = [_]ChartBucketBounds{ .{ .start = -10, .end = -10 }, .{ .start = 10, .end = 15 } };
            const before = allocation;
            allocation.locked = true;
            inline for (.{ &mapped, &generic }) |reader| {
                const handle = try reader.prepare("signal");
                var output: [2]ChartBucket = undefined;
                if (conflicting) {
                    // Cold conflicting edge and a prior API-warmed cache hit.
                    try std.testing.expectError(error.InvalidDatabase, reader.envelopePreparedInto(handle, bounds[1..], null, output[0..1]));
                    if (comptime @TypeOf(reader.*) == Reader) try warmCachedPageEdge(reader, handle);
                    try std.testing.expectError(error.InvalidDatabase, reader.envelopePreparedInto(handle, &bounds, null, &output));
                    _ = try reader.envelopePreparedInto(handle, bounds[0..1], null, output[0..1]);
                    try std.testing.expectEqual(@as(i64, -10), output[0].samples[0].point.timestamp);
                } else {
                    for (0..2) |_| {
                        var work = ChartWork{};
                        _ = try reader.envelopePreparedInternal(true, handle, &bounds, null, &output, &work);
                        try std.testing.expectEqual(@as(u64, 2), work.page_loads);
                        try std.testing.expectEqual(@as(u64, 1), output[0].stored_count);
                        try std.testing.expectEqual(@as(u64, 1), output[1].stored_count);
                        try std.testing.expectEqual(@as(i64, -10), output[0].samples[0].point.timestamp);
                        try std.testing.expectEqual(@as(i64, 10), output[1].samples[0].point.timestamp);
                        try std.testing.expect(output[1].samples[0].break_before.excluded_interval);
                    }
                }
            }
            try std.testing.expectEqual(before.alloc_attempts, allocation.alloc_attempts);
            try std.testing.expectEqual(before.resize_attempts, allocation.resize_attempts);
            try std.testing.expectEqual(before.remap_attempts, allocation.remap_attempts);
            try std.testing.expectEqual(before.frees, allocation.frees);
        }
    }
}

test "chart envelope refresh stale handles and copied result lifetime" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var writer = try Appender.createOn(std.testing.allocator, try temporary.dir.createFile("chart-refresh.ctdb", .{ .read = true }), .compressed);
    defer writer.abort();
    try writer.append("signal", 10, -0.0);
    try writer.checkpoint(false);
    const path = try temporary.dir.realpathAlloc(std.testing.allocator, "chart-refresh.ctdb");
    defer std.testing.allocator.free(path);
    var mapped = try Reader.open(std.testing.allocator, path);
    var io = ChartTestIo{};
    var generic = try ReaderFor(ChartTestFile).openOn(std.testing.allocator, .{ .file = try temporary.dir.openFile("chart-refresh.ctdb", .{}), .io = &io });
    const mapped_handle = try mapped.prepare("signal");
    const generic_handle = try generic.prepare("signal");
    const bounds = [_]ChartBucketBounds{.{ .start = 10, .end = 20 }};
    var copied: [1]ChartBucket = undefined;
    _ = try mapped.envelopePreparedInto(mapped_handle, &bounds, null, &copied);
    try std.testing.expect(!try mapped.refresh());
    try std.testing.expect(!try generic.refresh());
    try writer.append("signal", 20, 2);
    try writer.checkpoint(false);
    inline for (.{ &mapped, &generic }, .{ mapped_handle, generic_handle }) |reader, old_handle| {
        var output: [1]ChartBucket = undefined;
        _ = try reader.envelopePreparedInto(old_handle, &bounds, null, &output);
        try std.testing.expectEqual(@as(u64, 1), output[0].stored_count);
        try std.testing.expect(try reader.refresh());
        try std.testing.expectError(error.StaleSeriesHandle, reader.envelopePreparedInto(old_handle, &.{}, null, &output));
        try std.testing.expectError(error.StaleSeriesHandle, reader.envelopePreparedInto(old_handle, &bounds, null, &.{}));
        _ = try reader.envelopeInto("signal", &bounds, 10, &output);
        try std.testing.expectEqual(@as(u64, 2), output[0].stored_count);
        try std.testing.expect(!output[0].has_internal_time_gap);
        reader.close();
    }
    try std.testing.expectEqual(@as(u64, 1), copied[0].stored_count);
    try std.testing.expectEqual(@as(u8, 1), copied[0].sample_count);
    try std.testing.expectEqual(@as(i64, 10), copied[0].samples[0].point.timestamp);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(copied[0].samples[0].point.value)));
}

// Every fixture is fully on disk and immutable before either reader opens.
const ChartBadEdge = enum { page_series, child_series, child_summary, child_level };
fn writeChartBadEdgeFixture(directory: std.fs.Dir, codec: Codec, fault: ChartBadEdge) !u64 {
    {
        var writer = try Appender.createOn(std.testing.allocator, try directory.createFile("chart-bad-edge.ctdb", .{ .read = true }), codec);
        var opened = true;
        defer if (opened) writer.abort();
        for (0..index.entry_capacity + 1) |page_index| {
            const start: i64 = @intCast(page_index * 10);
            try writer.appendBatch("signal", &.{ start, start + 1, start + 2 }, &.{ 1, 2, 3 });
            try writer.checkpoint(false);
        }
        try writer.close();
        opened = false;
    }
    const file = try directory.openFile("chart-bad-edge.ctdb", .{ .mode = .read_write });
    defer file.close();
    const physical_size = try file.getEndPos();
    var snapshot = (try loadSnapshot(std.testing.allocator, file, physical_size)) orelse return error.MissingFixtureSnapshot;
    defer snapshot.deinit(std.testing.allocator);
    const series = &snapshot.catalog.series.items[0];
    var root_bytes: [format.index_node_size]u8 = undefined;
    try std.testing.expectEqual(root_bytes.len, try file.preadAll(&root_bytes, series.root.offset));
    var root_node = try index.decode(&root_bytes, series.root, snapshot.root.committed_size);
    try std.testing.expectEqual(@as(u8, 1), root_node.level);
    const first_child = &root_node.entries[0];
    switch (fault) {
        .child_level => root_node.level = 2,
        .child_summary => first_child.summary.value_sum += 1,
        .child_series, .page_series => {
            var child_bytes: [format.index_node_size]u8 = undefined;
            try std.testing.expectEqual(child_bytes.len, try file.preadAll(&child_bytes, first_child.pointer.offset));
            var child = try index.decode(&child_bytes, first_child.pointer, snapshot.root.committed_size);
            if (fault == .child_series) {
                child.series_id += 1;
            } else {
                var data: [format.page_size]u8 = undefined;
                const first_page = &child.entries[0];
                const size: usize = first_page.pointer.size;
                try std.testing.expectEqual(size, try file.preadAll(data[0..size], first_page.pointer.offset));
                _ = try page.decode(data[0..size], first_page.pointer.identity);
                std.mem.writeInt(u32, data[8..12], series.id + 1, .little);
                first_page.pointer.identity = checksum.calculate(data[0..size]);
                _ = try page.decode(data[0..size], first_page.pointer.identity);
                try file.pwriteAll(data[0..size], first_page.pointer.offset);
            }
            try index.encode(&child, &child_bytes);
            first_child.pointer.identity = checksum.calculate(&child_bytes);
            _ = try index.decode(&child_bytes, first_child.pointer, snapshot.root.committed_size);
            try file.pwriteAll(&child_bytes, first_child.pointer.offset);
        },
    }
    try index.encode(&root_node, &root_bytes);
    series.root.identity = checksum.calculate(&root_bytes);
    series.summary = root_node.summary;
    _ = try index.decode(&root_bytes, series.root, snapshot.root.committed_size);
    try file.pwriteAll(&root_bytes, series.root.offset);
    var manifest_bytes: std.ArrayList(u8) = .empty;
    defer manifest_bytes.deinit(std.testing.allocator);
    var manifest_pointer = try manifest.encode(&manifest_bytes, std.testing.allocator, snapshot.root.generation, snapshot.catalog.series.items);
    try std.testing.expectEqual(snapshot.root.manifest.size, manifest_pointer.size);
    manifest_pointer.offset = snapshot.root.manifest.offset;
    try file.pwriteAll(manifest_bytes.items, manifest_pointer.offset);
    const control = try validateControl(file, physical_size);
    const candidates = collectRoots(&control, physical_size);
    const root = format.Root{
        .generation = snapshot.root.generation,
        .committed_size = snapshot.root.committed_size,
        .manifest = manifest_pointer,
        .previous_identity = snapshot.root.previous_identity,
    };
    var encoded_root: [format.root_slot_size]u8 = undefined;
    root.encode(&encoded_root);
    var replaced = false;
    for (candidates, 0..) |candidate, slot| {
        if (candidate) |value| {
            if (!checksum.equal(value.identity, snapshot.root_identity)) continue;
            try std.testing.expect(rootHasValidPredecessor(&candidates, value));
            try file.pwriteAll(&encoded_root, try format.rootSlotOffset(slot));
            replaced = true;
        }
    }
    try std.testing.expect(replaced);
    return root.generation;
}

test "chart envelope rejects authenticated child level summary and series edges" {
    for ([_]Codec{ .raw, .compressed }) |codec| {
        for (std.enums.values(ChartBadEdge)) |fault| {
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            const generation = try writeChartBadEdgeFixture(temporary.dir, codec, fault);
            const path = try temporary.dir.realpathAlloc(std.testing.allocator, "chart-bad-edge.ctdb");
            defer std.testing.allocator.free(path);
            var mapped = try Reader.open(std.testing.allocator, path);
            defer mapped.close();
            var io = ChartTestIo{};
            var generic = try ReaderFor(ChartTestFile).openOn(std.testing.allocator, .{ .file = try temporary.dir.openFile("chart-bad-edge.ctdb", .{}), .io = &io });
            defer generic.close();
            const bounds = [_]ChartBucketBounds{.{ .start = 0, .end = 2 }};
            var output: [1]ChartBucket = undefined;
            inline for (.{ &mapped, &generic }) |reader| {
                // Newest fully re-signed snapshot, not accidental root fallback.
                try std.testing.expectEqual(generation, reader.generation);
                const handle = try reader.prepare("signal");
                for (0..2) |_| try std.testing.expectError(error.InvalidDatabase, reader.envelopePreparedInto(handle, &bounds, null, &output));
            }
        }
    }
}
