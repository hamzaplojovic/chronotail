const std = @import("std");
const chronotail = @import("chronotail");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) return usage();
    const command = args[1];
    if (std.mem.eql(u8, command, "append")) {
        if (args.len != 6 and args.len != 7) return usage();
        try append(allocator, args);
    } else if (std.mem.eql(u8, command, "range")) {
        if (args.len != 6) return usage();
        try range(allocator, args);
    } else if (std.mem.eql(u8, command, "verify")) {
        if (args.len != 3) return usage();
        const report = chronotail.verifyPath(
            allocator,
            args[2],
        ) catch |err| return verificationFailed(err);
        try printVerification(report);
    } else if (std.mem.eql(u8, command, "inspect")) {
        if (args.len != 3) return usage();
        const report = chronotail.verifyPath(
            allocator,
            args[2],
        ) catch |err| return verificationFailed(err);
        try printInspection(report);
    } else if (std.mem.eql(u8, command, "migrate-v6")) {
        if (args.len != 4 and args.len != 5) return usage();
        const codec: chronotail.Codec = if (args.len == 4)
            .compressed
        else if (std.mem.eql(u8, args[4], "raw"))
            .raw
        else if (std.mem.eql(u8, args[4], "compressed"))
            .compressed
        else
            return error.InvalidCodec;
        try chronotail.migrateV6(allocator, args[2], args[3], codec, .disk);
    } else {
        return usage();
    }
}

fn append(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    const codec: chronotail.Codec = if (args.len != 7)
        .compressed
    else if (std.mem.eql(u8, args[6], "raw"))
        .raw
    else if (std.mem.eql(u8, args[6], "compressed"))
        .compressed
    else
        return error.InvalidCodec;
    var writer = try chronotail.Appender.open(allocator, args[2], codec);
    var closed = false;
    defer if (!closed) writer.abort();
    try writer.append(
        args[3],
        try std.fmt.parseInt(i64, args[4], 10),
        try std.fmt.parseFloat(f64, args[5]),
    );
    try writer.close();
    closed = true;
}

fn range(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var reader = try chronotail.Reader.open(allocator, args[2]);
    defer reader.close();
    _ = try reader.range(
        args[3],
        try std.fmt.parseInt(i64, args[4], 10),
        try std.fmt.parseInt(i64, args[5], 10),
        std.fs.File.stdout(),
    );
}

fn printVerification(report: chronotail.VerificationReport) !void {
    var buffer: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buffer,
        "OK: committed state valid\n" ++
            "checkpoint: {d}\nrecords: {d}\n" ++
            "uncommitted trailing bytes: {d}\n",
        .{ report.checkpoint, report.record_count, report.trailing_bytes },
    );
    try std.fs.File.stdout().writeAll(text);
}

fn printInspection(report: chronotail.VerificationReport) !void {
    var buffer: [1024]u8 = undefined;
    const compressed_percent = if (report.block_count == 0)
        0
    else
        @divFloor(report.compressed_blocks * 100, report.block_count);
    const text = try std.fmt.bufPrint(
        &buffer,
        "Chronotail v{d}\nseries: {d}\nrecords: {d}\nblocks: {d}\ncheckpoints: {d}\n" ++
            "compressed blocks: {d}%\nlogical size: {d} bytes\nphysical size: {d} bytes\n" ++
            "oldest timestamp: {d}\nnewest timestamp: {d}\nuncommitted trailing bytes: {d}\n",
        .{
            chronotail.file_header[4],
            report.series_count,
            report.record_count,
            report.block_count,
            report.checkpoint,
            compressed_percent,
            report.logical_size,
            report.physical_size,
            report.oldest_timestamp orelse 0,
            report.newest_timestamp orelse 0,
            report.trailing_bytes,
        },
    );
    try std.fs.File.stdout().writeAll(text);
}

fn verificationFailed(err: anyerror) noreturn {
    std.debug.print("FAILED: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: chronotail append  <file.ctdb> <series> <timestamp> <value> [raw|compressed]\n" ++
            "       chronotail range   <file.ctdb> <series> <start> <end>\n" ++
            "       chronotail verify  <file.ctdb>\n" ++
            "       chronotail inspect <file.ctdb>\n" ++
            "       chronotail migrate-v6 <source.ctdb> <target.ctdb> [raw|compressed]\n",
        .{},
    );
    return error.InvalidArguments;
}
