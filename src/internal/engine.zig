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
    if (physical_size >= format.file_header.len) {
        var found: [format.file_header.len]u8 = undefined;
        if (try file.preadAll(&found, 0) != found.len) return error.InvalidDatabase;
        if (std.mem.eql(u8, &found, "CTDB\x06")) return error.FormatV6RequiresMigration;
    }
    if (physical_size < format.control_size) return error.InvalidDatabase;
    var control: [format.control_size]u8 = undefined;
    if (try file.preadAll(&control, 0) != control.len) return error.InvalidDatabase;
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
    if (size > 256 * 1024 * 1024) return error.InvalidDatabase;
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
    var attempts: usize = 0;
    while (attempts < format.root_slot_count) : (attempts += 1) {
        var best_slot: ?usize = null;
        for (candidates, 0..) |candidate, slot| if (candidate) |value| {
            if (best_slot == null or
                value.root.generation > candidates[best_slot.?].?.root.generation)
            {
                best_slot = slot;
            }
        };
        const slot = best_slot orelse return error.InvalidDatabase;
        const candidate = candidates[slot].?;
        if (!rootHasValidPredecessor(&candidates, candidate)) {
            candidates[slot] = null;
            continue;
        }
        const catalog = loadManifestForRoot(allocator, file, candidate) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                candidates[slot] = null;
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
        if (directory.contains(entry.name)) return error.InvalidDatabase;
        directory.putAssumeCapacityNoClobber(entry.name, @intCast(series_index));
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
    pending_count: usize = 0,
    pending_entries: std.ArrayList(index.Entry) = .empty,
    last_timestamp: ?i64 = null,

    fn init(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        root: ?format.Pointer,
        summary: ?index.Summary,
    ) !WriterSeries {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const timestamps = try allocator.alloc(i64, page.records_max);
        errdefer allocator.free(timestamps);
        const values = try allocator.alloc(f64, page.records_max);
        return .{
            .id = id,
            .name = owned_name,
            .root = root,
            .summary = summary,
            .timestamps = timestamps,
            .values = values,
            .last_timestamp = if (summary) |value| value.timestamp_max else null,
        };
    }

    fn deinit(self: *WriterSeries, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.timestamps);
        allocator.free(self.values);
        self.pending_entries.deinit(allocator);
    }
};

pub fn AppenderFor(comptime File: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        file: File,
        series: std.ArrayList(WriterSeries) = .empty,
        series_directory: SeriesDirectory = .empty,
        manifest_scratch: std.ArrayList(u8) = .empty,
        manifest_series_scratch: std.ArrayList(manifest.Series) = .empty,
        write_offset: u64,
        generation: u64 = 0,
        previous_root_identity: checksum.Identity = checksum.zero,
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
                try self.series.ensureTotalCapacity(allocator, snapshot.catalog.series.items.len);
                try self.series_directory.ensureUnusedCapacity(
                    allocator,
                    @intCast(snapshot.catalog.series.items.len),
                );
                for (snapshot.catalog.series.items) |entry| {
                    const writer_series = try WriterSeries.init(
                        allocator,
                        entry.id,
                        entry.name,
                        entry.root,
                        entry.summary,
                    );
                    self.series.appendAssumeCapacity(writer_series);
                    const series_index = self.series.items.len - 1;
                    self.series_directory.putAssumeCapacityNoClobber(
                        self.series.items[series_index].name,
                        @intCast(series_index),
                    );
                }
                self.generation = snapshot.root.generation;
                self.previous_root_identity = snapshot.root_identity;
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

            const target = existing orelse try self.getOrCreateSeries(name);
            errdefer self.poisoned = true;
            var consumed: usize = 0;
            while (consumed < timestamps.len) {
                if (target.pending_count == page.records_max) try self.flushSeries(target);
                const amount = @min(
                    page.records_max - target.pending_count,
                    timestamps.len - consumed,
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
            for (self.series.items) |*entry| try self.flushSeries(entry);

            self.manifest_series_scratch.clearRetainingCapacity();
            try self.manifest_series_scratch.ensureTotalCapacity(
                self.allocator,
                self.series.items.len,
            );
            for (self.series.items) |*entry| {
                if (entry.pending_entries.items.len > 0) {
                    entry.candidate_root = try index.append(
                        self.file,
                        self.allocator,
                        &self.write_offset,
                        entry.id,
                        entry.root,
                        entry.pending_entries.items,
                    );
                    entry.candidate_summary = try readIndexSummary(
                        self.file,
                        entry.candidate_root.?,
                    );
                } else {
                    entry.candidate_root = entry.root;
                    entry.candidate_summary = entry.summary;
                }
                self.manifest_series_scratch.appendAssumeCapacity(.{
                    .id = entry.id,
                    .name = entry.name,
                    .root = entry.candidate_root orelse return error.InvalidDatabase,
                    .summary = entry.candidate_summary orelse return error.InvalidDatabase,
                });
            }

            const next_generation = std.math.add(u64, self.generation, 1) catch
                return error.DatabaseTooLarge;
            var manifest_pointer = try manifest.encode(
                &self.manifest_scratch,
                self.allocator,
                next_generation,
                self.manifest_series_scratch.items,
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
            self.previous_root_identity = format.Root.identity(&encoded_root);
            for (self.series.items) |*entry| {
                entry.root = entry.candidate_root;
                entry.summary = entry.candidate_summary;
                entry.candidate_root = null;
                entry.candidate_summary = null;
                entry.pending_entries.clearRetainingCapacity();
            }
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
            var encoded_bytes: [format.page_size]u8 = undefined;
            const encoded = try page.encodeWithOptions(
                &encoded_bytes,
                entry.id,
                entry.timestamps[0..entry.pending_count],
                entry.values[0..entry.pending_count],
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
            entry.pending_count = 0;
        }

        fn getOrCreateSeries(self: *Self, name: []const u8) !*WriterSeries {
            if (self.findSeries(name)) |entry| return entry;
            if (self.series.items.len == std.math.maxInt(u32))
                return error.DatabaseTooLarge;
            try self.series.ensureUnusedCapacity(self.allocator, 1);
            try self.series_directory.ensureUnusedCapacity(self.allocator, 1);
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
            return &self.series.items[series_index];
        }

        fn findSeries(self: *Self, name: []const u8) ?*WriterSeries {
            const series_index = self.series_directory.get(name) orelse return null;
            return &self.series.items[series_index];
        }

        fn deinitMemory(self: *Self) void {
            for (self.series.items) |*entry| entry.deinit(self.allocator);
            self.series.deinit(self.allocator);
            self.series_directory.deinit(self.allocator);
            self.manifest_scratch.deinit(self.allocator);
            self.manifest_series_scratch.deinit(self.allocator);
        }
    };
}

pub const Appender = AppenderFor(std.fs.File);

fn readIndexSummary(file: anytype, pointer: format.Pointer) !index.Summary {
    var bytes: [format.index_node_size]u8 = undefined;
    if (try file.preadAll(&bytes, pointer.offset) != bytes.len) return error.InvalidDatabase;
    const node = index.decode(&bytes, pointer, try file.getEndPos()) catch |err| switch (err) {
        error.ChecksumMismatch => return err,
        else => return error.InvalidDatabase,
    };
    return node.summary;
}

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
const SeriesRuntime = struct {
    root: ?index.View = null,
    single_page: ?index.Entry = null,
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
            if (physical_size == self.observed_file_size) return false;
            const control = try validateControl(self.file, physical_size);
            const candidates = collectRoots(&control, physical_size);
            const newest = newestRoot(&candidates);
            if (newest == null or newest.?.root.generation <= self.generation) {
                return false;
            }

            var loaded = (try loadSnapshot(self.allocator, self.file, physical_size)) orelse {
                self.observed_file_size = physical_size;
                return false;
            };
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
            for (self.series.items) |entry| entry.deinit(self.allocator);
            self.series.deinit(self.allocator);
            self.series_runtime.deinit(self.allocator);
            self.series = loaded.catalog.series;
            loaded.catalog.series = .empty;
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
            const entry = self.findSeries(name) orelse return error.SeriesNotFound;
            return entry.summary.timestamp_max;
        }

        pub fn codecCounts(self: *Self, name: []const u8) ![2]usize {
            const handle = try self.prepare(name);
            var counts = [_]usize{ 0, 0 };
            try self.walkPages(handle, struct {
                fn visit(reader: *Self, pointer: format.Pointer, _: index.Summary, state: *[2]usize) !void {
                    var scratch: [format.page_size]u8 = undefined;
                    const view = try reader.loadPage(pointer, &scratch);
                    state[if (view.timestamp_codec == .raw and view.value_codec == .raw) 0 else 1] += 1;
                }
            }.visit, &counts);
            return counts;
        }

        pub fn range(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            output: ?std.fs.File,
        ) !usize {
            const handle = try self.prepare(name);
            return self.rangePreparedInternal(handle, start, end, output, null, null);
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
            var buffers = RangeBuffers{ .timestamps = timestamps, .values = values };
            return self.rangePreparedInternal(handle, start, end, null, &buffers, null);
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
            _ = try self.resolve(cursor_state.series);
            if (cursor_state.complete) return 0;
            if (comptime File == std.fs.File) if (self.mapping != null) {
                return self.cursorNextMapped(cursor_state, timestamps, values);
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
            cursor_state: *Cursor,
            timestamps: []i64,
            values: []f64,
        ) !usize {
            const series_entry = try self.resolve(cursor_state.series);
            if (!cursor_state.initialized) {
                const runtime = &self.series_runtime.items[cursor_state.series.index];
                const root = runtime.root orelse blk: {
                    const loaded = try self.loadMappedIndex(series_entry.root);
                    runtime.root = loaded;
                    break :blk loaded;
                };
                if (root.series_id != series_entry.id or
                    !summaryEqual(root.summary, series_entry.summary))
                    return error.InvalidDatabase;
                cursor_state.frames[0] = .{
                    .view = root,
                    .next = root.lowerBound(cursor_state.next_timestamp),
                };
                cursor_state.depth = 1;
                cursor_state.initialized = true;
            }

            var copied: usize = 0;
            var page_scratch: [format.page_size]u8 = undefined;
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
                    cursor_state.frames[cursor_state.depth] = .{
                        .view = child,
                        .next = child.lowerBound(cursor_state.next_timestamp),
                    };
                    cursor_state.depth += 1;
                    continue;
                }

                const page_view = try self.loadPage(entry.pointer, &page_scratch);
                if (page_view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(page_view.statistics), entry.summary))
                    return error.InvalidDatabase;
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
            const pointer = try self.findMappedPage(series_entry, handle.index, timestamp);
            var scratch: [format.page_size]u8 = undefined;
            const view = try self.loadPage(pointer, &scratch);
            if (view.series_id != series_entry.id) return error.InvalidDatabase;
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
            _ = try self.rangePreparedInternal(handle, start, end, null, null, &profile);
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
                mergeAggregateSummary(&result, series_entry.summary);
                return result;
            }
            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            if (frames[0].node.series_id != series_entry.id) return error.InvalidDatabase;
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
                    frames[depth] = .{ .node = child };
                    depth += 1;
                } else {
                    const view = try self.loadPage(entry.pointer, &page_scratch);
                    if (view.series_id != series_entry.id) return error.InvalidDatabase;
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
            _ = try self.resolve(handle);
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

            const series_entry = try self.resolve(handle);
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
                    frames[depth] = .{ .node = child };
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
            output: ?std.fs.File,
            buffers: ?*RangeBuffers,
            profile: ?*QueryProfile,
        ) !usize {
            if (end < start) return 0;
            if (comptime File == std.fs.File) if (self.mapping != null) {
                return self.rangeMapped(handle, start, end, output, buffers, profile);
            };
            var timer = if (profile != null) try std.time.Timer.start() else null;
            const series_entry = try self.resolve(handle);
            if (timer) |*value| profile.?.block_lookup_ns += value.lap();
            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            if (frames[0].node.series_id != series_entry.id or
                !summaryEqual(frames[0].node.summary, series_entry.summary))
            {
                return error.InvalidDatabase;
            }
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
                if (frame.node.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.node.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    frames[depth] = .{ .node = child };
                    depth += 1;
                    continue;
                }
                if (output == null and buffers == null and
                    entry.summary.timestamp_min >= start and entry.summary.timestamp_max <= end)
                {
                    matches = std.math.add(usize, matches, @intCast(entry.summary.point_count)) catch
                        return error.DatabaseTooLarge;
                    continue;
                }
                if (timer) |*value| value.reset();
                const view = try self.loadPage(entry.pointer, &page_scratch);
                if (timer) |*value| profile.?.file_read_ns += value.lap();
                if (view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(view.statistics), entry.summary))
                {
                    return error.InvalidDatabase;
                }
                if (output == null) {
                    if (buffers) |destination| {
                        const output_offset = @min(matches, destination.timestamps.len);
                        matches += try view.rangeInto(
                            start,
                            end,
                            destination.timestamps[output_offset..],
                            destination.values[output_offset..],
                        );
                    } else {
                        matches += view.countRange(start, end);
                    }
                    if (timer) |*value| profile.?.record_decode_ns += value.lap();
                    continue;
                }
                var point_index = view.lowerBound(start);
                if (point_index == view.statistics.count) continue;
                var timestamp_cursor = view.timestampCursor(point_index);
                var value_cursor = view.valueCursor(point_index);
                while (point_index < view.statistics.count) : (point_index += 1) {
                    const timestamp = timestamp_cursor.next();
                    if (timestamp > end) break;
                    const value = value_cursor.next();
                    if (buffers) |destination| if (matches < destination.timestamps.len) {
                        destination.timestamps[matches] = timestamp;
                        destination.values[matches] = value;
                    };
                    if (output) |out| try writePoint(out, timestamp, value);
                    matches += 1;
                }
                if (timer) |*value| profile.?.record_decode_ns += value.lap();
            }
            return matches;
        }

        fn rangeMapped(
            self: *Self,
            handle: SeriesHandle,
            start: i64,
            end: i64,
            output: ?std.fs.File,
            buffers: ?*RangeBuffers,
            profile: ?*QueryProfile,
        ) !usize {
            var timer = if (profile != null) try std.time.Timer.start() else null;
            const series_entry = try self.resolve(handle);
            if (timer) |*value| profile.?.block_lookup_ns += value.lap();
            var frames: [index.height_max]MappedTraversalFrame = undefined;
            const runtime = &self.series_runtime.items[handle.index];
            const root = runtime.root orelse blk: {
                const loaded = try self.loadMappedIndex(series_entry.root);
                runtime.root = loaded;
                if (loaded.level == 0 and loaded.count == 1)
                    runtime.single_page = loaded.entryAt(0);
                break :blk loaded;
            };
            if (root.series_id != series_entry.id or !summaryEqual(root.summary, series_entry.summary))
                return error.InvalidDatabase;
            if (runtime.single_page) |entry| {
                if (entry.summary.timestamp_max < start or entry.summary.timestamp_min > end)
                    return 0;
                if (output == null and buffers == null and
                    entry.summary.timestamp_min >= start and entry.summary.timestamp_max <= end)
                    return @intCast(entry.summary.point_count);
                var page_scratch: [format.page_size]u8 = undefined;
                const page_view = try self.loadPage(entry.pointer, &page_scratch);
                if (page_view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(page_view.statistics), entry.summary))
                    return error.InvalidDatabase;
                if (output == null) {
                    if (buffers) |destination| {
                        return page_view.rangeInto(
                            start,
                            end,
                            destination.timestamps,
                            destination.values,
                        );
                    }
                    return page_view.countRange(start, end);
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
                    if (buffers) |destination| if (single_matches < destination.timestamps.len) {
                        destination.timestamps[single_matches] = timestamp;
                        destination.values[single_matches] = value;
                    };
                    if (output) |out| try writePoint(out, timestamp, value);
                    single_matches += 1;
                }
                return single_matches;
            }
            frames[0] = .{ .view = root, .next = root.lowerBound(start) };
            var depth: usize = 1;
            var matches: usize = 0;
            var page_scratch: [format.page_size]u8 = undefined;
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
                if (frame.view.level > 0) {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadMappedIndex(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.view.level or
                        !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                    frames[depth] = .{ .view = child, .next = child.lowerBound(start) };
                    depth += 1;
                    continue;
                }
                if (output == null and buffers == null and
                    entry.summary.timestamp_min >= start and entry.summary.timestamp_max <= end)
                {
                    matches = std.math.add(usize, matches, @intCast(entry.summary.point_count)) catch
                        return error.DatabaseTooLarge;
                    continue;
                }
                if (timer) |*value| value.reset();
                const page_view = try self.loadPage(entry.pointer, &page_scratch);
                if (timer) |*value| profile.?.file_read_ns += value.lap();
                if (page_view.series_id != series_entry.id or
                    !summaryEqual(index.Summary.fromPage(page_view.statistics), entry.summary))
                    return error.InvalidDatabase;
                if (output == null) {
                    if (buffers) |destination| {
                        const output_offset = @min(matches, destination.timestamps.len);
                        matches += try page_view.rangeInto(
                            start,
                            end,
                            destination.timestamps[output_offset..],
                            destination.values[output_offset..],
                        );
                    } else {
                        matches += page_view.countRange(start, end);
                    }
                    if (timer) |*value| profile.?.record_decode_ns += value.lap();
                    continue;
                }
                var point_index = page_view.lowerBound(start);
                if (point_index == page_view.statistics.count) continue;
                var timestamp_cursor = page_view.timestampCursor(point_index);
                var value_cursor = page_view.valueCursor(point_index);
                while (point_index < page_view.statistics.count) : (point_index += 1) {
                    const timestamp = timestamp_cursor.next();
                    if (timestamp > end) break;
                    const value = value_cursor.next();
                    if (buffers) |destination| if (matches < destination.timestamps.len) {
                        destination.timestamps[matches] = timestamp;
                        destination.values[matches] = value;
                    };
                    if (output) |out| try writePoint(out, timestamp, value);
                    matches += 1;
                }
                if (timer) |*value| profile.?.record_decode_ns += value.lap();
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

        fn findMappedPage(
            self: *Self,
            series_entry: *const manifest.Series,
            series_index: u32,
            timestamp: i64,
        ) !format.Pointer {
            if (comptime File != std.fs.File) return error.BorrowedViewUnavailable;
            if (self.mapping == null) return error.BorrowedViewUnavailable;
            var node = self.series_runtime.items[series_index].root orelse blk: {
                const root = try self.loadMappedIndex(series_entry.root);
                self.series_runtime.items[series_index].root = root;
                break :blk root;
            };
            var depth: usize = 0;
            while (true) {
                if (depth == index.height_max) return error.InvalidDatabase;
                const entry_index = node.lowerBound(timestamp);
                if (entry_index >= node.count) return error.TimestampNotFound;
                const entry = node.entryAt(entry_index);
                if (node.level == 0) return entry.pointer;
                const child = try self.loadMappedIndex(entry.pointer);
                if (child.series_id != series_entry.id or child.level + 1 != node.level or
                    !summaryEqual(child.summary, entry.summary)) return error.InvalidDatabase;
                node = child;
                depth += 1;
            }
        }

        fn walkPages(self: *Self, handle: SeriesHandle, visitor: anytype, state: anytype) !void {
            const series_entry = try self.resolve(handle);
            var frames: [index.height_max]TraversalFrame = undefined;
            frames[0] = .{ .node = try self.loadNode(series_entry.root) };
            var depth: usize = 1;
            while (depth > 0) {
                var frame = &frames[depth - 1];
                if (frame.next >= frame.node.count) {
                    depth -= 1;
                    continue;
                }
                const entry = frame.node.entries[frame.next];
                frame.next += 1;
                if (frame.node.level == 0) {
                    try visitor(self, entry.pointer, entry.summary, state);
                } else {
                    if (depth == frames.len) return error.InvalidDatabase;
                    const child = try self.loadNode(entry.pointer);
                    if (child.series_id != series_entry.id or child.level + 1 != frame.node.level)
                        return error.InvalidDatabase;
                    frames[depth] = .{ .node = child };
                    depth += 1;
                }
            }
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

        fn loadPage(
            self: *Self,
            pointer: format.Pointer,
            scratch: *[format.page_size]u8,
        ) !page.View {
            if (pointer.kind != .data or pointer.size > format.page_size or
                pointer.size < format.page_header_size) return error.InvalidDatabase;
            const size: usize = pointer.size;
            const bytes: []const u8 = if (comptime File == std.fs.File) blk: {
                if (self.mapping) |mapped| {
                    const offset = std.math.cast(usize, pointer.offset) orelse
                        return error.InvalidDatabase;
                    const end = std.math.add(usize, offset, size) catch
                        return error.InvalidDatabase;
                    if (end > mapped.len) return error.InvalidDatabase;
                    break :blk mapped[offset..end];
                }
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
                    entry.kind == pointer.kind and checksum.equal(entry.identity, pointer.identity))
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

        fn findSeries(self: *Self, name: []const u8) ?*const manifest.Series {
            const series_index = self.series_directory.get(name) orelse return null;
            return &self.series.items[series_index];
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
            for (self.series.items) |entry| entry.deinit(self.allocator);
            self.series.deinit(self.allocator);
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

fn writePoint(out: std.fs.File, timestamp: i64, value: f64) !void {
    var buffer: [128]u8 = undefined;
    try out.writeAll(try std.fmt.bufPrint(&buffer, "{d} {d}\n", .{ timestamp, value }));
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
