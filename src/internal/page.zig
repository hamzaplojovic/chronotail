const std = @import("std");
const checksum = @import("checksum.zig");
const format = @import("format.zig");

pub const records_max = (format.page_size - format.page_header_size) / 16;

pub const TimestampCodec = enum(u8) {
    raw = 0,
    base_step = 1,
    delta_varint = 2,
};

pub const ValueCodec = enum(u8) {
    raw = 0,
    xor_varint = 1,
};

const value_restart_interval: usize = 128;
const compression_min_savings_percent: usize = 5;

pub const Statistics = struct {
    count: u32,
    timestamp_min: i64,
    timestamp_max: i64,
    value_first: f64,
    value_last: f64,
    value_min: f64,
    value_max: f64,
    value_sum: f64,
};

pub const Encoded = struct {
    bytes: []const u8,
    identity: checksum.Identity,
    timestamp_codec: TimestampCodec,
    value_codec: ValueCodec,
    statistics: Statistics,
};

pub const View = struct {
    bytes: []const u8,
    series_id: u32,
    timestamp_codec: TimestampCodec,
    value_codec: ValueCodec,
    timestamps_offset: u32,
    timestamps_size: u32,
    values_offset: u32,
    values_size: u32,
    timestamp_step: u64,
    statistics: Statistics,

    pub fn lowerBound(self: View, target: i64) usize {
        if (self.statistics.count == 0) return 0;
        if (target <= self.statistics.timestamp_min) return 0;
        if (target > self.statistics.timestamp_max) return self.statistics.count;
        return switch (self.timestamp_codec) {
            .base_step => blk: {
                const distance: u64 = @intCast(
                    @as(i128, target) - self.statistics.timestamp_min,
                );
                const quotient = distance / self.timestamp_step;
                const remainder = distance % self.timestamp_step;
                break :blk @intCast(quotient + @intFromBool(remainder != 0));
            },
            .raw => self.rawLowerBound(target),
            .delta_varint => self.rawLowerBound(target),
        };
    }

    pub fn timestampAt(self: View, index: usize) i64 {
        std.debug.assert(index < self.statistics.count);
        if (self.timestamp_codec == .delta_varint) {
            var cursor = self.timestampCursor(index);
            return cursor.next();
        }
        return switch (self.timestamp_codec) {
            .base_step => @intCast(
                @as(i128, self.statistics.timestamp_min) +
                    @as(i128, @intCast(self.timestamp_step)) * index,
            ),
            .raw => std.mem.readInt(
                i64,
                self.timestampBytes(index)[0..8],
                .little,
            ),
            .delta_varint => unreachable,
        };
    }

    pub fn timestampCursor(self: View, start: usize) TimestampCursor {
        std.debug.assert(start < self.statistics.count);
        return TimestampCursor.init(self, start);
    }

    pub fn valueAt(self: View, index: usize) f64 {
        std.debug.assert(index < self.statistics.count);
        var cursor = self.valueCursor(index);
        return cursor.next();
    }

    pub fn valueCursor(self: View, start: usize) ValueCursor {
        std.debug.assert(start < self.statistics.count);
        return ValueCursor.init(self, start);
    }

    pub fn rawTimestamps(self: View) ?[]const i64 {
        if (self.timestamp_codec != .raw) return null;
        const start: usize = self.timestamps_offset;
        const pointer = self.bytes[start..].ptr;
        if (@intFromPtr(pointer) % @alignOf(i64) != 0) return null;
        const aligned: [*]align(@alignOf(i64)) const i64 = @ptrCast(@alignCast(pointer));
        return aligned[0..self.statistics.count];
    }

    pub fn rawValues(self: View) ?[]const f64 {
        if (self.value_codec != .raw) return null;
        const start: usize = self.values_offset;
        const pointer = self.bytes[start..].ptr;
        if (@intFromPtr(pointer) % @alignOf(f64) != 0) return null;
        const aligned: [*]align(@alignOf(f64)) const f64 = @ptrCast(@alignCast(pointer));
        return aligned[0..self.statistics.count];
    }

    pub fn rangeInto(
        self: View,
        start: i64,
        end: i64,
        timestamps: []i64,
        values: []f64,
    ) !usize {
        if (timestamps.len != values.len) return error.InvalidBatch;
        if (end < start) return 0;
        var index = self.lowerBound(start);
        if (index == self.statistics.count) return 0;
        if (self.timestamp_codec == .raw and self.value_codec == .raw) {
            const raw_timestamps = self.rawTimestamps() orelse return error.InvalidPage;
            const raw_values = self.rawValues() orelse return error.InvalidPage;
            var high = self.rawLowerBound(end);
            if (high < raw_timestamps.len and raw_timestamps[high] == end) high += 1;
            const count = high - index;
            const copied = @min(count, timestamps.len);
            @memcpy(timestamps[0..copied], raw_timestamps[index..][0..copied]);
            @memcpy(values[0..copied], raw_values[index..][0..copied]);
            return count;
        }
        var timestamp_cursor = self.timestampCursor(index);
        var value_cursor = self.valueCursor(index);
        var count: usize = 0;
        while (index < self.statistics.count) : (index += 1) {
            const timestamp = timestamp_cursor.next();
            if (timestamp > end) break;
            const value = value_cursor.next();
            if (count < timestamps.len) {
                timestamps[count] = timestamp;
                values[count] = value;
            }
            count += 1;
        }
        return count;
    }

    pub fn countRange(self: View, start: i64, end: i64) usize {
        if (end < start) return 0;
        var point_index = self.lowerBound(start);
        if (point_index == self.statistics.count) return 0;
        if (self.timestamp_codec == .raw) {
            const raw_timestamps = self.rawTimestamps() orelse unreachable;
            var high = self.rawLowerBound(end);
            if (high < raw_timestamps.len and raw_timestamps[high] == end) high += 1;
            return high - point_index;
        }
        var timestamp_cursor = self.timestampCursor(point_index);
        var count: usize = 0;
        while (point_index < self.statistics.count) : (point_index += 1) {
            if (timestamp_cursor.next() > end) break;
            count += 1;
        }
        return count;
    }

    fn rawLowerBound(self: View, target: i64) usize {
        var low: usize = 0;
        var high: usize = self.statistics.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.timestampAt(middle) < target) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    fn timestampBytes(self: View, index: usize) []const u8 {
        const offset = @as(usize, self.timestamps_offset) + index * 8;
        return self.bytes[offset..][0..8];
    }

    fn valueBytes(self: View, index: usize) []const u8 {
        const offset = @as(usize, self.values_offset) + index * 8;
        return self.bytes[offset..][0..8];
    }

    fn valueGroupOffset(self: View, group: usize) usize {
        const entry = @as(usize, self.values_offset) + 4 + group * 4;
        return @as(usize, self.values_offset) +
            std.mem.readInt(u32, self.bytes[entry..][0..4], .little);
    }
};

pub const TimestampCursor = struct {
    view: View,
    index: usize,
    timestamp: i64,
    cursor: usize,

    fn init(view: View, start: usize) TimestampCursor {
        if (view.timestamp_codec != .delta_varint) return .{
            .view = view,
            .index = start,
            .timestamp = 0,
            .cursor = 0,
        };
        const group = start / value_restart_interval;
        const group_start = group * value_restart_interval;
        const directory_entry = @as(usize, view.timestamps_offset) + 4 + group * 4;
        var cursor = @as(usize, view.timestamps_offset) +
            std.mem.readInt(u32, view.bytes[directory_entry..][0..4], .little);
        var timestamp = std.mem.readInt(i64, view.bytes[cursor..][0..8], .little);
        cursor += 8;
        var timestamp_index = group_start;
        while (timestamp_index < start) : (timestamp_index += 1) {
            timestamp += @intCast(readVarintUnchecked(view.bytes, &cursor));
        }
        return .{ .view = view, .index = start, .timestamp = timestamp, .cursor = cursor };
    }

    pub fn next(self: *TimestampCursor) i64 {
        std.debug.assert(self.index < self.view.statistics.count);
        if (self.view.timestamp_codec != .delta_varint) {
            const result: i64 = switch (self.view.timestamp_codec) {
                .raw => std.mem.readInt(
                    i64,
                    self.view.timestampBytes(self.index)[0..8],
                    .little,
                ),
                .base_step => @intCast(
                    @as(i128, self.view.statistics.timestamp_min) +
                        @as(i128, @intCast(self.view.timestamp_step)) * self.index,
                ),
                .delta_varint => unreachable,
            };
            self.index += 1;
            return result;
        }
        const result = self.timestamp;
        self.index += 1;
        if (self.index < self.view.statistics.count) {
            if (self.index % value_restart_interval == 0) {
                const group = self.index / value_restart_interval;
                const entry = @as(usize, self.view.timestamps_offset) + 4 + group * 4;
                self.cursor = @as(usize, self.view.timestamps_offset) +
                    std.mem.readInt(u32, self.view.bytes[entry..][0..4], .little);
                self.timestamp = std.mem.readInt(i64, self.view.bytes[self.cursor..][0..8], .little);
                self.cursor += 8;
            } else {
                self.timestamp += @intCast(readVarintUnchecked(self.view.bytes, &self.cursor));
            }
        }
        return result;
    }
};

pub const ValueCursor = struct {
    view: View,
    index: usize,
    bits: u64,
    cursor: usize,

    fn init(view: View, start: usize) ValueCursor {
        if (view.value_codec == .raw) return .{
            .view = view,
            .index = start,
            .bits = 0,
            .cursor = @as(usize, view.values_offset) + start * 8,
        };
        const group = start / value_restart_interval;
        const group_start = group * value_restart_interval;
        var cursor = view.valueGroupOffset(group);
        var bits = std.mem.readInt(u64, view.bytes[cursor..][0..8], .little);
        cursor += 8;
        var value_index = group_start;
        while (value_index < start) : (value_index += 1) bits ^= readVarintUnchecked(view.bytes, &cursor);
        return .{ .view = view, .index = start, .bits = bits, .cursor = cursor };
    }

    pub fn next(self: *ValueCursor) f64 {
        std.debug.assert(self.index < self.view.statistics.count);
        if (self.view.value_codec == .raw) {
            const bits = std.mem.readInt(u64, self.view.bytes[self.cursor..][0..8], .little);
            self.cursor += 8;
            self.index += 1;
            return @bitCast(bits);
        }
        const result: f64 = @bitCast(self.bits);
        self.index += 1;
        if (self.index < self.view.statistics.count) {
            if (self.index % value_restart_interval == 0) {
                self.cursor = self.view.valueGroupOffset(self.index / value_restart_interval);
                self.bits = std.mem.readInt(u64, self.view.bytes[self.cursor..][0..8], .little);
                self.cursor += 8;
            } else {
                self.bits ^= readVarintUnchecked(self.view.bytes, &self.cursor);
            }
        }
        return result;
    }
};

pub fn encode(
    output: *[format.page_size]u8,
    series_id: u32,
    timestamps: []const i64,
    values: []const f64,
) !Encoded {
    return encodeWithOptions(output, series_id, timestamps, values, true);
}

pub fn encodeWithOptions(
    output: *[format.page_size]u8,
    series_id: u32,
    timestamps: []const i64,
    values: []const f64,
    compress: bool,
) !Encoded {
    if (timestamps.len != values.len or timestamps.len == 0) return error.InvalidBatch;
    if (timestamps.len > records_max) return error.PageFull;
    if (!strictlyIncreasing(timestamps)) return error.TimestampNotIncreasing;

    const timestamps_offset = format.page_header_size;
    @memset(output, 0);
    var timestamp_codec = if (compress)
        detectTimestampCodec(timestamps)
    else
        TimestampCodec.raw;
    var timestamps_size: usize = switch (timestamp_codec) {
        .raw => timestamps.len * 8,
        .base_step => 16,
        .delta_varint => encodeDeltaTimestamps(output[timestamps_offset..], timestamps) orelse blk: {
            timestamp_codec = .raw;
            break :blk timestamps.len * 8;
        },
    };
    if (timestamp_codec == .delta_varint and
        timestamps_size * 100 > timestamps.len * 8 * (100 - compression_min_savings_percent))
    {
        timestamp_codec = .raw;
        timestamps_size = timestamps.len * 8;
    }
    const values_offset = std.mem.alignForward(
        usize,
        timestamps_offset + timestamps_size,
        8,
    );
    const raw_values_size = values.len * 8;
    const maximum_stored_size = values_offset + raw_values_size;
    if (maximum_stored_size > output.len) return error.PageFull;
    const statistics = calculateStatistics(timestamps, values);
    switch (timestamp_codec) {
        .raw => if (@import("builtin").cpu.arch.endian() == .little) {
            @memcpy(
                output[timestamps_offset..][0 .. timestamps.len * 8],
                std.mem.sliceAsBytes(timestamps),
            );
        } else for (timestamps, 0..) |timestamp, timestamp_index| {
            const offset = timestamps_offset + timestamp_index * 8;
            std.mem.writeInt(i64, output[offset..][0..8], timestamp, .little);
        },
        .base_step => {
            std.mem.writeInt(i64, output[timestamps_offset..][0..8], timestamps[0], .little);
            std.mem.writeInt(
                u64,
                output[timestamps_offset + 8 ..][0..8],
                timestampStep(timestamps),
                .little,
            );
        },
        .delta_varint => {},
    }
    const value_encoding = if (compress)
        encodeCompressedValues(output[values_offset..], values) orelse
            encodeRawValues(output[values_offset..], values)
    else
        encodeRawValues(output[values_offset..], values);
    const stored_size = values_offset + value_encoding.size;

    @memcpy(output[0..8], format.data_magic);
    std.mem.writeInt(u32, output[8..12], series_id, .little);
    output[12] = @intFromEnum(timestamp_codec);
    output[13] = @intFromEnum(value_encoding.codec);
    std.mem.writeInt(u32, output[16..20], @intCast(timestamps.len), .little);
    std.mem.writeInt(u32, output[20..24], @intCast(stored_size), .little);
    std.mem.writeInt(u32, output[24..28], timestamps_offset, .little);
    std.mem.writeInt(u32, output[28..32], @intCast(timestamps_size), .little);
    std.mem.writeInt(u32, output[32..36], @intCast(values_offset), .little);
    std.mem.writeInt(u32, output[36..40], @intCast(value_encoding.size), .little);
    std.mem.writeInt(i64, output[40..48], statistics.timestamp_min, .little);
    std.mem.writeInt(i64, output[48..56], statistics.timestamp_max, .little);
    writeFloat(output[56..64], statistics.value_first);
    writeFloat(output[64..72], statistics.value_last);
    writeFloat(output[72..80], statistics.value_min);
    writeFloat(output[80..88], statistics.value_max);
    writeFloat(output[88..96], statistics.value_sum);
    const page_identity = checksum.calculate(output[0..stored_size]);
    return .{
        .bytes = output[0..stored_size],
        .identity = page_identity,
        .timestamp_codec = timestamp_codec,
        .value_codec = value_encoding.codec,
        .statistics = statistics,
    };
}

const ValueEncoding = struct { codec: ValueCodec, size: usize };

fn encodeDeltaTimestamps(output: []u8, timestamps: []const i64) ?usize {
    const group_count = std.math.divCeil(usize, timestamps.len, value_restart_interval) catch
        return null;
    const directory_size = std.mem.alignForward(usize, 4 + group_count * 4, 8);
    if (directory_size >= output.len) return null;
    std.mem.writeInt(u32, output[0..4], @intCast(group_count), .little);
    @memset(output[4 + group_count * 4 .. directory_size], 0);
    var cursor = directory_size;
    var timestamp_index: usize = 0;
    while (timestamp_index < timestamps.len) {
        const group = timestamp_index / value_restart_interval;
        std.mem.writeInt(u32, output[4 + group * 4 ..][0..4], @intCast(cursor), .little);
        if (cursor + 8 > output.len) return null;
        std.mem.writeInt(i64, output[cursor..][0..8], timestamps[timestamp_index], .little);
        cursor += 8;
        timestamp_index += 1;
        const group_end = @min(timestamp_index + value_restart_interval - 1, timestamps.len);
        while (timestamp_index < group_end) : (timestamp_index += 1) {
            const delta: u64 = @intCast(
                @as(i128, timestamps[timestamp_index]) - timestamps[timestamp_index - 1],
            );
            cursor = writeVarint(output, cursor, delta) orelse return null;
        }
    }
    return cursor;
}

fn encodeRawValues(output: []u8, values: []const f64) ValueEncoding {
    const size = values.len * 8;
    if (@import("builtin").cpu.arch.endian() == .little) {
        @memcpy(output[0..size], std.mem.sliceAsBytes(values));
    } else {
        for (values, 0..) |value, value_index| {
            const offset = value_index * 8;
            std.mem.writeInt(u64, output[offset..][0..8], @bitCast(value), .little);
        }
    }
    return .{ .codec = .raw, .size = size };
}

fn encodeCompressedValues(output: []u8, values: []const f64) ?ValueEncoding {
    const group_count = std.math.divCeil(usize, values.len, value_restart_interval) catch
        return null;
    const directory_size = std.mem.alignForward(usize, 4 + group_count * 4, 8);
    if (directory_size >= output.len) return null;
    std.mem.writeInt(u32, output[0..4], @intCast(group_count), .little);
    @memset(output[4 + group_count * 4 .. directory_size], 0);
    var cursor = directory_size;
    var value_index: usize = 0;
    while (value_index < values.len) {
        const group = value_index / value_restart_interval;
        std.mem.writeInt(u32, output[4 + group * 4 ..][0..4], @intCast(cursor), .little);
        if (cursor + 8 > output.len) return null;
        var previous: u64 = @bitCast(values[value_index]);
        std.mem.writeInt(u64, output[cursor..][0..8], previous, .little);
        cursor += 8;
        value_index += 1;
        const group_end = @min(value_index + value_restart_interval - 1, values.len);
        while (value_index < group_end) : (value_index += 1) {
            const current: u64 = @bitCast(values[value_index]);
            cursor = writeVarint(output, cursor, current ^ previous) orelse return null;
            previous = current;
        }
    }
    const raw_size = values.len * 8;
    if (cursor * 100 > raw_size * (100 - compression_min_savings_percent)) return null;
    return .{ .codec = .xor_varint, .size = cursor };
}

fn writeVarint(output: []u8, start: usize, input: u64) ?usize {
    var value = input;
    var cursor = start;
    while (value >= 0x80) {
        if (cursor == output.len) return null;
        output[cursor] = @as(u8, @truncate(value)) | 0x80;
        cursor += 1;
        value >>= 7;
    }
    if (cursor == output.len) return null;
    output[cursor] = @truncate(value);
    return cursor + 1;
}

pub fn decode(bytes: []const u8, expected_identity: checksum.Identity) !View {
    return decodeInternal(bytes, expected_identity, true);
}

pub fn decodeKnown(bytes: []const u8, expected_identity: checksum.Identity) !View {
    return decodeInternal(bytes, expected_identity, false);
}

fn decodeInternal(
    bytes: []const u8,
    expected_identity: checksum.Identity,
    authenticate: bool,
) !View {
    if (bytes.len < format.page_header_size or bytes.len > format.page_size)
        return error.InvalidPage;
    if (authenticate and !checksum.equal(checksum.calculate(bytes), expected_identity))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0..8], format.data_magic)) return error.InvalidPage;
    if (!allZero(bytes[14..16]) or !allZero(bytes[96..format.page_header_size]))
        return error.InvalidPage;
    const timestamp_codec = std.meta.intToEnum(TimestampCodec, bytes[12]) catch
        return error.InvalidPage;
    const value_codec = std.meta.intToEnum(ValueCodec, bytes[13]) catch
        return error.InvalidPage;
    const count = std.mem.readInt(u32, bytes[16..20], .little);
    const stored_size = std.mem.readInt(u32, bytes[20..24], .little);
    const timestamps_offset = std.mem.readInt(u32, bytes[24..28], .little);
    const timestamps_size = std.mem.readInt(u32, bytes[28..32], .little);
    const values_offset = std.mem.readInt(u32, bytes[32..36], .little);
    const values_size = std.mem.readInt(u32, bytes[36..40], .little);
    if (count == 0 or count > records_max or stored_size != bytes.len)
        return error.InvalidPage;
    if (timestamps_offset != format.page_header_size) return error.InvalidPage;
    const expected_timestamps_size: u32 = switch (timestamp_codec) {
        .raw => std.math.mul(u32, count, 8) catch return error.InvalidPage,
        .base_step => 16,
        .delta_varint => timestamps_size,
    };
    if (timestamps_size != expected_timestamps_size) return error.InvalidPage;
    if (timestamp_codec == .delta_varint and timestamps_size < 16)
        return error.InvalidPage;
    const timestamps_end = std.math.add(u32, timestamps_offset, timestamps_size) catch
        return error.InvalidPage;
    if (values_offset != std.mem.alignForward(u32, timestamps_end, 8))
        return error.InvalidPage;
    switch (value_codec) {
        .raw => {
            const expected_values_size = std.math.mul(u32, count, 8) catch
                return error.InvalidPage;
            if (values_size != expected_values_size) return error.InvalidPage;
        },
        .xor_varint => if (values_size < 16) return error.InvalidPage,
    }
    const values_end = std.math.add(u32, values_offset, values_size) catch
        return error.InvalidPage;
    if (values_end != stored_size) return error.InvalidPage;
    const statistics = Statistics{
        .count = count,
        .timestamp_min = std.mem.readInt(i64, bytes[40..48], .little),
        .timestamp_max = std.mem.readInt(i64, bytes[48..56], .little),
        .value_first = readFloat(bytes[56..64]),
        .value_last = readFloat(bytes[64..72]),
        .value_min = readFloat(bytes[72..80]),
        .value_max = readFloat(bytes[80..88]),
        .value_sum = readFloat(bytes[88..96]),
    };
    if (statistics.timestamp_min > statistics.timestamp_max) return error.InvalidPage;

    var view = View{
        .bytes = bytes,
        .series_id = std.mem.readInt(u32, bytes[8..12], .little),
        .timestamp_codec = timestamp_codec,
        .value_codec = value_codec,
        .timestamps_offset = timestamps_offset,
        .timestamps_size = timestamps_size,
        .values_offset = values_offset,
        .values_size = values_size,
        .timestamp_step = 0,
        .statistics = statistics,
    };
    if (timestamp_codec == .delta_varint) try validateDeltaTimestamps(view, authenticate);
    if (value_codec == .xor_varint) try validateCompressedValues(view, authenticate);
    if (timestamp_codec == .base_step) {
        const base = std.mem.readInt(i64, bytes[timestamps_offset..][0..8], .little);
        view.timestamp_step = std.mem.readInt(
            u64,
            bytes[timestamps_offset + 8 ..][0..8],
            .little,
        );
        if (base != statistics.timestamp_min or view.timestamp_step == 0)
            return error.InvalidPage;
        const last: i128 = @as(i128, base) +
            @as(i128, @intCast(view.timestamp_step)) * (count - 1);
        if (last != statistics.timestamp_max) return error.InvalidPage;
    } else if (timestamp_codec == .raw) {
        var previous = view.timestampAt(0);
        if (previous != statistics.timestamp_min) return error.InvalidPage;
        if (authenticate) {
            for (1..count) |index| {
                const timestamp = view.timestampAt(index);
                if (timestamp <= previous) return error.InvalidPage;
                previous = timestamp;
            }
        } else {
            previous = view.timestampAt(count - 1);
        }
        if (previous != statistics.timestamp_max) return error.InvalidPage;
    } else {
        if (view.timestampAt(0) != statistics.timestamp_min or
            view.timestampAt(count - 1) != statistics.timestamp_max)
            return error.InvalidPage;
    }
    if (authenticate and !statisticsEqual(calculateViewStatistics(view), statistics))
        return error.InvalidPage;
    return view;
}

fn detectTimestampCodec(timestamps: []const i64) TimestampCodec {
    if (timestamps.len < 2) return .raw;
    const step: u64 = @intCast(@as(i128, timestamps[1]) - timestamps[0]);
    for (timestamps[2..], 2..) |timestamp, index| {
        const current: u64 = @intCast(@as(i128, timestamp) - timestamps[index - 1]);
        if (current != step) return .delta_varint;
    }
    return .base_step;
}

fn timestampStep(timestamps: []const i64) u64 {
    std.debug.assert(timestamps.len >= 2);
    return @intCast(@as(i128, timestamps[1]) - timestamps[0]);
}

fn strictlyIncreasing(timestamps: []const i64) bool {
    for (timestamps[1..], timestamps[0 .. timestamps.len - 1]) |current, previous| {
        if (current <= previous) return false;
    }
    return true;
}

fn validateDeltaTimestamps(view: View, authenticate: bool) !void {
    const base: usize = view.timestamps_offset;
    const end = base + view.timestamps_size;
    const group_count = std.mem.readInt(u32, view.bytes[base..][0..4], .little);
    const expected_groups = std.math.divCeil(
        u32,
        view.statistics.count,
        value_restart_interval,
    ) catch return error.InvalidPage;
    if (group_count != expected_groups) return error.InvalidPage;
    const directory_size = std.mem.alignForward(usize, 4 + @as(usize, group_count) * 4, 8);
    if (directory_size + 8 > view.timestamps_size) return error.InvalidPage;
    if (!allZero(view.bytes[base + 4 + @as(usize, group_count) * 4 .. base + directory_size]))
        return error.InvalidPage;
    if (!authenticate) {
        const first_offset = std.mem.readInt(u32, view.bytes[base + 4 ..][0..4], .little);
        if (first_offset != directory_size) return error.InvalidPage;
        return;
    }

    var timestamp_index: usize = 0;
    var cursor = directory_size;
    var previous: ?i64 = null;
    for (0..group_count) |group| {
        const encoded_offset = std.mem.readInt(
            u32,
            view.bytes[base + 4 + group * 4 ..][0..4],
            .little,
        );
        if (encoded_offset != cursor or base + cursor + 8 > end) return error.InvalidPage;
        var timestamp = std.mem.readInt(i64, view.bytes[base + cursor ..][0..8], .little);
        cursor += 8;
        if (previous) |last| if (timestamp <= last) return error.InvalidPage;
        previous = timestamp;
        timestamp_index += 1;
        const group_end = @min(
            timestamp_index + value_restart_interval - 1,
            view.statistics.count,
        );
        while (timestamp_index < group_end) : (timestamp_index += 1) {
            const delta = try readVarint(view.bytes[base..end], &cursor);
            if (delta == 0 or delta > std.math.maxInt(i64)) return error.InvalidPage;
            timestamp = std.math.add(i64, timestamp, @intCast(delta)) catch
                return error.InvalidPage;
            previous = timestamp;
        }
    }
    if (cursor != view.timestamps_size or timestamp_index != view.statistics.count or
        previous.? != view.statistics.timestamp_max) return error.InvalidPage;
}

fn validateCompressedValues(view: View, authenticate: bool) !void {
    const base: usize = view.values_offset;
    const end = base + view.values_size;
    const group_count = std.mem.readInt(u32, view.bytes[base..][0..4], .little);
    const expected_groups = std.math.divCeil(
        u32,
        view.statistics.count,
        value_restart_interval,
    ) catch return error.InvalidPage;
    if (group_count != expected_groups) return error.InvalidPage;
    const directory_size = std.mem.alignForward(usize, 4 + @as(usize, group_count) * 4, 8);
    if (directory_size + 8 > view.values_size) return error.InvalidPage;
    if (!allZero(view.bytes[base + 4 + @as(usize, group_count) * 4 .. base + directory_size]))
        return error.InvalidPage;
    if (!authenticate) {
        const first_offset = std.mem.readInt(u32, view.bytes[base + 4 ..][0..4], .little);
        if (first_offset != directory_size) return error.InvalidPage;
        return;
    }

    var value_index: usize = 0;
    var cursor = directory_size;
    for (0..group_count) |group| {
        const encoded_offset = std.mem.readInt(
            u32,
            view.bytes[base + 4 + group * 4 ..][0..4],
            .little,
        );
        if (encoded_offset != cursor or base + cursor + 8 > end) return error.InvalidPage;
        cursor += 8;
        value_index += 1;
        const group_end = @min(value_index + value_restart_interval - 1, view.statistics.count);
        while (value_index < group_end) : (value_index += 1) {
            _ = try readVarint(view.bytes[base..end], &cursor);
        }
    }
    if (cursor != view.values_size or value_index != view.statistics.count)
        return error.InvalidPage;
}

fn readVarint(bytes: []const u8, cursor: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var byte_count: usize = 0;
    while (byte_count < 10) : (byte_count += 1) {
        if (cursor.* >= bytes.len) return error.InvalidPage;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 63 and byte > 1) return error.InvalidPage;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
    }
    return error.InvalidPage;
}

fn readVarintUnchecked(bytes: []const u8, cursor: *usize) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
    }
}

fn calculateStatistics(timestamps: []const i64, values: []const f64) Statistics {
    var minimum = std.math.nan(f64);
    var maximum = std.math.nan(f64);
    var sum: f64 = 0;
    for (values) |value| {
        if (!std.math.isNan(value)) {
            minimum = if (std.math.isNan(minimum)) value else @min(minimum, value);
            maximum = if (std.math.isNan(maximum)) value else @max(maximum, value);
            sum += value;
        }
    }
    return .{
        .count = @intCast(timestamps.len),
        .timestamp_min = timestamps[0],
        .timestamp_max = timestamps[timestamps.len - 1],
        .value_first = values[0],
        .value_last = values[values.len - 1],
        .value_min = minimum,
        .value_max = maximum,
        .value_sum = sum,
    };
}

fn calculateViewStatistics(view: View) Statistics {
    var minimum = std.math.nan(f64);
    var maximum = std.math.nan(f64);
    var sum: f64 = 0;
    var cursor = view.valueCursor(0);
    for (0..view.statistics.count) |_| {
        const value = cursor.next();
        if (!std.math.isNan(value)) {
            minimum = if (std.math.isNan(minimum)) value else @min(minimum, value);
            maximum = if (std.math.isNan(maximum)) value else @max(maximum, value);
            sum += value;
        }
    }
    return .{
        .count = view.statistics.count,
        .timestamp_min = view.timestampAt(0),
        .timestamp_max = view.timestampAt(view.statistics.count - 1),
        .value_first = view.valueAt(0),
        .value_last = view.valueAt(view.statistics.count - 1),
        .value_min = minimum,
        .value_max = maximum,
        .value_sum = sum,
    };
}

fn statisticsEqual(a: Statistics, b: Statistics) bool {
    return a.count == b.count and
        a.timestamp_min == b.timestamp_min and
        a.timestamp_max == b.timestamp_max and
        @as(u64, @bitCast(a.value_first)) == @as(u64, @bitCast(b.value_first)) and
        @as(u64, @bitCast(a.value_last)) == @as(u64, @bitCast(b.value_last)) and
        @as(u64, @bitCast(a.value_min)) == @as(u64, @bitCast(b.value_min)) and
        @as(u64, @bitCast(a.value_max)) == @as(u64, @bitCast(b.value_max)) and
        @as(u64, @bitCast(a.value_sum)) == @as(u64, @bitCast(b.value_sum));
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
    std.debug.assert(format.page_header_size % 8 == 0);
    std.debug.assert(records_max > 4_000);
}

test "dense timestamp pages round trip and select exact ranges" {
    var timestamps: [100]i64 = undefined;
    var values: [100]f64 = undefined;
    for (&timestamps, &values, 0..) |*timestamp, *value, index| {
        timestamp.* = @intCast(index * 10);
        value.* = @floatFromInt(index);
    }
    var buffer: [format.page_size]u8 = undefined;
    const encoded = try encode(&buffer, 7, &timestamps, &values);
    var duplicate_buffer: [format.page_size]u8 = undefined;
    const duplicate = try encode(&duplicate_buffer, 7, &timestamps, &values);
    try std.testing.expectEqualSlices(u8, encoded.bytes, duplicate.bytes);
    try std.testing.expect(checksum.equal(encoded.identity, duplicate.identity));
    try std.testing.expectEqual(TimestampCodec.base_step, encoded.timestamp_codec);
    try std.testing.expect(encoded.bytes.len < timestamps.len * 16);
    const view = try decode(encoded.bytes, encoded.identity);
    var found_timestamps: [4]i64 = undefined;
    var found_values: [4]f64 = undefined;
    const count = try view.rangeInto(215, 245, &found_timestamps, &found_values);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(i64, &.{ 220, 230, 240 }, found_timestamps[0..count]);
    try std.testing.expectEqualSlices(f64, &.{ 22, 23, 24 }, found_values[0..count]);
}

test "irregular timestamp pages validate order and statistics" {
    const timestamps = [_]i64{ 1, 3, 10, 11 };
    const values = [_]f64{ 4, -2, 8, 1 };
    var buffer: [format.page_size]u8 = undefined;
    const encoded = try encode(&buffer, 3, &timestamps, &values);
    try std.testing.expectEqual(TimestampCodec.raw, encoded.timestamp_codec);
    const view = try decode(encoded.bytes, encoded.identity);
    try std.testing.expectEqual(@as(f64, -2), view.statistics.value_min);
    try std.testing.expectEqual(@as(f64, 8), view.statistics.value_max);
    try std.testing.expectEqual(@as(f64, 11), view.statistics.value_sum);
}

test "page identity and semantic validation reject corruption" {
    var buffer: [format.page_size]u8 = undefined;
    const encoded = try encode(&buffer, 1, &.{ 1, 2, 3 }, &.{ 1, 2, 3 });
    const length = encoded.bytes.len;
    const identity = encoded.identity;
    buffer[length - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(buffer[0..length], identity));

    const raw = try encodeWithOptions(&buffer, 1, &.{ 1, 3, 7 }, &.{ 1, 2, 3 }, false);
    const raw_length = raw.bytes.len;
    std.mem.writeInt(i64, buffer[format.page_header_size + 8 ..][0..8], 1, .little);
    const forged_identity = checksum.calculate(buffer[0..raw_length]);
    try std.testing.expectError(
        error.InvalidPage,
        decode(buffer[0..raw_length], forged_identity),
    );
}

test "irregular timestamps and smooth values use bounded restart codecs" {
    var timestamps: [512]i64 = undefined;
    var values: [512]f64 = undefined;
    var timestamp: i64 = 0;
    for (&timestamps, &values, 0..) |*stored_timestamp, *value, value_index| {
        timestamp += @intCast(value_index % 97 + 1);
        stored_timestamp.* = timestamp;
        value.* = 20.0 + @as(f64, @floatFromInt(value_index % 100)) * 0.001;
    }
    var buffer: [format.page_size]u8 = undefined;
    const encoded = try encode(&buffer, 9, &timestamps, &values);
    try std.testing.expectEqual(TimestampCodec.delta_varint, encoded.timestamp_codec);
    try std.testing.expectEqual(ValueCodec.xor_varint, encoded.value_codec);
    const view = try decode(encoded.bytes, encoded.identity);
    for (0..timestamps.len) |value_index| {
        try std.testing.expectEqual(timestamps[value_index], view.timestampAt(value_index));
        try std.testing.expectEqual(
            @as(u64, @bitCast(values[value_index])),
            @as(u64, @bitCast(view.valueAt(value_index))),
        );
    }
}
