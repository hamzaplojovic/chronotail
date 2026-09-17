const std = @import("std");
const chronotail = @import("chronotail");

test "torn control regions are rejected" {
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

test "reader rejects a corrupted immutable page" {
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
    const block_offset = chronotail.block_size;
    var timestamp_bytes: [8]u8 = undefined;
    try std.testing.expectEqual(
        timestamp_bytes.len,
        try file.preadAll(
            &timestamp_bytes,
            block_offset + chronotail.block_header_size + 8,
        ),
    );
    timestamp_bytes[0] ^= 1;
    try file.pwriteAll(
        &timestamp_bytes,
        block_offset + chronotail.block_header_size + 8,
    );

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var timestamps: [3]i64 = undefined;
    var values: [3]f64 = undefined;
    try std.testing.expectError(
        error.ChecksumMismatch,
        reader.rangeInto("cpu", 1, 3, &timestamps, &values),
    );
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

test "prepared handles and aggregate summaries follow snapshot generations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "aggregate.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .compressed);
    try writer.appendBatch("cpu", &.{ 1, 2, 3, 4 }, &.{ 4, 1, 8, 3 });
    try writer.checkpoint(false);
    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    const handle = try reader.prepare("cpu");
    const aggregate = try reader.aggregatePrepared(handle, 2, 4);
    try std.testing.expectEqual(@as(u64, 3), aggregate.count);
    try std.testing.expectEqual(@as(f64, 1), aggregate.minimum);
    try std.testing.expectEqual(@as(f64, 8), aggregate.maximum);
    try std.testing.expectEqual(@as(f64, 12), aggregate.sum);
    try std.testing.expectEqual(@as(f64, 1), aggregate.first);
    try std.testing.expectEqual(@as(f64, 3), aggregate.last);

    var windows: [2]chronotail.Aggregate = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        try reader.aggregateWindowsPrepared(handle, 1, 4, 2, &windows),
    );
    try std.testing.expectEqual(@as(u64, 2), windows[0].count);
    try std.testing.expectEqual(@as(f64, 5), windows[0].sum);
    try std.testing.expectEqual(@as(u64, 2), windows[1].count);
    try std.testing.expectEqual(@as(f64, 11), windows[1].sum);

    try writer.append("cpu", 5, 9);
    try writer.checkpoint(false);
    try std.testing.expect(try reader.refresh());
    var timestamps: [1]i64 = undefined;
    var values: [1]f64 = undefined;
    try std.testing.expectError(
        error.StaleSeriesHandle,
        reader.rangePreparedInto(handle, 5, 5, &timestamps, &values),
    );
    try writer.close();
}

test "aggregate windows match a multi-page oracle for raw and compressed data" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);

    const point_count: usize = 12_000;
    const timestamps = try std.testing.allocator.alloc(i64, point_count);
    defer std.testing.allocator.free(timestamps);
    const values = try std.testing.allocator.alloc(f64, point_count);
    defer std.testing.allocator.free(values);
    for (timestamps, values, 0..) |*timestamp, *value, point_index| {
        timestamp.* = -50_000 + @as(i64, @intCast(point_index * 7));
        value.* = @floatFromInt(point_index % 29);
    }

    inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
        const filename = if (codec == .raw) "windows-raw.ctdb" else "windows-compressed.ctdb";
        const path = try std.fs.path.join(std.testing.allocator, &.{ directory, filename });
        defer std.testing.allocator.free(path);
        var writer = try chronotail.Appender.create(std.testing.allocator, path, codec);
        try writer.appendBatch("cpu", timestamps, values);
        try writer.close();

        var reader = try chronotail.Reader.open(std.testing.allocator, path);
        defer reader.close();
        const handle = try reader.prepare("cpu");
        const start = timestamps[113];
        const end = timestamps[point_count - 79];
        const resolution: u64 = 7_777;
        const span: u64 = @intCast(end - start);
        const expected_count: usize = @intCast(span / resolution + 1);
        const actual = try std.testing.allocator.alloc(chronotail.Aggregate, expected_count);
        defer std.testing.allocator.free(actual);
        const expected = try std.testing.allocator.alloc(chronotail.Aggregate, expected_count);
        defer std.testing.allocator.free(expected);
        @memset(expected, chronotail.Aggregate{});
        for (timestamps, values) |timestamp, value| {
            if (timestamp < start or timestamp > end) continue;
            const bucket: usize = @intCast(@as(u64, @intCast(timestamp - start)) / resolution);
            var aggregate = &expected[bucket];
            if (aggregate.count == 0) aggregate.first = value;
            aggregate.last = value;
            aggregate.minimum = if (std.math.isNan(aggregate.minimum))
                value
            else
                @min(aggregate.minimum, value);
            aggregate.maximum = if (std.math.isNan(aggregate.maximum))
                value
            else
                @max(aggregate.maximum, value);
            aggregate.sum += value;
            aggregate.count += 1;
        }

        try std.testing.expectEqual(
            expected_count,
            try reader.aggregateWindowsPrepared(handle, start, end, resolution, actual),
        );
        for (expected, actual) |wanted, found| {
            try std.testing.expectEqual(wanted.count, found.count);
            try std.testing.expectEqual(wanted.minimum, found.minimum);
            try std.testing.expectEqual(wanted.maximum, found.maximum);
            try std.testing.expectApproxEqAbs(wanted.sum, found.sum, 0.000_001);
            try std.testing.expectEqual(wanted.first, found.first);
            try std.testing.expectEqual(wanted.last, found.last);
        }

        var prefix: [2]chronotail.Aggregate = undefined;
        try std.testing.expectEqual(
            expected_count,
            try reader.aggregateWindowsPrepared(handle, start, end, resolution, &prefix),
        );
        try std.testing.expectEqual(expected[0].count, prefix[0].count);
        try std.testing.expectEqual(expected[1].sum, prefix[1].sum);
        try std.testing.expectError(
            error.InvalidArguments,
            reader.aggregateWindowsPrepared(handle, start, end, 0, &prefix),
        );
        try std.testing.expectError(
            error.DatabaseTooLarge,
            reader.aggregateWindowsPrepared(
                handle,
                std.math.minInt(i64),
                std.math.maxInt(i64),
                1,
                &prefix,
            ),
        );
    }
}

test "cursor advances in bounded caller-owned batches" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "cursor.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .compressed);
    var input_timestamps: [19]i64 = undefined;
    var input_values: [19]f64 = undefined;
    for (&input_timestamps, &input_values, 0..) |*timestamp, *value, point_index| {
        timestamp.* = @intCast(point_index * 2);
        value.* = @floatFromInt(point_index);
    }
    try writer.appendBatch("cpu", &input_timestamps, &input_values);
    try writer.close();

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var cursor = try reader.cursor("cpu", 6, 30);
    var output_timestamps: [5]i64 = undefined;
    var output_values: [5]f64 = undefined;
    var total: usize = 0;
    while (true) {
        const count = try reader.cursorNext(&cursor, &output_timestamps, &output_values);
        if (count == 0) break;
        for (0..count) |point_index| {
            try std.testing.expectEqual(@as(i64, @intCast((total + 3) * 2)), output_timestamps[point_index]);
            try std.testing.expectEqual(@as(f64, @floatFromInt(total + 3)), output_values[point_index]);
            total += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 13), total);
}

test "raw pages can be borrowed without copying until refresh" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "borrow.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    try writer.appendBatch("cpu", &.{ 10, 20, 30 }, &.{ 1.5, 2.5, 3.5 });
    try writer.close();

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    const handle = try reader.prepare("cpu");
    const borrowed = try reader.borrowRawPage(handle, 20);
    try std.testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, borrowed.timestamps);
    try std.testing.expectEqualSlices(f64, &.{ 1.5, 2.5, 3.5 }, borrowed.values);
    try std.testing.expectEqual(@as(i64, 10), borrowed.timestamp_min);
    try std.testing.expectEqual(@as(i64, 30), borrowed.timestamp_max);
}

test "torn newest root falls back to the preceding committed snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "roots.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    try writer.append("cpu", 1, 1);
    try writer.checkpoint(false);
    try writer.append("cpu", 2, 2);
    try writer.checkpoint(false);
    writer.abort();

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const second_root_offset = 4 * 1024 + 2 * 4 * 1024;
    var final_byte: [1]u8 = undefined;
    _ = try file.preadAll(&final_byte, second_root_offset + 4 * 1024 - 1);
    final_byte[0] ^= 1;
    try file.pwriteAll(&final_byte, second_root_offset + 4 * 1024 - 1);

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var timestamps: [2]i64 = undefined;
    var values: [2]f64 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try reader.rangeInto("cpu", 1, 2, &timestamps, &values),
    );
    try std.testing.expectEqual(@as(i64, 1), timestamps[0]);
}

test "newest root must authenticate its retained predecessor" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "root-chain.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    try writer.append("cpu", 1, 1);
    try writer.checkpoint(false);
    try writer.append("cpu", 2, 2);
    try writer.checkpoint(false);
    try writer.append("cpu", 3, 3);
    try writer.checkpoint(false);
    writer.abort();

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const third_root_offset = 4 * 1024 + 3 * 4 * 1024;
    var root: [4 * 1024]u8 = undefined;
    try std.testing.expectEqual(root.len, try file.preadAll(&root, third_root_offset));
    root[56] ^= 1;
    var identity: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(root[0 .. root.len - 16], &identity, .{});
    @memcpy(root[root.len - 16 ..], identity[0..16]);
    try file.pwriteAll(&root, third_root_offset);

    var reader = try chronotail.Reader.open(std.testing.allocator, path);
    defer reader.close();
    var found_timestamps: [3]i64 = undefined;
    var found_values: [3]f64 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        try reader.rangeInto("cpu", 1, 3, &found_timestamps, &found_values),
    );
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, found_timestamps[0..2]);
}

test "all nonzero invalid root slots fail closed instead of opening empty" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "invalid-roots.ctdb" });
    defer std.testing.allocator.free(path);

    var writer = try chronotail.Appender.create(std.testing.allocator, path, .raw);
    try writer.append("cpu", 1, 1);
    try writer.close();

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    for (0..2) |slot| {
        const root_offset = 4 * 1024 + slot * 4 * 1024;
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(1, try file.preadAll(&byte, root_offset));
        byte[0] ^= 1;
        try file.pwriteAll(&byte, root_offset);
    }
    try std.testing.expectError(
        error.InvalidDatabase,
        chronotail.Reader.open(std.testing.allocator, path),
    );
}
