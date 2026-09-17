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
