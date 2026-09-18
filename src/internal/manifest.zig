const std = @import("std");
const checksum = @import("checksum.zig");
const format = @import("format.zig");
const index = @import("index.zig");

pub const header_size: usize = 64;
pub const series_fixed_size: usize = 120;
pub const size_max: usize = 256 * 1024 * 1024;

pub const Series = struct {
    id: u32,
    name: []u8,
    root: format.Pointer,
    summary: index.Summary,

    pub fn deinit(self: Series, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Manifest = struct {
    generation: u64,
    series: std.ArrayList(Series),
    names: []u8 = &.{},

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        if (self.names.len > 0) allocator.free(self.names);
        self.series.deinit(allocator);
    }
};

pub fn encode(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    generation: u64,
    series: []const Series,
) !format.Pointer {
    if (generation == 0 or series.len > std.math.maxInt(u32))
        return error.InvalidManifest;
    var total_size = header_size;
    for (series, 0..) |entry, series_index| {
        if (entry.name.len == 0 or entry.name.len > std.math.maxInt(u16))
            return error.InvalidSeriesName;
        if (entry.root.kind != .index or entry.summary.point_count == 0)
            return error.InvalidManifest;
        if (series_index > 0 and series[series_index - 1].id >= entry.id)
            return error.InvalidManifest;
        total_size = std.math.add(usize, total_size, series_fixed_size) catch
            return error.ManifestTooLarge;
        total_size = std.math.add(usize, total_size, entry.name.len) catch
            return error.ManifestTooLarge;
    }
    if (total_size > size_max) return error.ManifestTooLarge;
    return encodeKnownSize(output, allocator, generation, series, total_size);
}

pub fn encodeKnownSize(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    generation: u64,
    series: []const Series,
    total_size: usize,
) !format.Pointer {
    var iterator = SliceIterator{ .series = series };
    return encodeKnownIterator(
        output,
        allocator,
        generation,
        series.len,
        total_size,
        &iterator,
    );
}

const SliceIterator = struct {
    series: []const Series,
    index: usize = 0,

    fn next(self: *SliceIterator) ?Series {
        if (self.index == self.series.len) return null;
        defer self.index += 1;
        return self.series[self.index];
    }
};

pub fn encodeKnownIterator(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    generation: u64,
    series_count: usize,
    total_size: usize,
    iterator: anytype,
) !format.Pointer {
    if (generation == 0 or series_count > std.math.maxInt(u32) or total_size < header_size)
        return error.InvalidManifest;
    if (total_size > size_max) return error.ManifestTooLarge;
    output.clearRetainingCapacity();
    try output.resize(allocator, total_size);
    @memcpy(output.items[0..8], format.manifest_magic);
    std.mem.writeInt(u64, output.items[8..16], generation, .little);
    std.mem.writeInt(u32, output.items[16..20], @intCast(series_count), .little);
    std.mem.writeInt(u32, output.items[20..24], @intCast(total_size), .little);
    @memset(output.items[24..header_size], 0);

    var cursor: usize = header_size;
    var encoded_count: usize = 0;
    while (iterator.next()) |entry| {
        if (encoded_count == series_count) return error.InvalidManifest;
        std.mem.writeInt(u32, output.items[cursor..][0..4], entry.id, .little);
        std.mem.writeInt(u16, output.items[cursor + 4 ..][0..2], @intCast(entry.name.len), .little);
        @memset(output.items[cursor + 6 .. cursor + 24], 0);
        var pointer_bytes: [format.pointer_size]u8 = undefined;
        entry.root.encode(&pointer_bytes);
        @memcpy(output.items[cursor + 24 ..][0..format.pointer_size], &pointer_bytes);
        encodeSummary(entry.summary, output.items[cursor + 56 ..][0..64]);
        cursor += series_fixed_size;
        @memcpy(output.items[cursor..][0..entry.name.len], entry.name);
        cursor += entry.name.len;
        encoded_count += 1;
    }
    if (encoded_count != series_count or cursor != total_size) return error.InvalidManifest;
    return .{
        .offset = 0,
        .size = @intCast(total_size),
        .kind = .manifest,
        .identity = checksum.calculate(output.items),
    };
}

pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pointer: format.Pointer,
    committed_size: u64,
) !Manifest {
    if (pointer.kind != .manifest or pointer.size != bytes.len)
        return error.InvalidManifest;
    try pointer.validate(committed_size);
    if (!checksum.equal(checksum.calculate(bytes), pointer.identity))
        return error.ChecksumMismatch;
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..8], format.manifest_magic))
        return error.InvalidManifest;
    if (!allZero(bytes[24..header_size])) return error.InvalidManifest;
    const generation = std.mem.readInt(u64, bytes[8..16], .little);
    const series_count = std.mem.readInt(u32, bytes[16..20], .little);
    const encoded_size = std.mem.readInt(u32, bytes[20..24], .little);
    if (generation == 0 or encoded_size != bytes.len) return error.InvalidManifest;

    const minimum_size = std.math.mul(usize, series_count, series_fixed_size) catch
        return error.InvalidManifest;
    if (minimum_size > bytes.len - header_size) return error.InvalidManifest;
    const names_size = bytes.len - header_size - minimum_size;
    var result = Manifest{
        .generation = generation,
        .series = .empty,
        .names = if (names_size == 0) &.{} else try allocator.alloc(u8, names_size),
    };
    errdefer result.deinit(allocator);
    try result.series.ensureTotalCapacity(allocator, series_count);
    var cursor: usize = header_size;
    var names_cursor: usize = 0;
    for (0..series_count) |_| {
        const fixed_end = std.math.add(usize, cursor, series_fixed_size) catch
            return error.InvalidManifest;
        if (fixed_end > bytes.len) return error.InvalidManifest;
        const id = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        const name_len = std.mem.readInt(u16, bytes[cursor + 4 ..][0..2], .little);
        if (name_len == 0 or !allZero(bytes[cursor + 6 .. cursor + 24]))
            return error.InvalidManifest;
        const root = try format.Pointer.decode(bytes[cursor + 24 ..][0..format.pointer_size]);
        if (root.kind != .index) return error.InvalidManifest;
        try root.validate(committed_size);
        const summary = decodeSummary(bytes[cursor + 56 ..][0..64]);
        if (summary.point_count == 0 or summary.timestamp_min > summary.timestamp_max)
            return error.InvalidManifest;
        cursor = fixed_end;
        const name_end = std.math.add(usize, cursor, name_len) catch
            return error.InvalidManifest;
        if (name_end > bytes.len) return error.InvalidManifest;
        if (result.series.items.len > 0 and result.series.items[result.series.items.len - 1].id >= id)
            return error.InvalidManifest;
        const name = result.names[names_cursor..][0..name_len];
        @memcpy(name, bytes[cursor..name_end]);
        result.series.appendAssumeCapacity(.{
            .id = id,
            .name = name,
            .root = root,
            .summary = summary,
        });
        names_cursor += name_len;
        cursor = name_end;
    }
    if (cursor != bytes.len or names_cursor != result.names.len)
        return error.InvalidManifest;
    return result;
}

fn encodeSummary(summary: index.Summary, output: *[64]u8) void {
    std.mem.writeInt(i64, output[0..8], summary.timestamp_min, .little);
    std.mem.writeInt(i64, output[8..16], summary.timestamp_max, .little);
    std.mem.writeInt(u64, output[16..24], summary.point_count, .little);
    writeFloat(output[24..32], summary.value_min);
    writeFloat(output[32..40], summary.value_max);
    writeFloat(output[40..48], summary.value_sum);
    writeFloat(output[48..56], summary.value_first);
    writeFloat(output[56..64], summary.value_last);
}

fn decodeSummary(input: *const [64]u8) index.Summary {
    return .{
        .timestamp_min = std.mem.readInt(i64, input[0..8], .little),
        .timestamp_max = std.mem.readInt(i64, input[8..16], .little),
        .point_count = std.mem.readInt(u64, input[16..24], .little),
        .value_min = readFloat(input[24..32]),
        .value_max = readFloat(input[32..40]),
        .value_sum = readFloat(input[40..48]),
        .value_first = readFloat(input[48..56]),
        .value_last = readFloat(input[56..64]),
    };
}

fn writeFloat(output: *[8]u8, value: f64) void {
    std.mem.writeInt(u64, output, @bitCast(value), .little);
}

fn readFloat(input: *const [8]u8) f64 {
    return @bitCast(std.mem.readInt(u64, input, .little));
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

comptime {
    std.debug.assert(size_max <= std.math.maxInt(u32));
}

test "manifest round trip preserves portable series roots" {
    const allocator = std.testing.allocator;
    const name_a = try allocator.dupe(u8, "cpu");
    const name_b = try allocator.dupe(u8, "memory");
    var source = [_]Series{
        testSeries(1, name_a, 1, 10),
        testSeries(2, name_b, 20, 30),
    };
    defer for (&source) |entry| entry.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var pointer = try encode(&bytes, allocator, 9, &source);
    var duplicate: std.ArrayList(u8) = .empty;
    defer duplicate.deinit(allocator);
    const duplicate_pointer = try encode(&duplicate, allocator, 9, &source);
    try std.testing.expectEqualSlices(u8, bytes.items, duplicate.items);
    try std.testing.expect(checksum.equal(pointer.identity, duplicate_pointer.identity));
    pointer.offset = format.control_size;
    var decoded = try decode(
        allocator,
        bytes.items,
        pointer,
        format.control_size + format.index_node_size,
    );
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 9), decoded.generation);
    try std.testing.expectEqual(@as(usize, 2), decoded.series.items.len);
    try std.testing.expectEqualStrings("cpu", decoded.series.items[0].name);
    try std.testing.expectEqual(@as(i64, 30), decoded.series.items[1].summary.timestamp_max);
}

fn testSeries(id: u32, name: []u8, min: i64, max: i64) Series {
    return .{
        .id = id,
        .name = name,
        .root = .{
            .offset = format.control_size,
            .size = format.index_node_size,
            .kind = .index,
            .identity = checksum.calculate(name),
        },
        .summary = .{
            .timestamp_min = min,
            .timestamp_max = max,
            .point_count = @intCast(max - min + 1),
            .value_min = 1,
            .value_max = 2,
            .value_sum = 3,
            .value_first = 1,
            .value_last = 2,
        },
    };
}
