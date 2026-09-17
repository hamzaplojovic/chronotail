//! Read-only format-v6 support used exclusively by the explicit migration tool.
//! Production v7 reads never dispatch through this module.
const std = @import("std");
const engine = @import("engine.zig");

const file_header = "CTDB\x06";
const block_magic = "CTBK";
const footer_magic = "CTIDX006";
const trailer_magic = "CTTRL006";
const block_size: usize = 64 * 1024;
const block_header_size: usize = 48;
const record_size: usize = 16;
const records_per_block: usize = (block_size - block_header_size) / record_size;
const trailer_size: usize = 32;
const footer_chain_max: usize = 64;
const footer_size_max: usize = 256 * 1024 * 1024;
const chunk_record_count: usize = 128;
const checkpoint_entry_size: usize = 12;
const footer_series_entry_size: usize = 11;
const footer_block_entry_size: usize = 33;

const Codec = enum(u8) { raw = 0, compressed = 1 };
const FooterKind = enum(u8) { snapshot = 0, delta = 1 };

const FooterPointer = struct {
    offset: u64,
    size: u64,
    checksum: u64,
};

const Block = struct {
    offset: u64,
    timestamp_min: i64,
    timestamp_max: i64,
    record_count: u32,
    stored_size: u32,
    codec: Codec,
};

const Series = struct {
    id: u32,
    name: []u8,
    blocks: std.ArrayList(Block) = .empty,

    fn deinit(self: *Series, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.blocks.deinit(allocator);
    }
};

const Catalog = struct {
    series: std.ArrayList(Series) = .empty,

    fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.series.items) |*series| series.deinit(allocator);
        self.series.deinit(allocator);
    }
};

const ParsedFooterHeader = struct {
    kind: FooterKind,
    previous: ?FooterPointer,
    entry_count: u32,
    entries_offset: usize,
};

const BlockHeader = struct {
    series_id: u32,
    codec: Codec,
    timestamp_min: i64,
    timestamp_max: i64,
    record_count: u32,
    payload_size: u32,
    checksum: u64,
};

pub fn migrate(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    target_path: []const u8,
    codec: engine.Codec,
    durability: engine.Durability,
) !void {
    if (std.mem.eql(u8, source_path, target_path)) return error.InvalidArguments;
    const source = try std.fs.cwd().openFile(source_path, .{});
    defer source.close();
    const physical_size = try source.getEndPos();
    try validateHeader(source, physical_size);

    var catalog = if (physical_size == file_header.len)
        Catalog{}
    else
        try loadCatalog(allocator, source, physical_size);
    defer catalog.deinit(allocator);

    var target = try engine.Appender.create(allocator, target_path, codec);
    var target_open = true;
    errdefer if (target_open) {
        target.abort();
        std.fs.cwd().deleteFile(target_path) catch {};
    };

    var timestamps: [records_per_block]i64 = undefined;
    var values: [records_per_block]f64 = undefined;
    var block_bytes: [block_size]u8 = undefined;
    for (catalog.series.items) |series| {
        try target.prepareSeries(series.name, records_per_block);
        for (series.blocks.items) |block| {
            const count = try decodeBlock(
                source,
                physical_size,
                series.id,
                block,
                &block_bytes,
                &timestamps,
                &values,
            );
            try target.appendBatch(series.name, timestamps[0..count], values[0..count]);
        }
    }
    try target.checkpointWithDurability(durability);
    target_open = false;
    try target.close();
}

fn validateHeader(file: std.fs.File, physical_size: u64) !void {
    if (physical_size < file_header.len) return error.InvalidV6Database;
    var bytes: [file_header.len]u8 = undefined;
    if (try file.preadAll(&bytes, 0) != bytes.len or
        !std.mem.eql(u8, &bytes, file_header)) return error.InvalidV6Database;
}

fn loadCatalog(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    physical_size: u64,
) !Catalog {
    const latest = try findLatestFooter(allocator, file, physical_size);
    var chain: [footer_chain_max]FooterPointer = undefined;
    var chain_count: usize = 0;
    var current = latest;
    while (true) {
        if (chain_count == chain.len) return error.InvalidV6Database;
        chain[chain_count] = current;
        chain_count += 1;
        const bytes = try readFooter(allocator, file, physical_size, current);
        defer allocator.free(bytes);
        const header = try parseFooterHeader(bytes);
        if (header.kind == .snapshot) break;
        current = header.previous orelse return error.InvalidV6Database;
    }

    var result = Catalog{};
    errdefer result.deinit(allocator);
    var chain_index = chain_count;
    while (chain_index > 0) {
        chain_index -= 1;
        const bytes = try readFooter(allocator, file, physical_size, chain[chain_index]);
        defer allocator.free(bytes);
        try applyFooter(allocator, bytes, physical_size, &result);
    }
    return result;
}

fn findLatestFooter(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    physical_size: u64,
) !FooterPointer {
    var search_end = physical_size;
    var search_buffer: [block_size]u8 = undefined;
    while (search_end > file_header.len) {
        const start = if (search_end > file_header.len + block_size)
            search_end - block_size
        else
            file_header.len;
        const length: usize = @intCast(search_end - start);
        if (try file.preadAll(search_buffer[0..length], start) != length)
            return error.InvalidV6Database;
        var position = length -| trailer_magic.len;
        while (true) {
            if (position + trailer_magic.len <= length and
                std.mem.eql(u8, search_buffer[position..][0..trailer_magic.len], trailer_magic))
            {
                const trailer_offset = start + position;
                if (try readFooterPointerAt(file, physical_size, trailer_offset)) |pointer| {
                    const bytes = readFooter(
                        allocator,
                        file,
                        physical_size,
                        pointer,
                    ) catch null;
                    if (bytes) |footer_bytes| {
                        defer allocator.free(footer_bytes);
                        if (parseFooterHeader(footer_bytes)) |_| return pointer else |_| {}
                    }
                }
            }
            if (position == 0) break;
            position -= 1;
        }
        if (start == file_header.len) break;
        search_end = start + trailer_magic.len - 1;
    }
    return error.InvalidV6Database;
}

fn readFooterPointerAt(
    file: std.fs.File,
    physical_size: u64,
    trailer_offset: u64,
) !?FooterPointer {
    if (trailer_offset > physical_size -| trailer_size) return null;
    var trailer: [trailer_size]u8 = undefined;
    if (try file.preadAll(&trailer, trailer_offset) != trailer.len)
        return error.InvalidV6Database;
    if (!std.mem.eql(u8, trailer[0..8], trailer_magic)) return null;
    const pointer = FooterPointer{
        .offset = std.mem.readInt(u64, trailer[8..16], .little),
        .size = std.mem.readInt(u64, trailer[16..24], .little),
        .checksum = std.mem.readInt(u64, trailer[24..32], .little),
    };
    const footer_end = std.math.add(u64, pointer.offset, pointer.size) catch return null;
    if (pointer.offset < file_header.len or pointer.size < 40 or
        pointer.size > footer_size_max or footer_end != trailer_offset) return null;
    return pointer;
}

fn readFooter(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    physical_size: u64,
    pointer: FooterPointer,
) ![]u8 {
    if (pointer.size < 40 or pointer.size > footer_size_max)
        return error.InvalidV6Database;
    const end = std.math.add(u64, pointer.offset, pointer.size) catch
        return error.InvalidV6Database;
    if (pointer.offset < file_header.len or end > physical_size)
        return error.InvalidV6Database;
    const size: usize = @intCast(pointer.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    if (try file.preadAll(bytes, pointer.offset) != bytes.len or
        checksum(bytes) != pointer.checksum) return error.InvalidV6Database;
    return bytes;
}

fn parseFooterHeader(bytes: []const u8) !ParsedFooterHeader {
    if (bytes.len < 40 or !std.mem.eql(u8, bytes[0..8], footer_magic))
        return error.InvalidV6Database;
    if (bytes[9] != 0 or bytes[10] != 0 or bytes[11] != 0)
        return error.InvalidV6Database;
    const kind = std.meta.intToEnum(FooterKind, bytes[8]) catch
        return error.InvalidV6Database;
    var cursor: usize = 12;
    const previous = FooterPointer{
        .offset = try takeInt(u64, bytes, &cursor),
        .size = try takeInt(u64, bytes, &cursor),
        .checksum = try takeInt(u64, bytes, &cursor),
    };
    const entry_count = try takeInt(u32, bytes, &cursor);
    if (kind == .snapshot and
        (previous.offset != 0 or previous.size != 0 or previous.checksum != 0))
        return error.InvalidV6Database;
    return .{
        .kind = kind,
        .previous = if (kind == .delta) previous else null,
        .entry_count = entry_count,
        .entries_offset = cursor,
    };
}

fn applyFooter(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    physical_size: u64,
    catalog: *Catalog,
) !void {
    const header = try parseFooterHeader(bytes);
    if (header.kind == .snapshot and catalog.series.items.len != 0)
        return error.InvalidV6Database;
    if (header.entry_count > (bytes.len - header.entries_offset) / footer_series_entry_size)
        return error.InvalidV6Database;
    try catalog.series.ensureUnusedCapacity(allocator, header.entry_count);
    var cursor = header.entries_offset;
    for (0..header.entry_count) |_| {
        const id = try takeInt(u32, bytes, &cursor);
        const include_name = try takeInt(u8, bytes, &cursor);
        const name_length = try takeInt(u16, bytes, &cursor);
        const block_count = try takeInt(u32, bytes, &cursor);
        const name_end = std.math.add(usize, cursor, name_length) catch
            return error.InvalidV6Database;
        if (include_name > 1 or (include_name == 0 and name_length != 0) or
            name_end > bytes.len) return error.InvalidV6Database;
        var series: *Series = undefined;
        if (include_name == 1) {
            if (name_length == 0) return error.InvalidV6Database;
            for (catalog.series.items) |existing| {
                if (existing.id == id or std.mem.eql(u8, existing.name, bytes[cursor..name_end]))
                    return error.InvalidV6Database;
            }
            const name = try allocator.dupe(u8, bytes[cursor..name_end]);
            errdefer allocator.free(name);
            catalog.series.appendAssumeCapacity(.{ .id = id, .name = name });
            series = &catalog.series.items[catalog.series.items.len - 1];
        } else {
            series = findSeries(catalog.series.items, id) orelse
                return error.InvalidV6Database;
        }
        cursor = name_end;
        if (block_count > (bytes.len - cursor) / footer_block_entry_size)
            return error.InvalidV6Database;
        try series.blocks.ensureUnusedCapacity(allocator, block_count);
        for (0..block_count) |_| {
            const block = try takeBlock(bytes, &cursor, physical_size);
            if (series.blocks.items.len > 0 and
                block.timestamp_min <= series.blocks.items[series.blocks.items.len - 1].timestamp_max)
                return error.InvalidV6Database;
            series.blocks.appendAssumeCapacity(block);
        }
    }
    if (cursor != bytes.len) return error.InvalidV6Database;
}

fn findSeries(series_list: []Series, id: u32) ?*Series {
    for (series_list) |*series| if (series.id == id) return series;
    return null;
}

fn takeBlock(bytes: []const u8, cursor: *usize, physical_size: u64) !Block {
    const block = Block{
        .offset = try takeInt(u64, bytes, cursor),
        .timestamp_min = try takeInt(i64, bytes, cursor),
        .timestamp_max = try takeInt(i64, bytes, cursor),
        .record_count = try takeInt(u32, bytes, cursor),
        .stored_size = try takeInt(u32, bytes, cursor),
        .codec = std.meta.intToEnum(Codec, try takeInt(u8, bytes, cursor)) catch
            return error.InvalidV6Database,
    };
    const end = std.math.add(u64, block.offset, block.stored_size) catch
        return error.InvalidV6Database;
    if (block.offset < file_header.len or block.record_count == 0 or
        block.record_count > records_per_block or block.stored_size < block_header_size or
        block.stored_size > block_size or block.timestamp_min > block.timestamp_max or
        end > physical_size) return error.InvalidV6Database;
    return block;
}

fn decodeBlock(
    file: std.fs.File,
    physical_size: u64,
    series_id: u32,
    block: Block,
    scratch: *[block_size]u8,
    timestamps: *[records_per_block]i64,
    values: *[records_per_block]f64,
) !usize {
    const end = std.math.add(u64, block.offset, block.stored_size) catch
        return error.InvalidV6Database;
    if (end > physical_size) return error.InvalidV6Database;
    const size: usize = block.stored_size;
    if (try file.preadAll(scratch[0..size], block.offset) != size)
        return error.InvalidV6Database;
    const header = try decodeBlockHeader(scratch[0..block_header_size]);
    if (header.series_id != series_id or header.codec != block.codec or
        header.timestamp_min != block.timestamp_min or
        header.timestamp_max != block.timestamp_max or
        header.record_count != block.record_count or
        block_header_size + header.payload_size != block.stored_size)
        return error.InvalidV6Database;
    const payload = scratch[block_header_size..size];
    if (checksum(payload) != header.checksum) return error.V6ChecksumMismatch;
    const count: usize = header.record_count;
    switch (header.codec) {
        .raw => try decodeRaw(header, payload, timestamps[0..count], values[0..count]),
        .compressed => try decodeCompressed(
            header,
            payload,
            timestamps[0..count],
            values[0..count],
        ),
    }
    return count;
}

fn decodeBlockHeader(bytes: *const [block_header_size]u8) !BlockHeader {
    if (!std.mem.eql(u8, bytes[0..4], block_magic)) return error.InvalidV6Database;
    if (bytes[5] != 0 or bytes[6] != 0 or bytes[7] != 0)
        return error.InvalidV6Database;
    const codec = std.meta.intToEnum(Codec, bytes[4]) catch return error.InvalidV6Database;
    const result = BlockHeader{
        .codec = codec,
        .series_id = std.mem.readInt(u32, bytes[8..12], .little),
        .record_count = std.mem.readInt(u32, bytes[12..16], .little),
        .timestamp_min = std.mem.readInt(i64, bytes[16..24], .little),
        .timestamp_max = std.mem.readInt(i64, bytes[24..32], .little),
        .payload_size = std.mem.readInt(u32, bytes[32..36], .little),
        .checksum = std.mem.readInt(u64, bytes[40..48], .little),
    };
    if (result.record_count == 0 or result.record_count > records_per_block or
        result.timestamp_min > result.timestamp_max or
        std.mem.readInt(u32, bytes[36..40], .little) != result.record_count * record_size)
        return error.InvalidV6Database;
    return result;
}

fn decodeRaw(
    header: BlockHeader,
    payload: []const u8,
    timestamps: []i64,
    values: []f64,
) !void {
    if (payload.len != @as(usize, header.record_count) * record_size)
        return error.InvalidV6Database;
    var previous: ?i64 = null;
    for (timestamps, values, 0..) |*timestamp, *value, point_index| {
        const record = payload[point_index * record_size ..][0..record_size];
        timestamp.* = std.mem.readInt(i64, record[0..8], .little);
        value.* = @bitCast(std.mem.readInt(u64, record[8..16], .little));
        if (previous) |last| if (timestamp.* <= last) return error.InvalidV6Database;
        previous = timestamp.*;
    }
    try validateDecodedBounds(header, timestamps);
}

fn decodeCompressed(
    header: BlockHeader,
    payload: []const u8,
    timestamps: []i64,
    values: []f64,
) !void {
    if (payload.len < 4) return error.InvalidV6Database;
    const chunk_count = std.mem.readInt(u32, payload[0..4], .little);
    const expected_chunks = (timestamps.len + chunk_record_count - 1) / chunk_record_count;
    if (chunk_count != expected_chunks) return error.InvalidV6Database;
    const table_size = 4 + @as(usize, chunk_count) * checkpoint_entry_size;
    if (table_size > payload.len) return error.InvalidV6Database;
    var output_index: usize = 0;
    var previous_timestamp: ?i64 = null;
    var previous_offset = table_size;
    for (0..chunk_count) |chunk_index| {
        const entry = 4 + chunk_index * checkpoint_entry_size;
        const checkpoint_timestamp = std.mem.readInt(i64, payload[entry..][0..8], .little);
        const chunk_offset = std.mem.readInt(u32, payload[entry + 8 ..][0..4], .little);
        const chunk_end = if (chunk_index + 1 < chunk_count)
            std.mem.readInt(u32, payload[entry + checkpoint_entry_size + 8 ..][0..4], .little)
        else
            payload.len;
        if (chunk_offset < table_size or chunk_offset < previous_offset or
            chunk_end <= chunk_offset or chunk_end > payload.len) return error.InvalidV6Database;
        const records_in_chunk = @min(chunk_record_count, timestamps.len - output_index);
        var decoder = try CompressedDecoder.init(
            payload[chunk_offset..chunk_end],
            @intCast(records_in_chunk),
        );
        for (0..records_in_chunk) |_| {
            const point = try decoder.next();
            if (previous_timestamp) |last| if (point.timestamp <= last)
                return error.InvalidV6Database;
            timestamps[output_index] = point.timestamp;
            values[output_index] = point.value;
            previous_timestamp = point.timestamp;
            output_index += 1;
        }
        try decoder.finish();
        if (timestamps[output_index - records_in_chunk] != checkpoint_timestamp)
            return error.InvalidV6Database;
        previous_offset = chunk_offset;
    }
    if (output_index != timestamps.len) return error.InvalidV6Database;
    try validateDecodedBounds(header, timestamps);
}

fn validateDecodedBounds(header: BlockHeader, timestamps: []const i64) !void {
    if (timestamps.len == 0 or timestamps[0] != header.timestamp_min or
        timestamps[timestamps.len - 1] != header.timestamp_max)
        return error.InvalidV6Database;
}

const CompressedDecoder = struct {
    timestamps: []const u8,
    timestamp_cursor: usize = 8,
    value_reader: BitReader,
    count: u32,
    index: u32 = 0,
    timestamp: i64,
    delta: i64 = 0,
    value: u64,

    const Point = struct { timestamp: i64, value: f64 };

    fn init(payload: []const u8, count: u32) !CompressedDecoder {
        if (payload.len < 20) return error.InvalidV6Database;
        const timestamp_length = std.mem.readInt(u32, payload[0..4], .little);
        if (timestamp_length < 8 or 4 + timestamp_length + 8 > payload.len)
            return error.InvalidV6Database;
        const value_offset = 4 + timestamp_length;
        const value = std.mem.readInt(u64, payload[value_offset..][0..8], .little);
        return .{
            .timestamps = payload[4..value_offset],
            .value_reader = .{ .bytes = payload[value_offset + 8 ..] },
            .count = count,
            .timestamp = std.mem.readInt(i64, payload[4..12], .little),
            .value = value,
        };
    }

    fn next(self: *CompressedDecoder) !Point {
        if (self.index >= self.count) return error.InvalidV6Database;
        if (self.index > 0) {
            if (self.index == 1) {
                const encoded = try readVarint(self.timestamps, &self.timestamp_cursor);
                if (encoded > std.math.maxInt(i64)) return error.InvalidV6Database;
                self.delta = @intCast(encoded);
            } else {
                const difference = zigzagDecode(try readVarint(
                    self.timestamps,
                    &self.timestamp_cursor,
                ));
                self.delta = std.math.add(i64, self.delta, difference) catch
                    return error.InvalidV6Database;
            }
            self.timestamp = std.math.add(i64, self.timestamp, self.delta) catch
                return error.InvalidV6Database;
            if (try self.value_reader.read(1) == 1) {
                const leading: u6 = @intCast(try self.value_reader.read(6));
                const significant: u7 = @as(u7, @intCast(try self.value_reader.read(6))) + 1;
                if (@as(u7, leading) + significant > 64) return error.InvalidV6Database;
                const trailing: u6 = @intCast(64 - @as(u7, leading) - significant);
                self.value ^= (try self.value_reader.read(significant)) << trailing;
            }
        }
        self.index += 1;
        return .{ .timestamp = self.timestamp, .value = @bitCast(self.value) };
    }

    fn finish(self: *const CompressedDecoder) !void {
        if (self.index != self.count or self.timestamp_cursor != self.timestamps.len or
            self.value_reader.byte_position != self.value_reader.bytes.len or
            self.value_reader.reservoir != 0)
            return error.InvalidV6Database;
    }
};

const BitReader = struct {
    bytes: []const u8,
    byte_position: usize = 0,
    reservoir: u128 = 0,
    reservoir_bits: u8 = 0,

    fn read(self: *BitReader, count: u7) !u64 {
        if (count > 64) return error.InvalidV6Database;
        while (self.reservoir_bits < count) {
            if (self.byte_position >= self.bytes.len) return error.InvalidV6Database;
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
        return if (count == 64)
            value
        else
            value & ((@as(u64, 1) << @intCast(count)) - 1);
    }
};

fn takeInt(comptime T: type, bytes: []const u8, cursor: *usize) !T {
    const end = std.math.add(usize, cursor.*, @sizeOf(T)) catch
        return error.InvalidV6Database;
    if (end > bytes.len) return error.InvalidV6Database;
    const value = std.mem.readInt(T, bytes[cursor.*..][0..@sizeOf(T)], .little);
    cursor.* = end;
    return value;
}

fn readVarint(bytes: []const u8, cursor: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    for (0..10) |_| {
        if (cursor.* >= bytes.len) return error.InvalidV6Database;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 63 and byte > 1) return error.InvalidV6Database;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
    }
    return error.InvalidV6Database;
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

comptime {
    std.debug.assert(records_per_block == 4093);
    std.debug.assert(checkpoint_entry_size == @sizeOf(i64) + @sizeOf(u32));
    std.debug.assert(footer_series_entry_size == 11);
    std.debug.assert(footer_block_entry_size == 33);
}
