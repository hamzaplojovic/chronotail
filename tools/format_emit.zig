const std = @import("std");
const chronotail = @import("chronotail");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    if (args.len != 2) return error.InvalidArguments;
    var writer = try chronotail.Appender.create(std.heap.page_allocator, args[1], .compressed);
    for (0..20_000) |i| {
        const input: f64 = @floatFromInt(i);
        const value = 20.0 + input * 0.000001 + @sin(input * 0.0001);
        try writer.append("series-0", @intCast(i), value);
        if ((i + 1) % 5_000 == 0) try writer.checkpoint(false);
    }
    try writer.close();
}
