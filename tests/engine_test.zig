const std = @import("std");
const chronotail = @import("chronotail");

test "short trailing bytes return corruption instead of entering trailer scan out of bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    inline for (1..8) |trailing_count| {
        const name = try std.fmt.allocPrint(
            std.testing.allocator,
            "short-{d}.ctdb",
            .{trailing_count},
        );
        defer std.testing.allocator.free(name);
        const file = try temporary.dir.createFile(name, .{ .read = true });
        try file.writeAll(&chronotail.file_header);
        try file.writeAll(&([_]u8{0} ** trailing_count));
        try file.seekTo(0);
        try std.testing.expectError(
            error.InvalidDatabase,
            chronotail.Reader.openOn(std.testing.allocator, file),
        );
    }
}

test "checkpoint reopen and range round trip" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const file = try temporary.dir.createFile("test.ctdb", .{ .read = true });
    var writer = try chronotail.Appender.createOn(std.testing.allocator, file, .compressed);
    const timestamps = [_]i64{ 10, 20, 30 };
    const values = [_]f64{ 1.5, 2.5, 3.5 };
    try writer.appendBatch("cpu", &timestamps, &values);
    try writer.checkpoint(false);
    try writer.close();

    const reopened = try temporary.dir.openFile("test.ctdb", .{});
    var reader = try chronotail.Reader.openOn(std.testing.allocator, reopened);
    defer reader.close();
    var found_timestamps: [3]i64 = undefined;
    var found_values: [3]f64 = undefined;
    const count = try reader.rangeInto("cpu", 0, 100, &found_timestamps, &found_values);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(i64, &timestamps, &found_timestamps);
    try std.testing.expectEqualSlices(f64, &values, &found_values);
}

test "mapped reader refreshes to a newly checkpointed snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "mapped.ctdb" });
    defer std.testing.allocator.free(path);

    var initial = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    try initial.append("cpu", 1, 1);
    try initial.checkpoint(false);
    try initial.close();

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var writer = try chronotail.Appender.open(std.testing.allocator, path, .raw);
    try writer.append("cpu", 2, 2);
    try writer.checkpoint(false);
    try std.testing.expect(try reader.refresh());
    var timestamps: [2]i64 = undefined;
    var values: [2]f64 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        try reader.rangeInto("cpu", 1, 2, &timestamps, &values),
    );
    try writer.close();
}

test "prepared timestamp mapping handles block boundaries and missing timestamps" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "mapping.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    var timestamps: [10_000]i64 = undefined;
    var values: [10_000]f64 = undefined;
    for (&timestamps, &values, 0..) |*timestamp, *value, index| {
        timestamp.* = @intCast(index * 10);
        value.* = @floatFromInt(index);
    }
    try writer.appendBatch("cpu", &timestamps, &values);
    try writer.close();

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var found_timestamps: [2]i64 = undefined;
    var found_values: [2]f64 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try reader.rangeInto("cpu", 15, 25, &found_timestamps, &found_values),
    );
    try std.testing.expectEqual(@as(i64, 20), found_timestamps[0]);
    try std.testing.expectEqual(
        @as(usize, 2),
        try reader.rangeInto("cpu", 40_920, 40_930, &found_timestamps, &found_values),
    );
    try std.testing.expectEqualSlices(i64, &.{ 40_920, 40_930 }, &found_timestamps);
}

test "reader rejects checksummed raw blocks with unordered interior timestamps" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "unordered.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    try writer.appendBatch("cpu", &.{ 1, 2, 3 }, &.{ 1, 2, 3 });
    try writer.close();

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const block_offset = chronotail.file_header.len;
    var payload: [3 * chronotail.record_size]u8 = undefined;
    try std.testing.expectEqual(
        payload.len,
        try file.preadAll(&payload, block_offset + chronotail.block_header_size),
    );
    std.mem.writeInt(i64, payload[chronotail.record_size..][0..8], 0, .little);
    try file.pwriteAll(&payload, block_offset + chronotail.block_header_size);
    var checksum_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &checksum_bytes, testChecksum(&payload), .little);
    try file.pwriteAll(&checksum_bytes, block_offset + 40);

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var timestamps: [3]i64 = undefined;
    var values: [3]f64 = undefined;
    try std.testing.expectError(
        error.InvalidDatabase,
        reader.rangeInto("cpu", 1, 3, &timestamps, &values),
    );
}

fn testChecksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

test "batch timestamp validation is all-or-nothing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const file = try temporary.dir.createFile("batch.ctdb", .{ .read = true });
    var writer = try chronotail.Appender.createOn(std.testing.allocator, file, .raw);
    defer writer.abort();
    const timestamps = [_]i64{ 2, 1 };
    const values = [_]f64{ 2, 1 };
    try std.testing.expectError(
        error.TimestampNotIncreasing,
        writer.appendBatch("cpu", &timestamps, &values),
    );
    try writer.append("cpu", 1, 1);
}
