const std = @import("std");
const chronotail = @import("chronotail");

const V6Codec = enum(u8) { raw = 0, compressed = 1 };
const timestamps = [_]i64{ 100, 110, 120 };
const values = [_]f64{ 42.5, 42.5, 42.5 };

test "format v6 raw and compressed fixtures migrate exactly to v7" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);

    inline for (.{ V6Codec.raw, V6Codec.compressed }) |codec| {
        const source_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "source-{s}.ctdb",
            .{@tagName(codec)},
        );
        defer std.testing.allocator.free(source_name);
        const target_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "target-{s}.ctdb",
            .{@tagName(codec)},
        );
        defer std.testing.allocator.free(target_name);
        const source_path = try std.fs.path.join(
            std.testing.allocator,
            &.{ directory, source_name },
        );
        defer std.testing.allocator.free(source_path);
        const target_path = try std.fs.path.join(
            std.testing.allocator,
            &.{ directory, target_name },
        );
        defer std.testing.allocator.free(target_path);

        const source = try std.fs.cwd().createFile(source_path, .{});
        try writeV6Fixture(source, codec);
        source.close();
        try std.testing.expectError(
            error.FormatV6RequiresMigration,
            chronotail.Reader.open(std.testing.allocator, source_path),
        );
        try chronotail.migrateV6(
            std.testing.allocator,
            source_path,
            target_path,
            .compressed,
            .memory,
        );

        var reader = try chronotail.Reader.open(std.testing.allocator, target_path);
        defer reader.close();
        var found_timestamps: [timestamps.len]i64 = undefined;
        var found_values: [values.len]f64 = undefined;
        const count = try reader.rangeInto(
            "cpu",
            std.math.minInt(i64),
            std.math.maxInt(i64),
            &found_timestamps,
            &found_values,
        );
        try std.testing.expectEqual(timestamps.len, count);
        try std.testing.expectEqualSlices(i64, &timestamps, &found_timestamps);
        try std.testing.expectEqualSlices(f64, &values, &found_values);
    }
}

test "format v6 migration rejects a corrupted payload and removes the target" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const source_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory, "corrupt-v6.ctdb" },
    );
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory, "must-not-exist.ctdb" },
    );
    defer std.testing.allocator.free(target_path);

    const source = try std.fs.cwd().createFile(source_path, .{ .read = true });
    try writeV6Fixture(source, .raw);
    try source.pwriteAll(&.{0xff}, 5 + 48);
    source.close();
    try std.testing.expectError(
        error.V6ChecksumMismatch,
        chronotail.migrateV6(
            std.testing.allocator,
            source_path,
            target_path,
            .compressed,
            .memory,
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.fs.cwd().openFile(target_path, .{}),
    );
}

fn writeV6Fixture(file: std.fs.File, codec: V6Codec) !void {
    try file.writeAll("CTDB\x06");
    var payload: [128]u8 = undefined;
    const payload_size = switch (codec) {
        .raw => encodeRawPayload(&payload),
        .compressed => encodeCompressedPayload(&payload),
    };
    var block_header: [48]u8 = [_]u8{0} ** 48;
    @memcpy(block_header[0..4], "CTBK");
    block_header[4] = @intFromEnum(codec);
    std.mem.writeInt(u32, block_header[8..12], 0, .little);
    std.mem.writeInt(u32, block_header[12..16], timestamps.len, .little);
    std.mem.writeInt(i64, block_header[16..24], timestamps[0], .little);
    std.mem.writeInt(i64, block_header[24..32], timestamps[timestamps.len - 1], .little);
    std.mem.writeInt(u32, block_header[32..36], @intCast(payload_size), .little);
    std.mem.writeInt(u32, block_header[36..40], timestamps.len * 16, .little);
    std.mem.writeInt(u64, block_header[40..48], checksum(payload[0..payload_size]), .little);
    try file.writeAll(&block_header);
    try file.writeAll(payload[0..payload_size]);

    const block_offset: u64 = 5;
    const stored_size: u32 = @intCast(block_header.len + payload_size);
    const footer_offset = block_offset + stored_size;
    var footer: [87]u8 = [_]u8{0} ** 87;
    @memcpy(footer[0..8], "CTIDX006");
    footer[8] = 0;
    std.mem.writeInt(u32, footer[36..40], 1, .little);
    std.mem.writeInt(u32, footer[40..44], 0, .little);
    footer[44] = 1;
    std.mem.writeInt(u16, footer[45..47], 3, .little);
    std.mem.writeInt(u32, footer[47..51], 1, .little);
    @memcpy(footer[51..54], "cpu");
    std.mem.writeInt(u64, footer[54..62], block_offset, .little);
    std.mem.writeInt(i64, footer[62..70], timestamps[0], .little);
    std.mem.writeInt(i64, footer[70..78], timestamps[timestamps.len - 1], .little);
    std.mem.writeInt(u32, footer[78..82], timestamps.len, .little);
    std.mem.writeInt(u32, footer[82..86], stored_size, .little);
    footer[86] = @intFromEnum(codec);
    try file.writeAll(&footer);

    var trailer: [32]u8 = undefined;
    @memcpy(trailer[0..8], "CTTRL006");
    std.mem.writeInt(u64, trailer[8..16], footer_offset, .little);
    std.mem.writeInt(u64, trailer[16..24], footer.len, .little);
    std.mem.writeInt(u64, trailer[24..32], checksum(&footer), .little);
    try file.writeAll(&trailer);
}

fn encodeRawPayload(output: []u8) usize {
    for (timestamps, values, 0..) |timestamp, value, point_index| {
        const offset = point_index * 16;
        std.mem.writeInt(i64, output[offset..][0..8], timestamp, .little);
        std.mem.writeInt(u64, output[offset + 8 ..][0..8], @bitCast(value), .little);
    }
    return timestamps.len * 16;
}

fn encodeCompressedPayload(output: []u8) usize {
    @memset(output, 0);
    std.mem.writeInt(u32, output[0..4], 1, .little);
    std.mem.writeInt(i64, output[4..12], timestamps[0], .little);
    std.mem.writeInt(u32, output[12..16], 16, .little);
    std.mem.writeInt(u32, output[16..20], 10, .little);
    std.mem.writeInt(i64, output[20..28], timestamps[0], .little);
    output[28] = 10;
    output[29] = 0;
    std.mem.writeInt(u64, output[30..38], @bitCast(values[0]), .little);
    output[38] = 0;
    return 39;
}

fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}
