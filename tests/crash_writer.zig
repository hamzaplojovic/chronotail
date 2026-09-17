const std = @import("std");
const chronotail = @import("chronotail");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    if (args.len != 2) return error.InvalidArguments;

    var appender = try chronotail.Appender.create(std.heap.page_allocator, args[1], .raw);
    try appender.append("telemetry", 0, 42.5);
    try appender.checkpoint(true);

    var state: u64 = 0x9e3779b97f4a7c15;
    var next_checkpoint: usize = 1;
    for (1..10_000_000) |timestamp| {
        try appender.append("telemetry", @intCast(timestamp), 42.5);
        if (timestamp == next_checkpoint) {
            try appender.checkpoint(true);
            state = state *% 6364136223846793005 +% 1442695040888963407;
            next_checkpoint += @intCast(state % 1000 + 1);
        }
    }
    try appender.close();
}
