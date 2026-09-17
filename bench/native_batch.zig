const std = @import("std");
const chronotail = @import("chronotail");

const count = 1_000_000;
const batch_sizes = [_]usize{ 1, 100, 1_000, 10_000 };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const timestamps = try allocator.alloc(i64, count);
    defer allocator.free(timestamps);
    const values = try allocator.alloc(f64, count);
    defer allocator.free(values);
    for (timestamps, values, 0..) |*timestamp, *value, i| {
        timestamp.* = @intCast(i);
        value.* = 42.5;
    }

    for (batch_sizes) |batch_size| {
        const path = try std.fmt.allocPrint(allocator, "native-batch-{d}.ctdb", .{batch_size});
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
        var writer = try chronotail.Appender.create(allocator, path, .raw);
        var timer = try std.time.Timer.start();
        var offset: usize = 0;
        while (offset < count) {
            const end = @min(offset + batch_size, count);
            try writer.appendBatch("telemetry", timestamps[offset..end], values[offset..end]);
            offset = end;
        }
        try writer.checkpoint(false);
        try writer.close();
        const elapsed = timer.read();
        const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
        var output: [128]u8 = undefined;
        try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(
            &output,
            "batch={d} writes/sec={d:.0}\n",
            .{ batch_size, count / seconds },
        ));
    }
}
