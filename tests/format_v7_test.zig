const std = @import("std");
const chronotail = @import("chronotail");

test "format v7 constants are explicit" {
    try std.testing.expectEqualSlices(u8, "CTDB\x07", &chronotail.file_header);
    try std.testing.expectEqual(@as(usize, 64 * 1024), chronotail.block_size);
    try std.testing.expectEqual(@as(usize, 128), chronotail.block_header_size);
    try std.testing.expectEqual(@as(usize, 16), chronotail.record_size);
}

test "record encoding is little endian and stable" {
    const record = chronotail.encodeRecord(0x0102030405060708, 42.5);
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 6, 5, 4, 3, 2, 1 }, record[0..8]);
    const expected_value: u64 = @bitCast(@as(f64, 42.5));
    try std.testing.expectEqual(
        expected_value,
        std.mem.readInt(u64, record[8..16], .little),
    );
}

test "format v7 raw and compressed database bytes are stable" {
    var timestamps: [256]i64 = undefined;
    var values: [256]f64 = undefined;
    var current_timestamp: i64 = 0;
    for (&timestamps, &values, 0..) |*stored_timestamp, *value, point_index| {
        current_timestamp += @intCast(3 + point_index % 5);
        stored_timestamp.* = current_timestamp;
        value.* = 20.0 + @as(f64, @floatFromInt(point_index % 100)) * 0.001;
    }

    inline for (.{ chronotail.Codec.raw, chronotail.Codec.compressed }) |codec| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const file = try temporary.dir.createFile("golden.ctdb", .{ .read = true });
        var writer = try chronotail.Appender.createOn(std.testing.allocator, file, codec);
        try writer.appendBatch("telemetry", &timestamps, &values);
        try writer.close();

        const stored = try temporary.dir.openFile("golden.ctdb", .{});
        defer stored.close();
        const bytes = try stored.readToEndAlloc(std.testing.allocator, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const expected = switch (codec) {
            .raw => [_]u8{
                0x44, 0x65, 0xe6, 0xd5, 0x05, 0x00, 0xc1, 0xf8,
                0x8c, 0x0e, 0xe0, 0x0b, 0x68, 0x0f, 0x81, 0x95,
                0xfa, 0x3b, 0xf1, 0x6c, 0xbc, 0xe2, 0x95, 0x33,
                0xb1, 0x5b, 0x44, 0x61, 0xc2, 0xd5, 0xac, 0x0d,
            },
            .compressed => [_]u8{
                0x7a, 0xc8, 0x6a, 0x32, 0x1f, 0x48, 0x58, 0x6a,
                0x85, 0x8b, 0xa0, 0x8c, 0xaf, 0x29, 0x69, 0x87,
                0x15, 0xc8, 0x0b, 0x5a, 0x61, 0x6c, 0x26, 0x2a,
                0xec, 0x17, 0x54, 0xcb, 0xb3, 0x4a, 0x87, 0x3a,
            },
        };
        try std.testing.expectEqualSlices(u8, &expected, &digest);
    }
}
