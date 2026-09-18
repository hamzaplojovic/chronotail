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
                if (pointerEqual(cached.pointer, entry.pointer)) return cached.view;
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
