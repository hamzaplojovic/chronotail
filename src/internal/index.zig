const std = @import("std");
const checksum = @import("checksum.zig");
const format = @import("format.zig");
const page = @import("page.zig");

pub const entry_size: usize = 96;
pub const entry_capacity: usize = (format.index_node_size - format.page_header_size) /
    entry_size;
pub const height_max: usize = 8;

pub const Summary = struct {
    timestamp_min: i64,
    timestamp_max: i64,
    point_count: u64,
    value_min: f64,
    value_max: f64,
    value_sum: f64,
    value_first: f64,
    value_last: f64,

    pub fn fromPage(statistics: page.Statistics) Summary {
        return .{
            .timestamp_min = statistics.timestamp_min,
            .timestamp_max = statistics.timestamp_max,
            .point_count = statistics.count,
            .value_min = statistics.value_min,
            .value_max = statistics.value_max,
            .value_sum = statistics.value_sum,
            .value_first = statistics.value_first,
            .value_last = statistics.value_last,
        };
    }
};

pub const Entry = struct {
    pointer: format.Pointer,
    summary: Summary,
};

pub const Node = struct {
    level: u8,
    series_id: u32,
    count: u16,
    summary: Summary,
    entries: [entry_capacity]Entry = undefined,

    pub fn slice(self: *const Node) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn lowerBound(self: *const Node, timestamp: i64) u16 {
        var low: usize = 0;
        var high: usize = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.entries[middle].summary.timestamp_max < timestamp) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return @intCast(low);
    }
};

pub const View = struct {
    bytes: *const [format.index_node_size]u8,
    level: u8,
    series_id: u32,
    count: u16,
    summary: Summary,

    pub fn entryAt(self: View, entry_index: usize) Entry {
        std.debug.assert(entry_index < self.count);
        const start = format.page_header_size + entry_index * entry_size;
        return decodeEntry(self.bytes[start..][0..entry_size]) catch unreachable;
    }

    pub fn lowerBound(self: View, timestamp: i64) u16 {
        var low: usize = 0;
        var high: usize = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const start = format.page_header_size + middle * entry_size;
            const timestamp_max = std.mem.readInt(i64, self.bytes[start + 40 ..][0..8], .little);
            if (timestamp_max < timestamp) low = middle + 1 else high = middle;
        }
        return @intCast(low);
    }
};

pub fn view(
    bytes: *const [format.index_node_size]u8,
    expected: format.Pointer,
    committed_size: u64,
    authenticate: bool,
) !View {
    if (authenticate) {
        const node = try decode(bytes, expected, committed_size);
        return .{
            .bytes = bytes,
            .level = node.level,
            .series_id = node.series_id,
            .count = node.count,
            .summary = node.summary,
        };
    }
    if (expected.kind != .index or expected.size != format.index_node_size)
        return error.InvalidIndex;
    try expected.validate(committed_size);
    if (!std.mem.eql(u8, bytes[0..8], format.index_magic)) return error.InvalidIndex;
    const level = bytes[8];
    const count = std.mem.readInt(u16, bytes[10..12], .little);
    if (level >= height_max or count == 0 or count > entry_capacity)
        return error.InvalidIndex;
    return .{
        .bytes = bytes,
        .level = level,
        .series_id = std.mem.readInt(u32, bytes[12..16], .little),
        .count = count,
        .summary = decodeSummary(bytes[16..80]),
    };
}

pub fn dataEntry(pointer: format.Pointer, statistics: page.Statistics) !Entry {
    if (pointer.kind != .data) return error.InvalidPointer;
    return .{ .pointer = pointer, .summary = Summary.fromPage(statistics) };
}

pub fn encode(node: *Node, output: *[format.index_node_size]u8) !void {
    if (node.count == 0 or node.count > entry_capacity) return error.InvalidIndex;
    if (node.level >= height_max) return error.InvalidIndex;
    node.summary = try encodeEntries(
        node.level,
        node.series_id,
        node.slice(),
        output,
    );
}

fn encodeEntries(
    level: u8,
    series_id: u32,
    entries: []const Entry,
    output: *[format.index_node_size]u8,
) !Summary {
    if (entries.len == 0 or entries.len > entry_capacity) return error.InvalidIndex;
    if (level >= height_max) return error.InvalidIndex;
    const summary = try summarize(entries);
    @memset(output, 0);
    @memcpy(output[0..8], format.index_magic);
    output[8] = level;
    std.mem.writeInt(u16, output[10..12], @intCast(entries.len), .little);
    std.mem.writeInt(u32, output[12..16], series_id, .little);
    encodeSummary(summary, output[16..80]);
    for (entries, 0..) |entry, index| {
        const start = format.page_header_size + index * entry_size;
        encodeEntry(entry, output[start..][0..entry_size]);
    }
    return summary;
}

pub fn decode(
    bytes: *const [format.index_node_size]u8,
    expected: format.Pointer,
    committed_size: u64,
) !Node {
    return decodeInternal(bytes, expected, committed_size, true);
}

pub fn decodeKnown(
    bytes: *const [format.index_node_size]u8,
    expected: format.Pointer,
    committed_size: u64,
) !Node {
    return decodeInternal(bytes, expected, committed_size, false);
}

fn decodeInternal(
    bytes: *const [format.index_node_size]u8,
    expected: format.Pointer,
    committed_size: u64,
    authenticate: bool,
) !Node {
    if (expected.kind != .index or expected.size != format.index_node_size)
        return error.InvalidIndex;
    try expected.validate(committed_size);
    if (authenticate and !checksum.equal(checksum.calculate(bytes), expected.identity))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0..8], format.index_magic)) return error.InvalidIndex;
    if (bytes[9] != 0 or !allZero(bytes[80..format.page_header_size]))
        return error.InvalidIndex;
    const level = bytes[8];
    if (level >= height_max) return error.InvalidIndex;
    const count = std.mem.readInt(u16, bytes[10..12], .little);
    if (count == 0 or count > entry_capacity) return error.InvalidIndex;
    var node = Node{
        .level = level,
        .series_id = std.mem.readInt(u32, bytes[12..16], .little),
        .count = count,
        .summary = decodeSummary(bytes[16..80]),
    };
    var calculated_summary: ?Summary = null;
    for (0..count) |index| {
        const start = format.page_header_size + index * entry_size;
        node.entries[index] = try decodeEntry(bytes[start..][0..entry_size]);
        const required_kind: format.PointerKind = if (level == 0) .data else .index;
        if (node.entries[index].pointer.kind != required_kind) return error.InvalidIndex;
        try node.entries[index].pointer.validate(committed_size);
        if (node.entries[index].summary.point_count == 0 or
            node.entries[index].summary.timestamp_min > node.entries[index].summary.timestamp_max)
            return error.InvalidIndex;
        if (calculated_summary) |*summary| {
            extendSummary(summary, node.entries[index].summary) catch |err| switch (err) {
                error.TimestampNotIncreasing => return error.InvalidIndex,
                else => return err,
            };
        } else {
            calculated_summary = node.entries[index].summary;
        }
    }
    const used_end = format.page_header_size + @as(usize, count) * entry_size;
    if (!allZero(bytes[used_end..])) return error.InvalidIndex;
    if (!summaryEqual(calculated_summary.?, node.summary)) return error.InvalidIndex;
    return node;
}

pub const AppendResult = struct {
    root: Entry,
    spine_depth: u8,
};

pub fn append(
    file: anytype,
    allocator: std.mem.Allocator,
    write_offset: *u64,
    committed_size: u64,
    series_id: u32,
    old_root: ?Entry,
    new_data_entries: []const Entry,
) !Entry {
    var spine: [height_max]Node = undefined;
    return (try appendWithSpine(
        file,
        allocator,
        write_offset,
        committed_size,
        series_id,
        old_root,
        null,
        new_data_entries,
        &spine,
    )).root;
}

pub fn appendedSpineDepth(spine: []const Node, new_entry_count: usize) !usize {
    if (spine.len == 0 or spine.len > height_max or new_entry_count == 0)
        return error.InvalidIndex;
    for (spine) |node| {
        if (node.count == 0 or node.count > entry_capacity or node.level >= height_max)
            return error.InvalidIndex;
    }
    const leaf_entry_count = std.math.add(
        usize,
        spine[spine.len - 1].count,
        new_entry_count,
    ) catch return error.IndexTooLarge;
    var node_count = std.math.divCeil(
        usize,
        leaf_entry_count,
        entry_capacity,
    ) catch return error.IndexTooLarge;
    var spine_index = spine.len - 1;
    while (spine_index > 0) {
        spine_index -= 1;
        const entry_count = std.math.add(
            usize,
            spine[spine_index].count - 1,
            node_count,
        ) catch return error.IndexTooLarge;
        node_count = std.math.divCeil(usize, entry_count, entry_capacity) catch
            return error.IndexTooLarge;
    }
    var depth = spine.len;
    while (node_count > 1) {
        if (depth == height_max) return error.IndexTooDeep;
        node_count = std.math.divCeil(usize, node_count, entry_capacity) catch
            return error.IndexTooLarge;
        depth += 1;
    }
    return depth;
}

pub fn appendWithSpine(
    file: anytype,
    allocator: std.mem.Allocator,
    write_offset: *u64,
    committed_size: u64,
    series_id: u32,
    old_root: ?Entry,
    old_spine: ?[]const Node,
    new_data_entries: []const Entry,
    output_spine: []Node,
) !AppendResult {
    if (new_data_entries.len == 0) return error.EmptyIndex;
    try validateEntries(new_data_entries, .data);
    var stack_allocator = std.heap.stackFallback(8 * 1024, allocator);
    const scratch_allocator = stack_allocator.get();
    var current: std.ArrayList(Entry) = .empty;
    defer current.deinit(scratch_allocator);
    var new_spine_by_level: [height_max]Node = undefined;

    if (old_root) |root| {
        var loaded_spine: [height_max]Node = undefined;
        const spine = if (old_spine) |cached| blk: {
            try validateRightSpine(cached, root, series_id);
            break :blk cached;
        } else blk: {
            const depth = try loadRightSpine(
                file,
                root,
                committed_size,
                series_id,
                &loaded_spine,
            );
            break :blk loaded_spine[0..depth];
        };
        const write_in_place = old_spine != null and spine.ptr == output_spine.ptr;
        const predicted_depth = if (write_in_place)
            try appendedSpineDepth(spine, new_data_entries.len)
        else
            0;
        if (write_in_place and output_spine.len < predicted_depth)
            return error.IndexTooDeep;
        const leaf = &spine[spine.len - 1];
        try current.ensureTotalCapacity(scratch_allocator, leaf.count + new_data_entries.len);
        current.appendSliceAssumeCapacity(leaf.slice());
        current.appendSliceAssumeCapacity(new_data_entries);
        try validateEntries(current.items, .data);
        var next = try writeLevel(
            file,
            scratch_allocator,
            write_offset,
            series_id,
            0,
            current.items,
            if (write_in_place)
                &output_spine[predicted_depth - 1]
            else
                &new_spine_by_level[0],
        );
        defer next.deinit(scratch_allocator);

        var spine_index = spine.len - 1;
        var root_level = spine[0].level;
        while (spine_index > 0) {
            spine_index -= 1;
            const parent = &spine[spine_index];
            current.clearRetainingCapacity();
            try current.ensureTotalCapacity(
                scratch_allocator,
                parent.count - 1 + next.items.len,
            );
            current.appendSliceAssumeCapacity(parent.slice()[0 .. parent.count - 1]);
            current.appendSliceAssumeCapacity(next.items);
            const replacement = try writeLevel(
                file,
                scratch_allocator,
                write_offset,
                series_id,
                parent.level,
                current.items,
                if (write_in_place)
                    &output_spine[predicted_depth - 1 - parent.level]
                else
                    &new_spine_by_level[parent.level],
            );
            next.deinit(scratch_allocator);
            next = replacement;
        }
        while (next.items.len > 1) {
            if (root_level == height_max - 1) return error.IndexTooDeep;
            root_level = try std.math.add(u8, root_level, 1);
            const replacement = try writeLevel(
                file,
                scratch_allocator,
                write_offset,
                series_id,
                root_level,
                next.items,
                if (write_in_place)
                    &output_spine[predicted_depth - 1 - root_level]
                else
                    &new_spine_by_level[root_level],
            );
            next.deinit(scratch_allocator);
            next = replacement;
        }
        const new_depth: usize = @as(usize, root_level) + 1;
        if (output_spine.len < new_depth) return error.IndexTooDeep;
        if (!write_in_place) {
            for (0..new_depth) |spine_offset| {
                output_spine[spine_offset] = new_spine_by_level[root_level - spine_offset];
            }
        } else {
            std.debug.assert(new_depth == predicted_depth);
        }
        return .{ .root = next.items[0], .spine_depth = @intCast(new_depth) };
    }

    current.appendSlice(scratch_allocator, new_data_entries) catch return error.OutOfMemory;
    var level: u8 = 0;
    var next = try writeLevel(
        file,
        scratch_allocator,
        write_offset,
        series_id,
        level,
        current.items,
        &new_spine_by_level[level],
    );
    defer next.deinit(scratch_allocator);
    while (next.items.len > 1) {
        if (level == height_max - 1) return error.IndexTooDeep;
        level = try std.math.add(u8, level, 1);
        const replacement = try writeLevel(
            file,
            scratch_allocator,
            write_offset,
            series_id,
            level,
            next.items,
            &new_spine_by_level[level],
        );
        next.deinit(scratch_allocator);
        next = replacement;
    }
    const new_depth: usize = @as(usize, level) + 1;
    if (output_spine.len < new_depth) return error.IndexTooDeep;
    for (0..new_depth) |spine_offset| {
        output_spine[spine_offset] = new_spine_by_level[level - spine_offset];
    }
    return .{ .root = next.items[0], .spine_depth = @intCast(new_depth) };
}

fn loadRightSpine(
    file: anytype,
    root: Entry,
    committed_size: u64,
    series_id: u32,
    output: *[height_max]Node,
) !usize {
    var pointer = root.pointer;
    var expected_summary = root.summary;
    var expected_level: ?u8 = null;
    var depth: usize = 0;
    while (true) {
        if (depth == output.len) return error.IndexTooDeep;
        var bytes: [format.index_node_size]u8 = undefined;
        if (try file.preadAll(&bytes, pointer.offset) != bytes.len) return error.InvalidIndex;
        output[depth] = try decode(&bytes, pointer, committed_size);
        depth += 1;
        const node = &output[depth - 1];
        if (node.series_id != series_id or !summaryEqual(node.summary, expected_summary))
            return error.InvalidIndex;
        if (expected_level) |level| if (node.level != level) return error.InvalidIndex;
        if (node.level == 0) return depth;
        const child = node.entries[node.count - 1];
        pointer = child.pointer;
        expected_summary = child.summary;
        expected_level = node.level - 1;
    }
}

fn validateRightSpine(spine: []const Node, root: Entry, series_id: u32) !void {
    if (spine.len == 0 or spine.len > height_max) return error.InvalidIndex;
    if (spine[0].series_id != series_id or
        !summaryEqual(spine[0].summary, root.summary)) return error.InvalidIndex;
    for (spine, 0..) |node, node_index| {
        if (node.series_id != series_id or node.count == 0 or
            node.count > entry_capacity or node.level >= height_max) return error.InvalidIndex;
        if (node_index + 1 == spine.len) {
            if (node.level != 0) return error.InvalidIndex;
            continue;
        }
        const child = spine[node_index + 1];
        const expected = node.entries[node.count - 1];
        if (node.level != child.level + 1 or
            !summaryEqual(expected.summary, child.summary)) return error.InvalidIndex;
    }
}

fn writeLevel(
    file: anytype,
    allocator: std.mem.Allocator,
    write_offset: *u64,
    series_id: u32,
    level: u8,
    entries: []const Entry,
    rightmost: *Node,
) !std.ArrayList(Entry) {
    if (entries.len == 0) return error.EmptyIndex;
    const node_count = std.math.divCeil(usize, entries.len, entry_capacity) catch
        return error.IndexTooLarge;
    var result: std.ArrayList(Entry) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, node_count);
    const encoded_size = std.math.mul(usize, node_count, format.index_node_size) catch
        return error.IndexTooLarge;
    var single_node: [format.index_node_size]u8 = undefined;
    const encoded_nodes = if (node_count == 1)
        single_node[0..]
    else
        try allocator.alloc(u8, encoded_size);
    defer if (node_count > 1) allocator.free(encoded_nodes);
    const base_offset = std.mem.alignForward(u64, write_offset.*, 8);
    var entry_offset: usize = 0;
    var node_index: usize = 0;
    while (entry_offset < entries.len) {
        const end = @min(entry_offset + entry_capacity, entries.len);
        const group = entries[entry_offset..end];
        const encoded_offset = node_index * format.index_node_size;
        const bytes: *[format.index_node_size]u8 =
            @ptrCast(encoded_nodes[encoded_offset..][0..format.index_node_size].ptr);
        const summary = try encodeEntries(level, series_id, group, bytes);
        if (end == entries.len) {
            rightmost.* = .{
                .level = level,
                .series_id = series_id,
                .count = @intCast(group.len),
                .summary = summary,
            };
            @memcpy(rightmost.entries[0..group.len], group);
        }
        const node_offset = std.math.add(u64, base_offset, encoded_offset) catch
            return error.IndexTooLarge;
        const pointer = format.Pointer{
            .offset = node_offset,
            .size = format.index_node_size,
            .kind = .index,
            .identity = checksum.calculate(bytes),
        };
        result.appendAssumeCapacity(.{ .pointer = pointer, .summary = summary });
        entry_offset = end;
        node_index += 1;
    }
    std.debug.assert(node_index == node_count);
    try file.pwriteAll(encoded_nodes, base_offset);
    write_offset.* = std.math.add(u64, base_offset, encoded_size) catch
        return error.IndexTooLarge;
    return result;
}

fn summarize(entries: []const Entry) !Summary {
    if (entries.len == 0) return error.EmptyIndex;
    var summary = entries[0].summary;
    for (entries[1..]) |entry| {
        try extendSummary(&summary, entry.summary);
    }
    return summary;
}

fn extendSummary(summary: *Summary, next: Summary) !void {
    if (next.timestamp_min <= summary.timestamp_max)
        return error.TimestampNotIncreasing;
    summary.timestamp_max = next.timestamp_max;
    summary.point_count = std.math.add(
        u64,
        summary.point_count,
        next.point_count,
    ) catch return error.IndexTooLarge;
    summary.value_min = minimum(summary.value_min, next.value_min);
    summary.value_max = maximum(summary.value_max, next.value_max);
    summary.value_sum += next.value_sum;
    summary.value_last = next.value_last;
}

fn validateEntries(entries: []const Entry, kind: format.PointerKind) !void {
    if (entries.len == 0) return error.EmptyIndex;
    for (entries, 0..) |entry, index| {
        if (entry.pointer.kind != kind) return error.InvalidIndex;
        if (entry.summary.point_count == 0 or
            entry.summary.timestamp_min > entry.summary.timestamp_max)
        {
            return error.InvalidIndex;
        }
        if (index > 0 and
            entries[index - 1].summary.timestamp_max >= entry.summary.timestamp_min)
        {
            return error.TimestampNotIncreasing;
        }
    }
}

fn encodeEntry(entry: Entry, output: *[entry_size]u8) void {
    var pointer_bytes: [format.pointer_size]u8 = undefined;
    entry.pointer.encode(&pointer_bytes);
    @memcpy(output[0..format.pointer_size], &pointer_bytes);
    encodeSummary(entry.summary, output[format.pointer_size..entry_size]);
}

fn decodeEntry(input: *const [entry_size]u8) !Entry {
    return .{
        .pointer = try format.Pointer.decode(input[0..format.pointer_size]),
        .summary = decodeSummary(input[format.pointer_size..entry_size]),
    };
}

fn encodeSummary(summary: Summary, output: []u8) void {
    std.debug.assert(output.len >= 48);
    std.mem.writeInt(i64, output[0..8], summary.timestamp_min, .little);
    std.mem.writeInt(i64, output[8..16], summary.timestamp_max, .little);
    std.mem.writeInt(u64, output[16..24], summary.point_count, .little);
    writeFloat(output[24..32], summary.value_min);
    writeFloat(output[32..40], summary.value_max);
    writeFloat(output[40..48], summary.value_sum);
    if (output.len >= 64) {
        writeFloat(output[48..56], summary.value_first);
        writeFloat(output[56..64], summary.value_last);
    }
}

fn decodeSummary(input: []const u8) Summary {
    std.debug.assert(input.len >= 48);
    return .{
        .timestamp_min = std.mem.readInt(i64, input[0..8], .little),
        .timestamp_max = std.mem.readInt(i64, input[8..16], .little),
        .point_count = std.mem.readInt(u64, input[16..24], .little),
        .value_min = readFloat(input[24..32]),
        .value_max = readFloat(input[32..40]),
        .value_sum = readFloat(input[40..48]),
        .value_first = if (input.len >= 64) readFloat(input[48..56]) else 0,
        .value_last = if (input.len >= 64) readFloat(input[56..64]) else 0,
    };
}

fn summaryEqual(a: Summary, b: Summary) bool {
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
    std.debug.assert(entry_capacity >= 32);
    std.debug.assert(format.page_header_size + entry_capacity * entry_size <=
        format.index_node_size);
}

test "appended spine depth grows only when parent capacity requires it" {
    const leaf = Node{
        .level = 0,
        .series_id = 1,
        .count = entry_capacity,
        .summary = undefined,
    };
    try std.testing.expectEqual(@as(usize, 2), try appendedSpineDepth(&.{leaf}, 1));

    const root = Node{
        .level = 1,
        .series_id = 1,
        .count = entry_capacity,
        .summary = undefined,
    };
    try std.testing.expectEqual(
        @as(usize, 2),
        try appendedSpineDepth(&.{ root, leaf }, 1),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        try appendedSpineDepth(&.{ root, leaf }, entry_capacity * entry_capacity),
    );
    try std.testing.expectError(error.InvalidIndex, appendedSpineDepth(&.{leaf}, 0));
}

test "index nodes round trip and authenticate children externally" {
    var node = Node{
        .level = 0,
        .series_id = 7,
        .count = 2,
        .summary = undefined,
    };
    node.entries[0] = testEntry(1, 10, format.control_size, .data);
    node.entries[1] = testEntry(11, 20, format.control_size + 100, .data);
    node.summary = try summarize(node.slice());
    var bytes: [format.index_node_size]u8 = undefined;
    try encode(&node, &bytes);
    var duplicate: [format.index_node_size]u8 = undefined;
    try encode(&node, &duplicate);
    try std.testing.expectEqualSlices(u8, &bytes, &duplicate);
    const pointer = format.Pointer{
        .offset = format.control_size + 1_000,
        .size = format.index_node_size,
        .kind = .index,
        .identity = checksum.calculate(&bytes),
    };
    const decoded = try decode(&bytes, pointer, format.control_size + 10_000);
    try std.testing.expectEqual(@as(u16, 2), decoded.count);
    try std.testing.expectEqual(@as(u16, 0), decoded.lowerBound(10));
    try std.testing.expectEqual(@as(u16, 1), decoded.lowerBound(11));
    try std.testing.expectEqual(@as(u16, 2), decoded.lowerBound(21));
    bytes[format.page_header_size + 5] ^= 1;
    try std.testing.expectError(
        error.ChecksumMismatch,
        decode(&bytes, pointer, format.control_size + 10_000),
    );

    try encode(&node, &bytes);
    std.mem.writeInt(i64, bytes[format.page_header_size + entry_size + 32 ..][0..8], 5, .little);
    var forged_pointer = pointer;
    forged_pointer.identity = checksum.calculate(&bytes);
    try std.testing.expectError(
        error.InvalidIndex,
        decode(&bytes, forged_pointer, format.control_size + 10_000),
    );

    try encode(&node, &bytes);
    std.mem.writeInt(
        u64,
        bytes[format.page_header_size + format.pointer_size + 16 ..][0..8],
        0,
        .little,
    );
    std.mem.writeInt(u64, bytes[32..40], 10, .little);
    forged_pointer.identity = checksum.calculate(&bytes);
    try std.testing.expectError(
        error.InvalidIndex,
        decode(&bytes, forged_pointer, format.control_size + 10_000),
    );
}

test "persistent append rewrites only the right spine" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile("index.ctdb", .{ .read = true });
    defer file.close();
    var prefix: [format.control_size + 128]u8 = [_]u8{0} ** (format.control_size + 128);
    try file.writeAll(&prefix);

    var entries: [100]Entry = undefined;
    for (&entries, 0..) |*entry, entry_index| {
        entry.* = testEntry(
            @intCast(entry_index * 10),
            @intCast(entry_index * 10 + 9),
            format.control_size,
            .data,
        );
    }
    var write_offset: u64 = prefix.len;
    const first_root = try append(
        file,
        std.testing.allocator,
        &write_offset,
        prefix.len,
        1,
        null,
        &entries,
    );
    var first_root_bytes: [format.index_node_size]u8 = undefined;
    try std.testing.expectEqual(
        first_root_bytes.len,
        try file.preadAll(&first_root_bytes, first_root.pointer.offset),
    );
    const first_node = try decode(&first_root_bytes, first_root.pointer, try file.getEndPos());
    try std.testing.expect(summaryEqual(first_root.summary, first_node.summary));
    try std.testing.expectEqual(@as(u8, 1), first_node.level);

    var extra: [30]Entry = undefined;
    for (&extra, 100..) |*entry, entry_index| {
        entry.* = testEntry(
            @intCast(entry_index * 10),
            @intCast(entry_index * 10 + 9),
            format.control_size,
            .data,
        );
    }
    const offset_before_append = write_offset;
    const second_root = try append(
        file,
        std.testing.allocator,
        &write_offset,
        offset_before_append,
        1,
        first_root,
        &extra,
    );
    try std.testing.expect(second_root.pointer.offset >= offset_before_append);
    try std.testing.expect(second_root.pointer.offset != first_root.pointer.offset);
    var second_root_bytes: [format.index_node_size]u8 = undefined;
    try std.testing.expectEqual(
        second_root_bytes.len,
        try file.preadAll(&second_root_bytes, second_root.pointer.offset),
    );
    const second_node = try decode(&second_root_bytes, second_root.pointer, try file.getEndPos());
    try std.testing.expect(summaryEqual(second_root.summary, second_node.summary));
    try std.testing.expectEqual(@as(u64, 1_300), second_node.summary.point_count);
    try std.testing.expectEqual(@as(i64, 1_299), second_node.summary.timestamp_max);
}

fn testEntry(
    timestamp_min: i64,
    timestamp_max: i64,
    offset: u64,
    kind: format.PointerKind,
) Entry {
    return .{
        .pointer = .{
            .offset = offset,
            .size = 64,
            .kind = kind,
            .identity = checksum.calculate("child"),
        },
        .summary = .{
            .timestamp_min = timestamp_min,
            .timestamp_max = timestamp_max,
            .point_count = @intCast(timestamp_max - timestamp_min + 1),
            .value_min = 0,
            .value_max = 1,
            .value_sum = 1,
            .value_first = 0,
            .value_last = 1,
        },
    };
}
