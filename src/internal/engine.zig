const std = @import("std");
const format = @import("format.zig");

pub const file_header = format.file_header;
pub const block_size = format.block_size;
pub const block_header_size = format.block_header_size;
pub const record_size = format.record_size;
pub const records_per_block = format.records_per_block;
pub const compression_min_savings_percent = format.compression_min_savings_percent;
pub const Codec = format.Codec;

const footer_magic = format.footer_magic;
const trailer_magic = format.trailer_magic;
const snapshot_interval = format.snapshot_interval;
const block_magic = format.block_magic;
const trailer_size = format.trailer_size;
const raw_payload_capacity = format.raw_payload_capacity;
const chunk_record_count = format.chunk_record_count;
const checkpoint_entry_size = format.checkpoint_entry_size;
const footer_series_entry_size = 11;
const footer_block_entry_size = 33;

comptime {
    if (block_header_size >= block_size) @compileError("block header must leave payload space");
    if (raw_payload_capacity + block_header_size > block_size)
        @compileError("raw payload exceeds block size");
    if (records_per_block != @divExact(raw_payload_capacity, record_size))
        @compileError("raw block capacity constants disagree");
    if (checkpoint_entry_size != @sizeOf(i64) + @sizeOf(u32))
        @compileError("compressed checkpoint encoding size changed");
    if (snapshot_interval == 0 or snapshot_interval > std.math.maxInt(u8))
        @compileError("footer-chain depth must fit its in-memory counter");
    if (chunk_record_count == 0 or chunk_record_count > records_per_block)
        @compileError("compressed chunk bound is invalid");
}

const BlockIndex = struct {
    offset: u64,
    min_timestamp: i64,
    max_timestamp: i64,
    record_count: u32,
    stored_size: u32,
    codec: Codec,
};

const VerificationState = enum(u8) {
    unverified,
    block,
    compressed_structure,
};

// Verification belongs to the block descriptor at the same array index. A committed block is
// immutable under the single-writer protocol. Refresh transfers this state only when every
// identity field still matches, so a checksum result can never migrate to different bytes.
const BlockVerification = struct {
    // The allocation length is the authoritative BlockIndex.stored_size.
    cached: ?[*]u8 = null,
    timestamp_step: u64 = 0,
    state: VerificationState = .unverified,
};

comptime {
    if (@sizeOf(BlockIndex) > 64)
        @compileError("query-hot block metadata must fit in one small cache line");
    if (@sizeOf(BlockVerification) > 32)
        @compileError("cold verification metadata grew unexpectedly");
}

const BlockHeader = struct {
    series_id: u32,
    codec: Codec,
    min_timestamp: i64,
    max_timestamp: i64,
    record_count: u32,
    payload_size: u32,
    checksum: u64,
};

fn SeriesFor(comptime reader: bool) type {
    return struct {
        id: u32,
        name: []u8,
        blocks: std.ArrayList(BlockIndex) = .empty,
        verifications: if (reader) std.ArrayList(BlockVerification) else void =
            if (reader) .empty else {},
        block_search_stride: if (reader) u64 else void = if (reader) 0 else {},
        block_buffer: if (reader) void else *[block_size]u8 = if (reader) {} else undefined,
        pending_count: if (reader) void else u32 = if (reader) {} else 0,
        pending_min: if (reader) void else i64 = if (reader) {} else 0,
        last_timestamp: ?i64 = null,
        checkpointed_blocks: if (reader) void else usize = if (reader) {} else 0,
        known_to_footer: if (reader) void else bool = if (reader) {} else false,
    };
}

const WriterSeries = SeriesFor(false);
const ReaderSeries = SeriesFor(true);

const FooterPointer = struct {
    offset: u64,
    size: u64,
    checksum: u64,
};

fn CatalogLoadFor(comptime SeriesType: type) type {
    return struct {
        series: std.ArrayList(SeriesType),
        latest: FooterPointer,
        deltas_since_snapshot: u8,
    };
}

const FooterKind = enum(u8) { snapshot = 0, delta = 1 };
const SeriesDirectory = std.StringHashMapUnmanaged(u32);
const linear_series_search_limit = 4;

pub fn AppenderFor(comptime File: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        file: File,
        series: std.ArrayList(WriterSeries) = .empty,
        series_directory: SeriesDirectory = .empty,
        write_offset: u64,
        codec: Codec,
        dirty: bool = false,
        previous_footer: ?FooterPointer = null,
        deltas_since_snapshot: u8 = 0,
        footer_scratch: std.ArrayList(u8) = .empty,

        pub fn create(allocator: std.mem.Allocator, path: []const u8, codec: Codec) !Self {
            const file = try std.fs.cwd().createFile(path, .{
                .read = true,
                .exclusive = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            });
            errdefer file.close();
            try file.writeAll(&file_header);
            return .{
                .allocator = allocator,
                .file = file,
                .write_offset = file_header.len,
                .codec = codec,
            };
        }

        pub fn open(allocator: std.mem.Allocator, path: []const u8, codec: Codec) !Self {
            const cwd = std.fs.cwd();
            const file = cwd.openFile(path, .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |err| switch (err) {
                error.FileNotFound => return create(allocator, path, codec),
                else => return err,
            };
            errdefer file.close();
            const size = try file.getEndPos();
            if (size == 0) {
                try file.writeAll(&file_header);
                return .{
                    .allocator = allocator,
                    .file = file,
                    .write_offset = file_header.len,
                    .codec = codec,
                };
            }
            try validateHeader(file, size);
            if (size == file_header.len) {
                return .{
                    .allocator = allocator,
                    .file = file,
                    .write_offset = size,
                    .codec = codec,
                };
            }
            var catalog = try loadLatestCatalog(WriterSeries, file, size, allocator);
            errdefer deinitSeries(WriterSeries, allocator, &catalog.series);
            var series_directory = try buildSeriesDirectory(allocator, catalog.series.items);
            errdefer series_directory.deinit(allocator);
            return .{
                .allocator = allocator,
                .file = file,
                .series = catalog.series,
                .series_directory = series_directory,
                .write_offset = size,
                .codec = codec,
                .previous_footer = catalog.latest,
                .deltas_since_snapshot = catalog.deltas_since_snapshot,
            };
        }

        pub fn createOn(allocator: std.mem.Allocator, file: File, codec: Codec) !Self {
            errdefer file.close();
            if (try file.getEndPos() != 0) return error.InvalidDatabase;
            try file.pwriteAll(&file_header, 0);
            return .{
                .allocator = allocator,
                .file = file,
                .write_offset = file_header.len,
                .codec = codec,
            };
        }

        pub fn openOn(allocator: std.mem.Allocator, file: File, codec: Codec) !Self {
            errdefer file.close();
            const size = try file.getEndPos();
            if (size == 0) return createOn(allocator, file, codec);
            try validateHeader(file, size);
            if (size == file_header.len) return .{
                .allocator = allocator,
                .file = file,
                .write_offset = size,
                .codec = codec,
            };
            var catalog = try loadLatestCatalog(WriterSeries, file, size, allocator);
            errdefer deinitSeries(WriterSeries, allocator, &catalog.series);
            var series_directory = try buildSeriesDirectory(allocator, catalog.series.items);
            errdefer series_directory.deinit(allocator);
            return .{
                .allocator = allocator,
                .file = file,
                .series = catalog.series,
                .series_directory = series_directory,
                .write_offset = size,
                .codec = codec,
                .previous_footer = catalog.latest,
                .deltas_since_snapshot = catalog.deltas_since_snapshot,
            };
        }

        pub fn append(self: *Self, name: []const u8, timestamp: i64, value: f64) !void {
            const timestamps = [_]i64{timestamp};
            const values = [_]f64{value};
            try self.appendBatch(name, &timestamps, &values);
        }

        pub fn appendBatch(
            self: *Self,
            name: []const u8,
            timestamps: []const i64,
            values: []const f64,
        ) !void {
            if (timestamps.len != values.len) return error.InvalidBatch;
            if (timestamps.len == 0) return;

            const series = findSeriesByName(
                WriterSeries,
                self.series.items,
                self.series_directory,
                name,
            );
            if (timestamps.len == 1) {
                if (series) |existing| if (existing.last_timestamp) |last| {
                    if (timestamps[0] <= last) return error.TimestampNotIncreasing;
                };
                const target = series orelse try self.getOrCreateSeries(name);
                if (target.pending_count == records_per_block)
                    try target.blocks.ensureUnusedCapacity(self.allocator, 1);
                try self.appendToSeries(target, timestamps[0], values[0]);
                self.dirty = true;
                return;
            }

            if (series) |existing| if (existing.last_timestamp) |last| {
                if (timestamps[0] <= last) return error.TimestampNotIncreasing;
            };
            if (!timestampsStrictlyIncreasing(timestamps))
                return error.TimestampNotIncreasing;
            const target = series orelse try self.getOrCreateSeries(name);
            const pending_and_input = std.math.add(
                usize,
                target.pending_count,
                timestamps.len - 1,
            ) catch return error.DatabaseTooLarge;
            const blocks_needed = @divFloor(pending_and_input, records_per_block);
            try target.blocks.ensureUnusedCapacity(self.allocator, blocks_needed);
            try self.appendBatchToSeries(target, timestamps, values);
            self.dirty = true;
        }

        fn appendToSeries(self: *Self, series: *WriterSeries, timestamp: i64, value: f64) !void {
            if (series.pending_count == records_per_block) try self.flushSeries(series);
            if (series.pending_count == 0) series.pending_min = timestamp;
            const offset = block_header_size + @as(usize, series.pending_count) * record_size;
            const record = encodeRecord(timestamp, value);
            @memcpy(series.block_buffer[offset..][0..record_size], &record);
            series.pending_count += 1;
            series.last_timestamp = timestamp;
            std.debug.assert(series.pending_count <= records_per_block);
        }

        fn appendBatchToSeries(
            self: *Self,
            series: *WriterSeries,
            timestamps: []const i64,
            values: []const f64,
        ) !void {
            var consumed: usize = 0;
            while (consumed < timestamps.len) {
                if (series.pending_count == records_per_block) try self.flushSeries(series);
                const available = records_per_block - series.pending_count;
                const batch_count = @min(available, timestamps.len - consumed);
                if (series.pending_count == 0) series.pending_min = timestamps[consumed];
                const block_start = block_header_size +
                    @as(usize, series.pending_count) * record_size;
                for (0..batch_count) |batch_index| {
                    const input_index = consumed + batch_index;
                    const output_offset = block_start + batch_index * record_size;
                    const record = encodeRecord(timestamps[input_index], values[input_index]);
                    @memcpy(series.block_buffer[output_offset..][0..record_size], &record);
                }
                series.pending_count += @intCast(batch_count);
                consumed += batch_count;
                series.last_timestamp = timestamps[consumed - 1];
                std.debug.assert(series.pending_count <= records_per_block);
            }
        }

        pub fn checkpoint(self: *Self, sync: bool) !void {
            for (self.series.items) |*series| try self.flushSeries(series);
            const snapshot_due = self.previous_footer == null or
                self.deltas_since_snapshot >= snapshot_interval - 1;
            const kind: FooterKind = if (snapshot_due) .snapshot else .delta;
            const written = try writeFooter(
                self.file,
                self.write_offset,
                self.allocator,
                self.series.items,
                kind,
                self.previous_footer,
                &self.footer_scratch,
            );
            if (sync) try self.file.sync();
            self.write_offset = written.end_offset;
            self.previous_footer = written.pointer;
            self.deltas_since_snapshot = if (kind == .snapshot)
                0
            else
                self.deltas_since_snapshot + 1;
            for (self.series.items) |*series| {
                series.checkpointed_blocks = series.blocks.items.len;
                series.known_to_footer = true;
            }
            self.dirty = false;
        }

        pub fn close(self: *Self) !void {
            defer self.file.close();
            defer deinitSeries(WriterSeries, self.allocator, &self.series);
            defer self.series_directory.deinit(self.allocator);
            defer self.footer_scratch.deinit(self.allocator);
            if (self.dirty) try self.checkpoint(false);
        }

        pub fn abort(self: *Self) void {
            self.file.close();
            deinitSeries(WriterSeries, self.allocator, &self.series);
            self.series_directory.deinit(self.allocator);
            self.footer_scratch.deinit(self.allocator);
        }

        fn getOrCreateSeries(self: *Self, name: []const u8) !*WriterSeries {
            if (findSeriesByName(
                WriterSeries,
                self.series.items,
                self.series_directory,
                name,
            )) |series| return series;
            if (name.len == 0 or name.len > std.math.maxInt(u16)) return error.InvalidSeriesName;
            try self.series_directory.ensureUnusedCapacity(self.allocator, 1);
            var next_id: u32 = 0;
            for (self.series.items) |series| if (series.id >= next_id) {
                next_id = try std.math.add(u32, series.id, 1);
            };
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const block_buffer = try self.allocator.create([block_size]u8);
            errdefer self.allocator.destroy(block_buffer);
            try self.series.append(self.allocator, .{
                .id = next_id,
                .name = owned_name,
                .block_buffer = block_buffer,
            });
            const series_index = self.series.items.len - 1;
            self.series_directory.putAssumeCapacityNoClobber(owned_name, @intCast(series_index));
            return &self.series.items[series_index];
        }

        fn flushSeries(self: *Self, series: *WriterSeries) !void {
            if (series.pending_count == 0) return;
            const raw_len = @as(usize, series.pending_count) * record_size;
            const raw_payload = series.block_buffer[block_header_size..][0..raw_len];
            var encoded: [block_size]u8 = undefined;
            var timestamp_buffer: [raw_payload_capacity]u8 = undefined;
            const encoding = selectBlockEncoding(
                self.codec,
                raw_payload,
                series.pending_count,
                &encoded,
                &timestamp_buffer,
            );
            const selected_codec = encoding.codec;
            const payload_len = encoding.payload_size;
            const payload = if (selected_codec == .raw)
                raw_payload
            else
                encoded[block_header_size..][0..payload_len];
            const header = BlockHeader{
                .series_id = series.id,
                .codec = selected_codec,
                .min_timestamp = series.pending_min,
                .max_timestamp = series.last_timestamp.?,
                .record_count = series.pending_count,
                .payload_size = @intCast(payload_len),
                .checksum = checksum(payload),
            };
            const stored_size: u32 = @intCast(block_header_size + payload_len);
            if (selected_codec == .raw) {
                encodeBlockHeader(series.block_buffer[0..block_header_size], header);
                try self.file.pwriteAll(series.block_buffer[0..stored_size], self.write_offset);
            } else {
                encodeBlockHeader(encoded[0..block_header_size], header);
                try self.file.pwriteAll(encoded[0..stored_size], self.write_offset);
            }
            try series.blocks.append(self.allocator, .{
                .offset = self.write_offset,
                .min_timestamp = header.min_timestamp,
                .max_timestamp = header.max_timestamp,
                .record_count = header.record_count,
                .stored_size = stored_size,
                .codec = selected_codec,
            });
            self.write_offset = try std.math.add(u64, self.write_offset, stored_size);
            series.pending_count = 0;
            std.debug.assert(series.blocks.items.len > 0);
            const last_block = series.blocks.items[series.blocks.items.len - 1];
            std.debug.assert(last_block.offset <= self.write_offset);
        }
    };
}

pub const Appender = AppenderFor(std.fs.File);

const EncodingChoice = struct {
    codec: Codec,
    payload_size: usize,
};

fn selectBlockEncoding(
    requested_codec: Codec,
    raw_payload: []const u8,
    record_count: u32,
    encoded: *[block_size]u8,
    timestamp_buffer: *[raw_payload_capacity]u8,
) EncodingChoice {
    if (requested_codec == .raw) return .{ .codec = .raw, .payload_size = raw_payload.len };
    const sample_count = @min(record_count, 128);
    const sample_raw_len = @as(usize, sample_count) * record_size;
    const sample_len = compressPayload(
        raw_payload[0..sample_raw_len],
        sample_count,
        encoded[block_header_size..],
        timestamp_buffer,
    );
    const sample_saves_enough = if (sample_len) |length|
        length * 100 <= sample_raw_len * (100 - compression_min_savings_percent)
    else
        false;
    if (!valuesWorthCompressing(raw_payload[0..sample_raw_len], sample_count) or
        !sample_saves_enough)
        return .{ .codec = .raw, .payload_size = raw_payload.len };

    const encoded_len = compressPayload(
        raw_payload,
        record_count,
        encoded[block_header_size..],
        timestamp_buffer,
    ) orelse return .{ .codec = .raw, .payload_size = raw_payload.len };
    if (encoded_len * 100 > raw_payload.len * (100 - compression_min_savings_percent))
        return .{ .codec = .raw, .payload_size = raw_payload.len };
    return .{ .codec = .compressed, .payload_size = encoded_len };
}

pub const QueryProfile = struct {
    block_lookup_ns: u64 = 0,
    file_read_ns: u64 = 0,
    checksum_ns: u64 = 0,
    record_decode_ns: u64 = 0,
};

const RangeBuffers = struct {
    timestamps: []i64,
    values: []f64,
    count: usize = 0,
};

const LoadedBlock = struct {
    header: BlockHeader,
    payload: []const u8,
};

pub fn ReaderFor(comptime File: type) type {
    return struct {
        const Self = @This();
        const Mapping = if (File == std.fs.File) ?[]align(std.heap.page_size_min) u8 else void;
        allocator: std.mem.Allocator,
        file: File,
        series: std.ArrayList(ReaderSeries),
        series_directory: SeriesDirectory = .empty,
        latest_footer: ?FooterPointer = null,
        observed_file_size: u64,
        mapping: Mapping = if (File == std.fs.File) null else {},

        pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
            const file = try std.fs.cwd().openFile(path, .{});
            errdefer file.close();
            const size = try file.getEndPos();
            try validateHeader(file, size);
            if (size == file_header.len) return .{
                .allocator = allocator,
                .file = file,
                .series = .empty,
                .observed_file_size = size,
                .mapping = try mapFile(file, size),
            };
            var catalog = try loadLatestCatalog(ReaderSeries, file, size, allocator);
            errdefer deinitSeries(ReaderSeries, allocator, &catalog.series);
            var series_directory = try buildSeriesDirectory(allocator, catalog.series.items);
            errdefer series_directory.deinit(allocator);
            return .{
                .allocator = allocator,
                .file = file,
                .series = catalog.series,
                .series_directory = series_directory,
                .latest_footer = catalog.latest,
                .observed_file_size = size,
                .mapping = try mapFile(file, size),
            };
        }

        pub fn openOn(allocator: std.mem.Allocator, file: File) !Self {
            errdefer file.close();
            const size = try file.getEndPos();
            try validateHeader(file, size);
            if (size == file_header.len) return .{
                .allocator = allocator,
                .file = file,
                .series = .empty,
                .observed_file_size = size,
            };
            var catalog = try loadLatestCatalog(ReaderSeries, file, size, allocator);
            errdefer deinitSeries(ReaderSeries, allocator, &catalog.series);
            var series_directory = try buildSeriesDirectory(allocator, catalog.series.items);
            errdefer series_directory.deinit(allocator);
            return .{
                .allocator = allocator,
                .file = file,
                .series = catalog.series,
                .series_directory = series_directory,
                .latest_footer = catalog.latest,
                .observed_file_size = size,
            };
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

        fn unmapFile(mapping: Mapping) void {
            if (comptime File == std.fs.File) if (mapping) |bytes| std.posix.munmap(bytes);
        }

        pub fn refresh(self: *Self) !bool {
            const size = try self.file.getEndPos();
            if (size == self.observed_file_size) return false;
            if (size == file_header.len) {
                self.observed_file_size = size;
                return false;
            }
            const latest = try findLatestFooter(self.file, size, self.allocator);
            if (self.latest_footer) |current| {
                if (sameFooter(current, latest)) {
                    self.observed_file_size = size;
                    return false;
                }
            }

            var catalog = try reconstructCatalog(ReaderSeries, self.file, self.allocator, latest);
            errdefer deinitSeries(ReaderSeries, self.allocator, &catalog.series);
            var series_directory = try buildSeriesDirectory(self.allocator, catalog.series.items);
            errdefer series_directory.deinit(self.allocator);
            const new_mapping = try mapFile(self.file, size);
            preserveVerifiedBlocks(self.series.items, catalog.series.items);
            self.series_directory.deinit(self.allocator);
            deinitSeries(ReaderSeries, self.allocator, &self.series);
            unmapFile(self.mapping);
            self.series = catalog.series;
            self.series_directory = series_directory;
            self.latest_footer = latest;
            self.observed_file_size = size;
            self.mapping = new_mapping;
            return true;
        }

        pub fn latestTimestamp(self: *Self, name: []const u8) !?i64 {
            const series = self.findSeries(name) orelse return error.SeriesNotFound;
            return series.last_timestamp;
        }

        pub fn close(self: *Self) void {
            unmapFile(self.mapping);
            self.file.close();
            self.series_directory.deinit(self.allocator);
            deinitSeries(ReaderSeries, self.allocator, &self.series);
        }

        pub fn codecCounts(self: *Self, name: []const u8) ![2]usize {
            const series = self.findSeries(name) orelse return error.SeriesNotFound;
            var counts = [_]usize{ 0, 0 };
            for (series.blocks.items) |block| counts[@intFromEnum(block.codec)] += 1;
            return counts;
        }

        pub fn range(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            output: ?std.fs.File,
        ) !usize {
            return self.rangeInternal(name, start, end, output, null, null);
        }

        pub fn rangeInto(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            timestamps: []i64,
            values: []f64,
        ) !usize {
            if (timestamps.len != values.len) return error.InvalidBatch;
            var buffers = RangeBuffers{ .timestamps = timestamps, .values = values };
            return self.rangeInternal(name, start, end, null, null, &buffers);
        }

        pub fn profileRange(self: *Self, name: []const u8, start: i64, end: i64) !QueryProfile {
            var profile = QueryProfile{};
            _ = try self.rangeInternal(name, start, end, null, &profile, null);
            return profile;
        }

        fn rangeInternal(
            self: *Self,
            name: []const u8,
            start: i64,
            end: i64,
            output: ?std.fs.File,
            profile: ?*QueryProfile,
            buffers: ?*RangeBuffers,
        ) !usize {
            var timer = if (profile != null) try std.time.Timer.start() else null;
            if (end < start) return 0;
            const series = self.findSeries(name) orelse return error.SeriesNotFound;
            const low = findFirstBlock(series, start);
            if (timer) |*stage_timer| profile.?.block_lookup_ns += stage_timer.lap();

            var matches: usize = 0;
            var block: [block_size]u8 = undefined;
            std.debug.assert(series.blocks.items.len == series.verifications.items.len);
            for (series.blocks.items[low..], low..) |*index, block_index| {
                if (index.min_timestamp > end) break;
                if (timer) |*stage_timer| stage_timer.reset();
                const verification = &series.verifications.items[block_index];

                const loaded = try self.loadBlock(
                    series.id,
                    index,
                    verification,
                    &block,
                    if (timer) |*stage_timer| stage_timer else null,
                    profile,
                );
                if (loaded.header.codec == .compressed and
                    verification.state != .compressed_structure)
                {
                    std.debug.assert(verification.state == .block);
                    try validateCompressedTable(loaded.header.record_count, loaded.payload);
                    verification.state = .compressed_structure;
                    std.debug.assert(verification.state == .compressed_structure);
                }
                matches += try scanBlock(
                    loaded.header,
                    loaded.payload,
                    verification.timestamp_step,
                    start,
                    end,
                    output,
                    buffers,
                );
                if (timer) |*stage_timer| profile.?.record_decode_ns += stage_timer.lap();
            }
            return matches;
        }

        fn loadBlock(
            self: *Self,
            series_id: u32,
            index: *const BlockIndex,
            verification: *BlockVerification,
            scratch: *[block_size]u8,
            timer: ?*std.time.Timer,
            profile: ?*QueryProfile,
        ) !LoadedBlock {
            if (comptime File == std.fs.File) if (self.mapping) |mapped| {
                const offset = std.math.cast(usize, index.offset) orelse
                    return error.InvalidDatabase;
                const block_end = std.math.add(usize, offset, index.stored_size) catch
                    return error.InvalidDatabase;
                if (block_end > mapped.len) return error.InvalidDatabase;
                const block_bytes = mapped[offset..block_end];
                const header = try verifyBlock(
                    block_bytes,
                    series_id,
                    index,
                    verification,
                );
                if (timer) |stage_timer| {
                    profile.?.file_read_ns += stage_timer.lap();
                    profile.?.checksum_ns += stage_timer.lap();
                }
                return .{ .header = header, .payload = block_bytes[block_header_size..] };
            };

            if (verification.cached) |cached_pointer| {
                std.debug.assert(verification.state != .unverified);
                const cached = cached_pointer[0..index.stored_size];
                if (timer) |stage_timer| {
                    profile.?.file_read_ns += stage_timer.lap();
                    profile.?.checksum_ns += stage_timer.lap();
                }
                return .{
                    .header = headerFromIndex(series_id, index.*),
                    .payload = cached[block_header_size..],
                };
            }

            if (index.stored_size > block_size) return error.InvalidDatabase;
            const bytes_read = try self.file.preadAll(
                scratch[0..index.stored_size],
                index.offset,
            );
            if (bytes_read != index.stored_size) return error.InvalidDatabase;
            const block_bytes = scratch[0..index.stored_size];
            if (timer) |stage_timer| profile.?.file_read_ns += stage_timer.lap();
            const header = try verifyBlock(block_bytes, series_id, index, verification);
            errdefer {
                verification.state = .unverified;
                verification.timestamp_step = 0;
            }
            const cached = try self.allocator.dupe(u8, block_bytes);
            verification.cached = cached.ptr;
            if (timer) |stage_timer| profile.?.checksum_ns += stage_timer.lap();
            return .{ .header = header, .payload = cached[block_header_size..] };
        }

        fn findSeries(self: *Self, name: []const u8) ?*ReaderSeries {
            return findSeriesByName(ReaderSeries, self.series.items, self.series_directory, name);
        }
    };
}

pub const Reader = ReaderFor(std.fs.File);

fn timestampsStrictlyIncreasing(timestamps: []const i64) bool {
    const Vector = @Vector(4, i64);
    var index: usize = 1;
    while (index + 4 <= timestamps.len) : (index += 4) {
        const previous: Vector = timestamps[index - 1 ..][0..4].*;
        const current: Vector = timestamps[index..][0..4].*;
        if (@reduce(.Or, current <= previous)) return false;
    }
    while (index < timestamps.len) : (index += 1) {
        if (timestamps[index] <= timestamps[index - 1]) return false;
    }
    return true;
}

fn buildSeriesDirectory(allocator: std.mem.Allocator, series: anytype) !SeriesDirectory {
    if (series.len > std.math.maxInt(u32)) return error.InvalidDatabase;
    var directory: SeriesDirectory = .empty;
    errdefer directory.deinit(allocator);
    try directory.ensureUnusedCapacity(allocator, @intCast(series.len));
    for (series, 0..) |entry, series_index| {
        directory.putAssumeCapacityNoClobber(entry.name, @intCast(series_index));
    }
    return directory;
}

inline fn findSeriesByName(
    comptime SeriesType: type,
    series: []SeriesType,
    directory: SeriesDirectory,
    name: []const u8,
) ?*SeriesType {
    if (series.len <= linear_series_search_limit) {
        for (series) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }
    const series_index = directory.get(name) orelse return null;
    std.debug.assert(series_index < series.len);
    std.debug.assert(std.mem.eql(u8, series[series_index].name, name));
    return &series[series_index];
}

fn deriveBlockSearchStride(blocks: []const BlockIndex) u64 {
    if (blocks.len < 2) return 0;
    var timestamp_step: u64 = 0;
    for (blocks, 0..) |block, block_index| {
        if (block.record_count > 1) {
            const span: u64 = @intCast(@as(i128, block.max_timestamp) - block.min_timestamp);
            const intervals = block.record_count - 1;
            if (span % intervals != 0) return 0;
            const block_step = @divExact(span, intervals);
            if (block_step == 0) return 0;
            if (timestamp_step == 0)
                timestamp_step = block_step
            else if (timestamp_step != block_step)
                return 0;
        }
        if (block_index + 1 < blocks.len) {
            if (block.record_count != records_per_block or timestamp_step == 0) return 0;
            const next_distance = @as(i128, blocks[block_index + 1].min_timestamp) -
                block.max_timestamp;
            if (next_distance != timestamp_step) return 0;
        }
    }
    return std.math.mul(u64, timestamp_step, records_per_block) catch 0;
}

fn findFirstBlock(series: *const ReaderSeries, timestamp: i64) usize {
    const blocks = series.blocks.items;
    if (blocks.len == 0 or timestamp <= blocks[0].min_timestamp) return 0;
    if (series.block_search_stride != 0) {
        // Footer metadata proved full, equally spaced blocks. Bounds are still checked before
        // accepting the estimate so malformed but checksummed metadata falls back to search.
        const distance: u64 = @intCast(@as(i128, timestamp) - blocks[0].min_timestamp);
        const estimated = @min(
            @divFloor(distance, series.block_search_stride),
            blocks.len - 1,
        );
        const block_index: usize = @intCast(estimated);
        const follows_previous = block_index == 0 or
            blocks[block_index - 1].max_timestamp < timestamp;
        if (follows_previous and blocks[block_index].max_timestamp >= timestamp) return block_index;
    }

    var low: usize = 0;
    var high = blocks.len;
    while (low < high) {
        const middle = low + @divFloor(high - low, 2);
        if (blocks[middle].max_timestamp < timestamp) low = middle + 1 else high = middle;
    }
    return low;
}

inline fn verifyBlock(
    block_bytes: []const u8,
    series_id: u32,
    index: *const BlockIndex,
    verification: *BlockVerification,
) !BlockHeader {
    if (verification.state != .unverified) return headerFromIndex(series_id, index.*);
    const header = try decodeAndValidateBlock(block_bytes, series_id, index.*);
    const payload = block_bytes[block_header_size..];
    if (checksum(payload) != header.checksum) return error.ChecksumMismatch;
    std.debug.assert(verification.state == .unverified);
    if (header.codec == .raw)
        verification.timestamp_step = try validateRawPayload(header, payload);
    verification.state = .block;
    std.debug.assert(verification.state != .unverified);
    return header;
}

inline fn headerFromIndex(series_id: u32, index: BlockIndex) BlockHeader {
    return .{
        .series_id = series_id,
        .codec = index.codec,
        .min_timestamp = index.min_timestamp,
        .max_timestamp = index.max_timestamp,
        .record_count = index.record_count,
        .payload_size = index.stored_size - block_header_size,
        .checksum = 0,
    };
}

fn decodeAndValidateBlock(block_bytes: []const u8, series_id: u32, index: BlockIndex) !BlockHeader {
    const header = try decodeBlockHeader(block_bytes[0..block_header_size]);
    if (header.series_id != series_id or header.codec != index.codec or
        header.record_count != index.record_count or header.min_timestamp != index.min_timestamp or
        header.max_timestamp != index.max_timestamp or
        block_header_size + header.payload_size != index.stored_size)
        return error.InvalidDatabase;
    return header;
}

fn validateRawPayload(header: BlockHeader, payload: []const u8) !u64 {
    const expected_size = @as(usize, header.record_count) * record_size;
    if (payload.len != expected_size) return error.InvalidDatabase;

    var previous = decodeTimestamp(payload[0..record_size]);
    if (previous != header.min_timestamp) return error.InvalidDatabase;
    if (header.record_count == 1) {
        if (previous != header.max_timestamp) return error.InvalidDatabase;
        return 0;
    }

    const second = decodeTimestamp(payload[record_size..][0..record_size]);
    if (second <= previous) return error.InvalidDatabase;
    const first_step: u64 = @intCast(@as(i128, second) - previous);
    var fixed_step = true;
    previous = second;
    for (2..header.record_count) |record_index| {
        const offset = record_index * record_size;
        const timestamp = decodeTimestamp(payload[offset..][0..record_size]);
        if (timestamp <= previous) return error.InvalidDatabase;
        if (@as(i128, timestamp) - previous != first_step) fixed_step = false;
        previous = timestamp;
    }
    if (previous != header.max_timestamp) return error.InvalidDatabase;
    return if (fixed_step) first_step else 0;
}

fn rawRecordsLowerBound(
    header: BlockHeader,
    payload: []const u8,
    timestamp_step: u64,
    target: i64,
) usize {
    if (target <= header.min_timestamp) return 0;
    if (target > header.max_timestamp) return header.record_count;
    if (timestamp_step != 0) {
        // Full-block validation proved every interior delta equal. The arithmetic position is
        // therefore exact; this is not an interpolation guess and needs no corrective search.
        const distance: u64 = @intCast(@as(i128, target) - header.min_timestamp);
        if (timestamp_step == 1) return @intCast(@min(distance, header.record_count));
        const quotient = @divFloor(distance, timestamp_step);
        const record_index = quotient + @intFromBool(distance % timestamp_step != 0);
        return @intCast(@min(record_index, header.record_count));
    }

    var low: usize = 0;
    var high: usize = header.record_count;
    while (low < high) {
        const middle = low + @divFloor(high - low, 2);
        const timestamp = decodeTimestamp(payload[middle * record_size ..][0..record_size]);
        if (timestamp < target) low = middle + 1 else high = middle;
    }
    return low;
}

fn scanBlock(
    header: BlockHeader,
    payload: []const u8,
    timestamp_step: u64,
    start: i64,
    end: i64,
    output: ?std.fs.File,
    buffers: ?*RangeBuffers,
) !usize {
    var matches: usize = 0;
    if (header.codec == .raw) {
        const low = rawRecordsLowerBound(header, payload, timestamp_step, start);
        if (low > header.record_count) return error.InvalidDatabase;
        if (buffers) |points| {
            for (low..header.record_count) |i| {
                const record = payload[i * record_size ..][0..record_size];
                const timestamp = decodeTimestamp(record);
                if (timestamp > end) break;
                if (points.count < points.timestamps.len) {
                    points.timestamps[points.count] = timestamp;
                    points.values[points.count] = decodeValue(record);
                }
                points.count += 1;
                matches += 1;
            }
        } else if (output) |out| {
            for (low..header.record_count) |i| {
                const record = payload[i * record_size ..][0..record_size];
                const timestamp = decodeTimestamp(record);
                if (timestamp > end) break;
                try printRecord(out, timestamp, decodeValue(record));
                matches += 1;
            }
        } else {
            for (low..header.record_count) |i| {
                if (decodeTimestamp(payload[i * record_size ..][0..record_size]) > end) break;
                matches += 1;
            }
        }
    } else {
        matches = try scanCompressedBlock(
            header.record_count,
            payload,
            start,
            end,
            output,
            buffers,
        );
    }
    return matches;
}

fn chunksForRecords(count: u32) usize {
    return @divFloor(@as(usize, count) + chunk_record_count - 1, chunk_record_count);
}

fn scanCompressedBlock(
    count: u32,
    payload: []const u8,
    start: i64,
    end: i64,
    output: ?std.fs.File,
    buffers: ?*RangeBuffers,
) !usize {
    if (payload.len < 4) return error.InvalidDatabase;
    const chunk_count = std.mem.readInt(u32, payload[0..4], .little);
    const expected_chunks = chunksForRecords(count);
    if (chunk_count != expected_chunks) return error.InvalidDatabase;
    const table_size = 4 + @as(usize, chunk_count) * checkpoint_entry_size;
    if (table_size > payload.len) return error.InvalidDatabase;

    var low: usize = 0;
    var high: usize = chunk_count;
    while (low < high) {
        const middle = low + @divFloor(high - low, 2);
        const entry = 4 + middle * checkpoint_entry_size;
        const timestamp = std.mem.readInt(i64, payload[entry..][0..8], .little);
        if (timestamp <= start) low = middle + 1 else high = middle;
    }
    var chunk_index: usize = if (low == 0) 0 else low - 1;
    var matches: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const entry = 4 + chunk_index * checkpoint_entry_size;
        const first_timestamp = std.mem.readInt(i64, payload[entry..][0..8], .little);
        if (first_timestamp > end) break;
        const chunk_offset = std.mem.readInt(u32, payload[entry + 8 ..][0..4], .little);
        const chunk_end = if (chunk_index + 1 < chunk_count)
            std.mem.readInt(u32, payload[entry + checkpoint_entry_size + 8 ..][0..4], .little)
        else
            payload.len;
        if (chunk_end <= chunk_offset or chunk_end > payload.len) return error.InvalidDatabase;
        const first_record = chunk_index * chunk_record_count;
        const records_in_chunk: u32 = @intCast(@min(
            chunk_record_count,
            @as(usize, count) - first_record,
        ));
        var decoder = try CompressedDecoder.init(
            payload[chunk_offset..chunk_end],
            records_in_chunk,
        );
        if (buffers) |points| {
            for (0..records_in_chunk) |_| {
                const point = try decoder.next();
                if (point.timestamp < start) continue;
                if (point.timestamp > end) break;
                if (points.count < points.timestamps.len) {
                    points.timestamps[points.count] = point.timestamp;
                    points.values[points.count] = point.value;
                }
                points.count += 1;
                matches += 1;
            }
        } else {
            for (0..records_in_chunk) |_| {
                const point = try decoder.next();
                if (point.timestamp < start) continue;
                if (point.timestamp > end) break;
                matches += 1;
                if (output) |out| try printRecord(out, point.timestamp, point.value);
            }
        }
    }
    return matches;
}

fn validateCompressedTable(count: u32, payload: []const u8) !void {
    if (payload.len < 4) return error.InvalidDatabase;
    const chunk_count = std.mem.readInt(u32, payload[0..4], .little);
    const expected_chunks = chunksForRecords(count);
    if (chunk_count != expected_chunks) return error.InvalidDatabase;
    const table_size = 4 + @as(usize, chunk_count) * checkpoint_entry_size;
    if (table_size > payload.len) return error.InvalidDatabase;
    var previous_timestamp: ?i64 = null;
    var previous_offset: usize = table_size;
    for (0..chunk_count) |chunk_index| {
        const entry = 4 + chunk_index * checkpoint_entry_size;
        const timestamp = std.mem.readInt(i64, payload[entry..][0..8], .little);
        const offset = std.mem.readInt(u32, payload[entry + 8 ..][0..4], .little);
        if (offset < table_size or offset < previous_offset or offset >= payload.len)
            return error.InvalidDatabase;
        if (previous_timestamp) |previous| if (timestamp <= previous) return error.InvalidDatabase;
        previous_timestamp = timestamp;
        previous_offset = offset;
    }
}

fn collectPoint(buffers: ?*RangeBuffers, timestamp: i64, value: f64) void {
    if (buffers) |points| {
        if (points.count < points.timestamps.len) {
            points.timestamps[points.count] = timestamp;
            points.values[points.count] = value;
        }
        points.count += 1;
    }
}

fn valuesWorthCompressing(records: []const u8, count: u32) bool {
    if (count < 2) return false;
    var encoded_bits: usize = 64;
    var previous: u64 = @bitCast(decodeValue(records[0..record_size]));
    for (1..count) |i| {
        const value: u64 = @bitCast(decodeValue(records[i * record_size ..][0..record_size]));
        const xor = value ^ previous;
        encoded_bits += if (xor == 0) 1 else 13 + (64 - @clz(xor) - @ctz(xor));
        previous = value;
    }
    return encoded_bits < @as(usize, count) * 64;
}

fn compressPayload(records: []const u8, count: u32, output: []u8, timestamps: []u8) ?usize {
    if (count == 0) return null;
    const chunk_count = chunksForRecords(count);
    const table_size = 4 + chunk_count * checkpoint_entry_size;
    if (table_size >= output.len) return null;
    std.mem.writeInt(u32, output[0..4], @intCast(chunk_count), .little);

    var cursor = table_size;
    for (0..chunk_count) |chunk_index| {
        const first_record = chunk_index * chunk_record_count;
        const records_in_chunk: u32 = @intCast(@min(
            chunk_record_count,
            @as(usize, count) - first_record,
        ));
        const entry = 4 + chunk_index * checkpoint_entry_size;
        const first_timestamp = decodeTimestamp(
            records[first_record * record_size ..][0..record_size],
        );
        std.mem.writeInt(i64, output[entry..][0..8], first_timestamp, .little);
        std.mem.writeInt(u32, output[entry + 8 ..][0..4], @intCast(cursor), .little);
        const chunk_start = first_record * record_size;
        const chunk_size = @as(usize, records_in_chunk) * record_size;
        const chunk_bytes = records[chunk_start..][0..chunk_size];
        const encoded_len = compressChunk(
            chunk_bytes,
            records_in_chunk,
            output[cursor..],
            timestamps,
        ) orelse return null;
        cursor += encoded_len;
    }
    return cursor;
}

fn compressChunk(records: []const u8, count: u32, output: []u8, timestamps: []u8) ?usize {
    if (count == 0 or output.len < 12) return null;
    var timestamp_len: usize = 0;
    const first = decodeTimestamp(records[0..record_size]);
    std.mem.writeInt(i64, timestamps[0..8], first, .little);
    timestamp_len = 8;
    var previous_timestamp = first;
    var previous_delta: i64 = 0;

    for (1..count) |i| {
        const timestamp = decodeTimestamp(records[i * record_size ..][0..record_size]);
        const difference = @as(i128, timestamp) - previous_timestamp;
        if (difference <= 0 or difference > std.math.maxInt(i64)) return null;
        const delta: i64 = @intCast(difference);
        if (i == 1) {
            timestamp_len += writeVarint(
                timestamps[timestamp_len..],
                @intCast(delta),
            ) orelse return null;
        } else {
            const delta_difference = @as(i128, delta) - previous_delta;
            if (delta_difference < std.math.minInt(i64) or
                delta_difference > std.math.maxInt(i64)) return null;
            timestamp_len += writeVarint(
                timestamps[timestamp_len..],
                zigzagEncode(@intCast(delta_difference)),
            ) orelse return null;
        }
        previous_timestamp = timestamp;
        previous_delta = delta;
    }

    if (4 + timestamp_len + 8 > output.len) return null;
    std.mem.writeInt(u32, output[0..4], @intCast(timestamp_len), .little);
    @memcpy(output[4..][0..timestamp_len], timestamps[0..timestamp_len]);
    var value_offset = 4 + timestamp_len;
    var previous_value: u64 = @bitCast(decodeValue(records[0..record_size]));
    std.mem.writeInt(u64, output[value_offset..][0..8], previous_value, .little);
    value_offset += 8;
    @memset(output[value_offset..], 0);
    var writer = BitWriter{ .bytes = output[value_offset..] };

    for (1..count) |i| {
        const value: u64 = @bitCast(decodeValue(records[i * record_size ..][0..record_size]));
        const xor = value ^ previous_value;
        if (xor == 0) {
            writer.write(0, 1) catch return null;
        } else {
            writer.write(1, 1) catch return null;
            const leading: u6 = @intCast(@clz(xor));
            const trailing: u6 = @intCast(@ctz(xor));
            const significant: u7 = 64 - @as(u7, leading) - @as(u7, trailing);
            writer.write(leading, 6) catch return null;
            writer.write(significant - 1, 6) catch return null;
            writer.write(xor >> trailing, significant) catch return null;
        }
        previous_value = value;
    }
    return value_offset + writer.byteLen();
}

const CompressedDecoder = struct {
    timestamps: []const u8,
    timestamp_cursor: usize = 8,
    values_first: u64,
    value_reader: BitReader,
    count: u32,
    index: u32 = 0,
    timestamp: i64,
    delta: i64 = 0,
    value: u64,

    fn init(payload: []const u8, count: u32) !CompressedDecoder {
        if (payload.len < 20) return error.InvalidDatabase;
        const timestamp_len = std.mem.readInt(u32, payload[0..4], .little);
        if (timestamp_len < 8 or 4 + timestamp_len + 8 > payload.len) return error.InvalidDatabase;
        const timestamp = std.mem.readInt(i64, payload[4..12], .little);
        const value_offset = 4 + timestamp_len;
        const value = std.mem.readInt(u64, payload[value_offset..][0..8], .little);
        return .{
            .timestamps = payload[4..value_offset],
            .values_first = value,
            .value_reader = .{ .bytes = payload[value_offset + 8 ..] },
            .count = count,
            .timestamp = timestamp,
            .value = value,
        };
    }

    const Point = struct { timestamp: i64, value: f64 };

    inline fn next(self: *CompressedDecoder) !Point {
        if (self.index >= self.count) return error.InvalidDatabase;
        if (self.index > 0) {
            if (self.index == 1) {
                const encoded = try readVarint(self.timestamps, &self.timestamp_cursor);
                if (encoded > std.math.maxInt(i64)) return error.InvalidDatabase;
                self.delta = @intCast(encoded);
            } else {
                const difference = zigzagDecode(try readVarint(
                    self.timestamps,
                    &self.timestamp_cursor,
                ));
                self.delta = std.math.add(i64, self.delta, difference) catch
                    return error.InvalidDatabase;
            }
            self.timestamp = std.math.add(i64, self.timestamp, self.delta) catch
                return error.InvalidDatabase;
            if (try self.value_reader.read(1) == 1) {
                const leading: u6 = @intCast(try self.value_reader.read(6));
                const significant: u7 = @as(u7, @intCast(try self.value_reader.read(6))) + 1;
                if (@as(u7, leading) + significant > 64) return error.InvalidDatabase;
                const trailing: u6 = @intCast(64 - @as(u7, leading) - significant);
                self.value ^= (try self.value_reader.read(significant)) << trailing;
            }
        }
        self.index += 1;
        return .{ .timestamp = self.timestamp, .value = @bitCast(self.value) };
    }
};

const BitWriter = struct {
    bytes: []u8,
    bit_len: usize = 0,
    byte_position: usize = 0,
    reservoir: u128 = 0,
    reservoir_bits: u8 = 0,

    inline fn write(self: *BitWriter, value: anytype, count: u7) !void {
        if (count > 64 or self.bit_len + count > self.bytes.len * 8) return error.NoSpace;
        const input: u64 = @intCast(value);
        const bits = if (count == 64) input else input & ((@as(u64, 1) << @intCast(count)) - 1);
        self.reservoir = (self.reservoir << @intCast(count)) | bits;
        self.reservoir_bits += @intCast(count);
        self.bit_len += count;
        while (self.reservoir_bits >= 8) {
            const remaining = self.reservoir_bits - 8;
            self.bytes[self.byte_position] = @truncate(self.reservoir >> @intCast(remaining));
            self.byte_position += 1;
            self.reservoir = if (remaining == 0)
                0
            else
                self.reservoir & ((@as(u128, 1) << @intCast(remaining)) - 1);
            self.reservoir_bits = remaining;
        }
    }

    fn byteLen(self: *BitWriter) usize {
        if (self.reservoir_bits > 0)
            self.bytes[self.byte_position] = @truncate(
                self.reservoir << @intCast(8 - self.reservoir_bits),
            );
        return self.byte_position + @intFromBool(self.reservoir_bits > 0);
    }
};

const BitReader = struct {
    bytes: []const u8,
    byte_position: usize = 0,
    reservoir: u128 = 0,
    reservoir_bits: u8 = 0,

    inline fn read(self: *BitReader, count: u7) !u64 {
        if (count > 64) return error.InvalidDatabase;
        while (self.reservoir_bits < count) {
            if (self.byte_position >= self.bytes.len) return error.InvalidDatabase;
            self.reservoir = (self.reservoir << 8) | self.bytes[self.byte_position];
            self.byte_position += 1;
            self.reservoir_bits += 8;
        }
        const remaining: u7 = @intCast(self.reservoir_bits - count);
        const value: u64 = @truncate(self.reservoir >> remaining);
        self.reservoir = if (remaining == 0)
            0
        else
            self.reservoir & ((@as(u128, 1) << remaining) - 1);
        self.reservoir_bits = remaining;
        return if (count == 64) value else value & ((@as(u64, 1) << @intCast(count)) - 1);
    }
};

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
    try validateHeader(file, physical_size);
    if (physical_size == file_header.len) return error.NoCheckpoint;

    var catalog = try loadLatestCatalog(ReaderSeries, file, physical_size, allocator);
    defer deinitSeries(ReaderSeries, allocator, &catalog.series);
    const footer_end = std.math.add(u64, catalog.latest.offset, catalog.latest.size) catch
        return error.InvalidDatabase;
    const committed_end = std.math.add(u64, footer_end, trailer_size) catch
        return error.InvalidDatabase;
    if (committed_end > physical_size) return error.InvalidDatabase;

    var intervals: std.ArrayList(VerifyInterval) = .empty;
    defer intervals.deinit(allocator);
    try verifyFooterChain(file, catalog.latest, allocator, &intervals);

    var report = VerificationReport{
        .checkpoint = try countCheckpoints(file, catalog.latest, allocator),
        .series_count = catalog.series.items.len,
        .record_count = 0,
        .block_count = 0,
        .compressed_blocks = 0,
        .logical_size = 0,
        .physical_size = physical_size,
        .trailing_bytes = physical_size - committed_end,
        .oldest_timestamp = null,
        .newest_timestamp = null,
    };

    try verifyCatalogBlocks(
        file,
        allocator,
        catalog.series.items,
        catalog.latest.offset,
        &intervals,
        &report,
    );

    std.sort.heap(VerifyInterval, intervals.items, {}, struct {
        fn lessThan(_: void, a: VerifyInterval, b: VerifyInterval) bool {
            return a.start < b.start;
        }
    }.lessThan);
    for (intervals.items, 0..) |interval, i| {
        const overlaps_previous = i > 0 and
            interval.start < intervals.items[i - 1].end;
        if (interval.start >= interval.end or overlaps_previous)
            return error.OverlappingFileRegions;
    }
    return report;
}

fn verifyCatalogBlocks(
    file: std.fs.File,
    allocator: std.mem.Allocator,
    series_list: []const ReaderSeries,
    footer_offset: u64,
    intervals: *std.ArrayList(VerifyInterval),
    report: *VerificationReport,
) !void {
    var block_buffer: [block_size]u8 = undefined;
    for (series_list) |series| {
        var previous_timestamp: ?i64 = null;
        for (series.blocks.items) |index| {
            const block_end = std.math.add(u64, index.offset, index.stored_size) catch
                return error.InvalidDatabase;
            if (index.offset < file_header.len or block_end > footer_offset or
                index.stored_size > block_size)
                return error.InvalidDatabase;
            try intervals.append(allocator, .{ .start = index.offset, .end = block_end });
            const bytes_read = try file.preadAll(
                block_buffer[0..index.stored_size],
                index.offset,
            );
            if (bytes_read != index.stored_size) return error.InvalidDatabase;
            const block_bytes = block_buffer[0..index.stored_size];
            const header = try decodeAndValidateBlock(block_bytes, series.id, index);
            const payload = block_bytes[block_header_size..];
            if (checksum(payload) != header.checksum) return error.ChecksumMismatch;
            try verifyBlockPayload(header, payload, &previous_timestamp);

            report.record_count += header.record_count;
            report.block_count += 1;
            if (header.codec == .compressed) report.compressed_blocks += 1;
            if (report.oldest_timestamp == null or header.min_timestamp < report.oldest_timestamp.?)
                report.oldest_timestamp = header.min_timestamp;
            if (report.newest_timestamp == null or header.max_timestamp > report.newest_timestamp.?)
                report.newest_timestamp = header.max_timestamp;
        }
    }
    report.logical_size = report.record_count * record_size;
}

fn verifyFooterChain(
    file: std.fs.File,
    latest: FooterPointer,
    allocator: std.mem.Allocator,
    intervals: *std.ArrayList(VerifyInterval),
) !void {
    var current = latest;
    var footer_buffer: [block_size]u8 = undefined;
    var depth: usize = 0;
    while (true) {
        if (depth >= snapshot_interval) return error.InvalidFooterChain;
        depth += 1;
        const trailer_offset = std.math.add(u64, current.offset, current.size) catch
            return error.InvalidFooterChain;
        var trailer: [trailer_size]u8 = undefined;
        if (try file.preadAll(&trailer, trailer_offset) != trailer.len or
            !std.mem.eql(u8, trailer[0..8], trailer_magic) or
            std.mem.readInt(u64, trailer[8..16], .little) != current.offset or
            std.mem.readInt(u64, trailer[16..24], .little) != current.size or
            std.mem.readInt(u64, trailer[24..32], .little) != current.checksum)
            return error.InvalidFooterChain;
        const region_end = std.math.add(u64, trailer_offset, trailer.len) catch
            return error.InvalidFooterChain;
        try intervals.append(allocator, .{ .start = current.offset, .end = region_end });

        var footer = try readFooter(file, allocator, current, &footer_buffer);
        const parsed = parseFooterHeader(footer.bytes) catch |err| {
            footer.deinit(allocator);
            return err;
        };
        footer.deinit(allocator);
        if (parsed.kind == .snapshot) break;
        const previous = parsed.previous orelse return error.InvalidFooterChain;
        const previous_footer_end = std.math.add(u64, previous.offset, previous.size) catch
            return error.InvalidFooterChain;
        const previous_region_end = std.math.add(u64, previous_footer_end, trailer_size) catch
            return error.InvalidFooterChain;
        if (previous.offset >= current.offset or previous_region_end > current.offset)
            return error.InvalidFooterChain;
        current = previous;
    }
}

fn countCheckpoints(file: std.fs.File, latest: FooterPointer, allocator: std.mem.Allocator) !u64 {
    var count: u64 = 0;
    const footer_end = std.math.add(u64, latest.offset, latest.size) catch
        return error.InvalidFooterChain;
    var search_end = std.math.add(u64, footer_end, trailer_size) catch
        return error.InvalidFooterChain;
    while (search_end > file_header.len) {
        const pointer = findLatestFooter(file, search_end, allocator) catch |err| switch (err) {
            error.InvalidDatabase => break,
            else => return err,
        };
        count += 1;
        if (pointer.offset <= file_header.len) break;
        search_end = pointer.offset;
    }
    return count;
}

fn verifyBlockPayload(
    header: BlockHeader,
    payload: []const u8,
    previous_series_timestamp: *?i64,
) !void {
    var first: ?i64 = null;
    var last: ?i64 = null;
    var decoded_count: usize = 0;
    if (header.codec == .raw) {
        if (payload.len != @as(usize, header.record_count) * record_size)
            return error.InvalidDatabase;
        for (0..header.record_count) |i| {
            const record = payload[i * record_size ..][0..record_size];
            const timestamp = decodeTimestamp(record);
            _ = decodeValue(record);
            try acceptVerifiedTimestamp(timestamp, &first, &last, previous_series_timestamp);
            decoded_count += 1;
        }
    } else {
        if (payload.len < 4) return error.InvalidDatabase;
        const chunk_count = std.mem.readInt(u32, payload[0..4], .little);
        const expected_chunks = chunksForRecords(header.record_count);
        if (chunk_count != expected_chunks) return error.InvalidDatabase;
        const table_size = 4 + @as(usize, chunk_count) * checkpoint_entry_size;
        if (table_size >= payload.len) return error.InvalidDatabase;
        var expected_offset = table_size;
        for (0..chunk_count) |chunk_index| {
            const entry = 4 + chunk_index * checkpoint_entry_size;
            const checkpoint_timestamp = std.mem.readInt(i64, payload[entry..][0..8], .little);
            const chunk_offset = std.mem.readInt(u32, payload[entry + 8 ..][0..4], .little);
            const chunk_end = if (chunk_index + 1 < chunk_count)
                std.mem.readInt(u32, payload[entry + checkpoint_entry_size + 8 ..][0..4], .little)
            else
                payload.len;
            if (chunk_offset != expected_offset or
                chunk_end <= chunk_offset or
                chunk_end > payload.len)
                return error.InvalidDatabase;
            expected_offset = chunk_end;
            const first_record = chunk_index * chunk_record_count;
            const records_in_chunk: u32 = @intCast(@min(
                chunk_record_count,
                @as(usize, header.record_count) - first_record,
            ));
            var decoder = try CompressedDecoder.init(
                payload[chunk_offset..chunk_end],
                records_in_chunk,
            );
            for (0..records_in_chunk) |record_index| {
                const timestamp = (try decoder.next()).timestamp;
                if (record_index == 0 and timestamp != checkpoint_timestamp)
                    return error.InvalidDatabase;
                try acceptVerifiedTimestamp(timestamp, &first, &last, previous_series_timestamp);
                decoded_count += 1;
            }
        }
    }
    if (decoded_count != header.record_count or first == null or last == null or
        first.? != header.min_timestamp or last.? != header.max_timestamp)
        return error.InvalidDatabase;
}

fn acceptVerifiedTimestamp(
    timestamp: i64,
    first: *?i64,
    last: *?i64,
    previous_series_timestamp: *?i64,
) !void {
    if (last.*) |previous| if (timestamp <= previous) return error.TimestampNotIncreasing;
    if (last.* == null) {
        if (previous_series_timestamp.*) |previous| {
            if (timestamp <= previous) return error.TimestampNotIncreasing;
        }
        first.* = timestamp;
    }
    last.* = timestamp;
    previous_series_timestamp.* = timestamp;
}

pub fn encodeRecord(timestamp: i64, value: f64) [record_size]u8 {
    var record: [record_size]u8 = undefined;
    std.mem.writeInt(i64, record[0..8], timestamp, .little);
    std.mem.writeInt(u64, record[8..16], @bitCast(value), .little);
    return record;
}

fn decodeTimestamp(record: *const [record_size]u8) i64 {
    return std.mem.readInt(i64, record[0..8], .little);
}
fn decodeValue(record: *const [record_size]u8) f64 {
    return @bitCast(std.mem.readInt(u64, record[8..16], .little));
}

fn printRecord(out: std.fs.File, timestamp: i64, value: f64) !void {
    var buffer: [128]u8 = undefined;
    try out.writeAll(try std.fmt.bufPrint(&buffer, "{d} {d}\n", .{ timestamp, value }));
}

fn encodeBlockHeader(bytes: []u8, header: BlockHeader) void {
    @memcpy(bytes[0..4], block_magic);
    bytes[4] = @intFromEnum(header.codec);
    @memset(bytes[5..8], 0);
    std.mem.writeInt(u32, bytes[8..12], header.series_id, .little);
    std.mem.writeInt(u32, bytes[12..16], header.record_count, .little);
    std.mem.writeInt(i64, bytes[16..24], header.min_timestamp, .little);
    std.mem.writeInt(i64, bytes[24..32], header.max_timestamp, .little);
    std.mem.writeInt(u32, bytes[32..36], header.payload_size, .little);
    std.mem.writeInt(u32, bytes[36..40], header.record_count * record_size, .little);
    std.mem.writeInt(u64, bytes[40..48], header.checksum, .little);
}

fn decodeBlockHeader(bytes: []const u8) !BlockHeader {
    if (!std.mem.eql(u8, bytes[0..4], block_magic)) return error.InvalidDatabase;
    const codec = std.meta.intToEnum(Codec, bytes[4]) catch return error.InvalidDatabase;
    const header = BlockHeader{
        .codec = codec,
        .series_id = std.mem.readInt(u32, bytes[8..12], .little),
        .record_count = std.mem.readInt(u32, bytes[12..16], .little),
        .min_timestamp = std.mem.readInt(i64, bytes[16..24], .little),
        .max_timestamp = std.mem.readInt(i64, bytes[24..32], .little),
        .payload_size = std.mem.readInt(u32, bytes[32..36], .little),
        .checksum = std.mem.readInt(u64, bytes[40..48], .little),
    };
    if (header.record_count == 0 or
        header.record_count > records_per_block or
        header.min_timestamp > header.max_timestamp)
        return error.InvalidDatabase;
    if (std.mem.readInt(u32, bytes[36..40], .little) != header.record_count * record_size)
        return error.InvalidDatabase;
    return header;
}

const FooterWrite = struct {
    pointer: FooterPointer,
    end_offset: u64,
};

const FooterPlan = struct {
    entry_count: u32,
    size_bytes: usize,
};

fn planFooter(series_list: []const WriterSeries, kind: FooterKind) !FooterPlan {
    var entry_count: u32 = 0;
    var size_bytes: usize = 40;
    for (series_list) |series| {
        const unchanged_delta = kind == .delta and series.known_to_footer and
            series.blocks.items.len == series.checkpointed_blocks;
        if (unchanged_delta) continue;
        entry_count = try std.math.add(u32, entry_count, 1);
        const include_name = kind == .snapshot or !series.known_to_footer;
        const block_start = if (kind == .snapshot or !series.known_to_footer)
            0
        else
            series.checkpointed_blocks;
        const block_count = series.blocks.items.len - block_start;
        if (block_count > std.math.maxInt(u32)) return error.DatabaseTooLarge;
        size_bytes = try std.math.add(usize, size_bytes, footer_series_entry_size);
        if (include_name) size_bytes = try std.math.add(usize, size_bytes, series.name.len);
        const blocks_size = try std.math.mul(usize, block_count, footer_block_entry_size);
        size_bytes = try std.math.add(usize, size_bytes, blocks_size);
    }
    return .{ .entry_count = entry_count, .size_bytes = size_bytes };
}

fn writeFooter(
    file: anytype,
    offset: u64,
    allocator: std.mem.Allocator,
    series_list: []const WriterSeries,
    kind: FooterKind,
    previous: ?FooterPointer,
    footer: *std.ArrayList(u8),
) !FooterWrite {
    const plan = try planFooter(series_list, kind);
    footer.clearRetainingCapacity();
    try footer.ensureTotalCapacity(allocator, plan.size_bytes);
    try footer.appendSlice(allocator, footer_magic);
    try footer.append(allocator, @intFromEnum(kind));
    try footer.appendSlice(allocator, &[_]u8{ 0, 0, 0 });
    const previous_pointer = if (kind == .delta)
        previous orelse return error.InvalidDatabase
    else
        FooterPointer{ .offset = 0, .size = 0, .checksum = 0 };
    try appendInt(u64, footer, allocator, previous_pointer.offset);
    try appendInt(u64, footer, allocator, previous_pointer.size);
    try appendInt(u64, footer, allocator, previous_pointer.checksum);

    try appendInt(u32, footer, allocator, plan.entry_count);

    for (series_list) |series| {
        const unchanged_delta = kind == .delta and
            series.known_to_footer and
            series.blocks.items.len == series.checkpointed_blocks;
        if (unchanged_delta) continue;
        const include_name = kind == .snapshot or !series.known_to_footer;
        const block_start: usize = if (kind == .snapshot or !series.known_to_footer)
            0
        else
            series.checkpointed_blocks;
        try appendInt(u32, footer, allocator, series.id);
        try footer.append(allocator, if (include_name) 1 else 0);
        try appendInt(u16, footer, allocator, if (include_name) @intCast(series.name.len) else 0);
        const block_count = series.blocks.items.len - block_start;
        std.debug.assert(block_count <= std.math.maxInt(u32));
        try appendInt(u32, footer, allocator, @intCast(block_count));
        if (include_name) try footer.appendSlice(allocator, series.name);
        for (series.blocks.items[block_start..]) |block| {
            try appendInt(u64, footer, allocator, block.offset);
            try appendInt(i64, footer, allocator, block.min_timestamp);
            try appendInt(i64, footer, allocator, block.max_timestamp);
            try appendInt(u32, footer, allocator, block.record_count);
            try appendInt(u32, footer, allocator, block.stored_size);
            try footer.append(allocator, @intFromEnum(block.codec));
        }
    }

    std.debug.assert(footer.items.len == plan.size_bytes);
    const footer_checksum = checksum(footer.items);
    try file.pwriteAll(footer.items, offset);
    var trailer: [trailer_size]u8 = undefined;
    @memcpy(trailer[0..8], trailer_magic);
    std.mem.writeInt(u64, trailer[8..16], offset, .little);
    std.mem.writeInt(u64, trailer[16..24], footer.items.len, .little);
    std.mem.writeInt(u64, trailer[24..32], footer_checksum, .little);
    const trailer_offset = try std.math.add(u64, offset, footer.items.len);
    try file.pwriteAll(&trailer, trailer_offset);
    return .{
        .pointer = .{ .offset = offset, .size = footer.items.len, .checksum = footer_checksum },
        .end_offset = try std.math.add(u64, trailer_offset, trailer.len),
    };
}

fn sameFooter(a: FooterPointer, b: FooterPointer) bool {
    return a.offset == b.offset and a.size == b.size and a.checksum == b.checksum;
}

fn footerEndsAt(pointer: FooterPointer, expected_end: u64) bool {
    const actual_end = std.math.add(u64, pointer.offset, pointer.size) catch return false;
    return actual_end == expected_end;
}

fn preserveVerifiedBlocks(old_series: []ReaderSeries, new_series: []ReaderSeries) void {
    for (new_series) |*new| {
        var old_match: ?*ReaderSeries = null;
        for (old_series) |*old| {
            if (old.id == new.id) {
                old_match = old;
                break;
            }
        }
        if (old_match) |old| {
            std.debug.assert(old.blocks.items.len == old.verifications.items.len);
            std.debug.assert(new.blocks.items.len == new.verifications.items.len);
            const common = @min(old.blocks.items.len, new.blocks.items.len);
            for (0..common) |i| {
                const old_block = old.blocks.items[i];
                const new_block = new.blocks.items[i];
                const identity_changed = old_block.offset != new_block.offset or
                    old_block.stored_size != new_block.stored_size or
                    old_block.codec != new_block.codec or
                    old_block.record_count != new_block.record_count or
                    old_block.min_timestamp != new_block.min_timestamp or
                    old_block.max_timestamp != new_block.max_timestamp;
                if (identity_changed) break;
                new.verifications.items[i] = old.verifications.items[i];
                old.verifications.items[i].cached = null;
                old.verifications.items[i].state = .unverified;
            }
        }
    }
}

fn readFooterPointerAt(
    file: anytype,
    file_size: u64,
    trailer_offset: u64,
) !?FooterPointer {
    if (trailer_offset > file_size -| trailer_size) return null;
    var trailer: [trailer_size]u8 = undefined;
    if (try file.preadAll(&trailer, trailer_offset) != trailer_size)
        return error.InvalidDatabase;
    if (!std.mem.eql(u8, trailer[0..8], trailer_magic)) return null;
    const pointer = FooterPointer{
        .offset = std.mem.readInt(u64, trailer[8..16], .little),
        .size = std.mem.readInt(u64, trailer[16..24], .little),
        .checksum = std.mem.readInt(u64, trailer[24..32], .little),
    };
    if (pointer.offset < file_header.len or
        pointer.size < 40 or
        pointer.size > std.math.maxInt(usize) or
        !footerEndsAt(pointer, trailer_offset)) return null;
    return pointer;
}

fn findLatestFooter(file: anytype, file_size: u64, allocator: std.mem.Allocator) !FooterPointer {
    var search_end = file_size;
    var search_buffer: [block_size]u8 = undefined;
    var footer_buffer: [block_size]u8 = undefined;
    while (search_end > file_header.len) {
        const start = if (search_end > file_header.len + block_size)
            search_end - block_size
        else
            file_header.len;
        const len: usize = @intCast(search_end - start);
        if (try file.preadAll(search_buffer[0..len], start) != len)
            return error.InvalidDatabase;
        var position = len -| trailer_magic.len;
        while (true) {
            const magic_fits = position + trailer_magic.len <= len;
            if (magic_fits and
                std.mem.eql(u8, search_buffer[position..][0..trailer_magic.len], trailer_magic))
            {
                const trailer_offset = start + position;
                if (try readFooterPointerAt(file, file_size, trailer_offset)) |pointer| {
                    var footer = readFooter(
                        file,
                        allocator,
                        pointer,
                        &footer_buffer,
                    ) catch null;
                    if (footer) |*valid_footer| {
                        const valid_header = parseFooterHeader(valid_footer.bytes) catch null;
                        valid_footer.deinit(allocator);
                        if (valid_header != null) return pointer;
                    }
                }
            }
            if (position == 0) break;
            position -= 1;
        }
        if (start == file_header.len) break;
        search_end = start + trailer_magic.len - 1;
    }
    return error.InvalidDatabase;
}

fn loadLatestCatalog(
    comptime SeriesType: type,
    file: anytype,
    file_size: u64,
    allocator: std.mem.Allocator,
) !CatalogLoadFor(SeriesType) {
    var search_end = file_size;
    var buffer: [block_size]u8 = undefined;
    while (search_end > file_header.len) {
        const start = if (search_end > file_header.len + block_size)
            search_end - block_size
        else
            file_header.len;
        const len: usize = @intCast(search_end - start);
        if (try file.preadAll(buffer[0..len], start) != len)
            return error.InvalidDatabase;
        var position = len -| trailer_magic.len;
        while (true) {
            const magic_fits = position + trailer_magic.len <= len;
            if (magic_fits and
                std.mem.eql(u8, buffer[position..][0..trailer_magic.len], trailer_magic))
            {
                const trailer_offset = start + position;
                if (try readFooterPointerAt(file, file_size, trailer_offset)) |pointer| {
                    const catalog = reconstructCatalog(
                        SeriesType,
                        file,
                        allocator,
                        pointer,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            if (position == 0) break;
                            position -= 1;
                            continue;
                        },
                    };
                    return catalog;
                }
            }
            if (position == 0) break;
            position -= 1;
        }
        if (start == file_header.len) break;
        search_end = start + trailer_magic.len - 1;
    }
    return error.InvalidDatabase;
}

fn reconstructCatalog(
    comptime SeriesType: type,
    file: anytype,
    allocator: std.mem.Allocator,
    latest: FooterPointer,
) !CatalogLoadFor(SeriesType) {
    var chain: [snapshot_interval]FooterPointer = undefined;
    var chain_count: u8 = 0;
    var footer_buffer: [block_size]u8 = undefined;
    var current = latest;
    while (true) {
        if (chain_count >= snapshot_interval) return error.InvalidDatabase;
        chain[chain_count] = current;
        chain_count += 1;
        var footer = try readFooter(file, allocator, current, &footer_buffer);
        const header = parseFooterHeader(footer.bytes) catch |err| {
            footer.deinit(allocator);
            return err;
        };
        footer.deinit(allocator);
        if (header.kind == .snapshot) break;
        current = header.previous orelse return error.InvalidDatabase;
    }

    var series_list: std.ArrayList(SeriesType) = .empty;
    errdefer deinitSeries(SeriesType, allocator, &series_list);
    var index = chain_count;
    while (index > 0) {
        index -= 1;
        var footer = try readFooter(file, allocator, chain[index], &footer_buffer);
        applyFooter(SeriesType, allocator, footer.bytes, &series_list) catch |err| {
            footer.deinit(allocator);
            return err;
        };
        footer.deinit(allocator);
    }
    for (series_list.items) |*series| {
        if (comptime SeriesType == WriterSeries) {
            series.checkpointed_blocks = series.blocks.items.len;
            series.known_to_footer = true;
        } else {
            series.block_search_stride = deriveBlockSearchStride(series.blocks.items);
        }
        if (series.blocks.items.len > 0)
            series.last_timestamp = series.blocks.items[series.blocks.items.len - 1].max_timestamp;
    }
    return .{
        .series = series_list,
        .latest = latest,
        .deltas_since_snapshot = chain_count - 1,
    };
}

const ParsedFooterHeader = struct {
    kind: FooterKind,
    previous: ?FooterPointer,
    entry_count: u32,
    entries_offset: usize,
};

const FooterBytes = struct {
    bytes: []u8,
    owned: bool,

    fn deinit(self: *FooterBytes, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.bytes);
    }
};

fn readFooter(
    file: anytype,
    allocator: std.mem.Allocator,
    pointer: FooterPointer,
    buffer: []u8,
) !FooterBytes {
    if (pointer.size > std.math.maxInt(usize)) return error.InvalidDatabase;
    const size: usize = @intCast(pointer.size);
    const owned = size > buffer.len;
    const bytes = if (owned) try allocator.alloc(u8, size) else buffer[0..size];
    errdefer if (owned) allocator.free(bytes);
    const bytes_read = try file.preadAll(bytes, pointer.offset);
    if (bytes_read != bytes.len or checksum(bytes) != pointer.checksum)
        return error.InvalidDatabase;
    return .{ .bytes = bytes, .owned = owned };
}

fn parseFooterHeader(bytes: []const u8) !ParsedFooterHeader {
    if (bytes.len < 40 or
        !std.mem.eql(u8, bytes[0..footer_magic.len], footer_magic))
        return error.InvalidDatabase;
    const kind = std.meta.intToEnum(FooterKind, bytes[8]) catch return error.InvalidDatabase;
    var cursor: usize = 12;
    const previous = FooterPointer{
        .offset = try takeInt(u64, bytes, &cursor),
        .size = try takeInt(u64, bytes, &cursor),
        .checksum = try takeInt(u64, bytes, &cursor),
    };
    const entry_count = try takeInt(u32, bytes, &cursor);
    if (kind == .snapshot and
        (previous.offset != 0 or previous.size != 0 or previous.checksum != 0))
        return error.InvalidDatabase;
    return .{
        .kind = kind,
        .previous = if (kind == .delta) previous else null,
        .entry_count = entry_count,
        .entries_offset = cursor,
    };
}

fn applyFooter(
    comptime SeriesType: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    list: *std.ArrayList(SeriesType),
) !void {
    const header = try parseFooterHeader(bytes);
    if (header.kind == .snapshot and list.items.len != 0) return error.InvalidDatabase;
    if (header.entry_count > @divFloor(
        bytes.len - header.entries_offset,
        footer_series_entry_size,
    ))
        return error.InvalidDatabase;
    try list.ensureUnusedCapacity(allocator, header.entry_count);
    var cursor = header.entries_offset;
    for (0..header.entry_count) |_| {
        const id = try takeInt(u32, bytes, &cursor);
        const include_name = try takeInt(u8, bytes, &cursor);
        const name_len = try takeInt(u16, bytes, &cursor);
        const block_count = try takeInt(u32, bytes, &cursor);
        const name_end = std.math.add(usize, cursor, name_len) catch return error.InvalidDatabase;
        if (include_name > 1 or (include_name == 0 and name_len != 0) or name_end > bytes.len)
            return error.InvalidDatabase;
        var series: *SeriesType = undefined;
        if (include_name == 1) {
            if (name_len == 0) return error.InvalidDatabase;
            for (list.items) |existing| {
                if (existing.id == id or
                    std.mem.eql(u8, existing.name, bytes[cursor..name_end]))
                    return error.InvalidDatabase;
            }
            const name = try allocator.dupe(u8, bytes[cursor..name_end]);
            errdefer allocator.free(name);
            if (comptime SeriesType == WriterSeries) {
                const block_buffer = try allocator.create([block_size]u8);
                errdefer allocator.destroy(block_buffer);
                try list.append(allocator, .{
                    .id = id,
                    .name = name,
                    .block_buffer = block_buffer,
                });
            } else {
                try list.append(allocator, .{ .id = id, .name = name });
            }
            series = &list.items[list.items.len - 1];
        } else {
            series = findSeriesById(SeriesType, list.items, id) orelse return error.InvalidDatabase;
        }
        cursor = name_end;
        if (block_count > @divFloor(bytes.len - cursor, footer_block_entry_size))
            return error.InvalidDatabase;
        try series.blocks.ensureUnusedCapacity(allocator, block_count);
        if (comptime SeriesType == ReaderSeries)
            try series.verifications.ensureUnusedCapacity(allocator, block_count);
        for (0..block_count) |_| {
            const block = try takeBlockIndex(bytes, &cursor);
            if (series.blocks.items.len > 0) {
                const previous = series.blocks.items[series.blocks.items.len - 1];
                if (block.min_timestamp <= previous.max_timestamp)
                    return error.InvalidDatabase;
            }
            series.blocks.appendAssumeCapacity(block);
            if (comptime SeriesType == ReaderSeries)
                series.verifications.appendAssumeCapacity(.{});
        }
        if (comptime SeriesType == ReaderSeries)
            std.debug.assert(series.blocks.items.len == series.verifications.items.len);
    }
    if (cursor != bytes.len) return error.InvalidDatabase;
}

fn takeBlockIndex(bytes: []const u8, cursor: *usize) !BlockIndex {
    const block = BlockIndex{
        .offset = try takeInt(u64, bytes, cursor),
        .min_timestamp = try takeInt(i64, bytes, cursor),
        .max_timestamp = try takeInt(i64, bytes, cursor),
        .record_count = try takeInt(u32, bytes, cursor),
        .stored_size = try takeInt(u32, bytes, cursor),
        .codec = std.meta.intToEnum(
            Codec,
            try takeInt(u8, bytes, cursor),
        ) catch return error.InvalidDatabase,
    };
    if (block.offset < file_header.len or
        block.record_count == 0 or
        block.record_count > records_per_block or
        block.stored_size < block_header_size or
        block.stored_size > block_size or
        block.min_timestamp > block.max_timestamp)
        return error.InvalidDatabase;
    return block;
}

fn findSeriesById(comptime SeriesType: type, series_list: []SeriesType, id: u32) ?*SeriesType {
    for (series_list) |*series| if (series.id == id) return series;
    return null;
}

fn appendInt(
    comptime T: type,
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: T,
) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}
fn takeInt(comptime T: type, bytes: []const u8, cursor: *usize) !T {
    const value_end = std.math.add(usize, cursor.*, @sizeOf(T)) catch
        return error.InvalidDatabase;
    if (value_end > bytes.len) return error.InvalidDatabase;
    const value = std.mem.readInt(T, bytes[cursor.*..][0..@sizeOf(T)], .little);
    cursor.* = value_end;
    return value;
}
fn writeVarint(output: []u8, input: u64) ?usize {
    var value = input;
    var index: usize = 0;
    while (true) {
        if (index == output.len) return null;
        output[index] = @intCast(value & 0x7f);
        value >>= 7;
        if (value == 0) return index + 1;
        output[index] |= 0x80;
        index += 1;
    }
}
fn readVarint(input: []const u8, cursor: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    for (0..10) |_| {
        if (cursor.* >= input.len) return error.InvalidDatabase;
        const byte = input[cursor.*];
        cursor.* += 1;
        if (shift == 63 and byte > 1) return error.InvalidDatabase;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
    }
    return error.InvalidDatabase;
}
fn zigzagEncode(value: i64) u64 {
    return @as(u64, @bitCast(value)) << 1 ^ @as(u64, @bitCast(value >> 63));
}
fn zigzagDecode(value: u64) i64 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}
fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}
fn validateHeader(file: anytype, size: u64) !void {
    if (size < file_header.len) return error.InvalidDatabase;
    var found: [file_header.len]u8 = undefined;
    if (try file.preadAll(&found, 0) != file_header.len or
        !std.mem.eql(u8, &found, &file_header))
        return error.InvalidDatabase;
}
fn deinitSeries(
    comptime SeriesType: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(SeriesType),
) void {
    for (list.items) |*series| {
        allocator.free(series.name);
        if (comptime SeriesType == ReaderSeries) {
            std.debug.assert(series.blocks.items.len == series.verifications.items.len);
            for (series.verifications.items, series.blocks.items) |verification, block|
                if (verification.cached) |cached| allocator.free(cached[0..block.stored_size]);
            series.verifications.deinit(allocator);
        } else {
            allocator.destroy(series.block_buffer);
        }
        series.blocks.deinit(allocator);
    }
    list.deinit(allocator);
}
fn usage() error{InvalidArguments} {
    std.fs.File.stderr().writeAll(
        "usage: chronotail append  <file.ctdb> <series> <timestamp> <value> [raw|compressed]\n" ++
            "       chronotail range   <file.ctdb> <series> <start> <end>\n" ++
            "       chronotail verify  <file.ctdb>\n" ++
            "       chronotail inspect <file.ctdb>\n",
    ) catch {};
    return error.InvalidArguments;
}
