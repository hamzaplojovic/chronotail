const std = @import("std");
const chronotail = @import("chronotail");

const allocator = std.heap.c_allocator;

const WriterState = struct {
    appender: chronotail.Appender,
    poisoned: bool = false,
};

const Handle = union(enum) {
    writer: WriterState,
    reader: chronotail.Reader,
};

const ok = 0;
const buffer_too_small = 1;
const generic_error = -1;
const invalid_argument = -2;
const wrong_handle = -3;
const writer_busy = -4;
const timestamp_order = -5;
const io_error = -6;
const poisoned_writer = -7;

export fn ct_abi_version() callconv(.c) u32 {
    return 1;
}

export fn ct_error_string(code: c_int) callconv(.c) [*:0]const u8 {
    return switch (code) {
        ok => "ok",
        buffer_too_small => "range buffer too small",
        invalid_argument => "invalid argument",
        wrong_handle => "wrong handle type",
        writer_busy => "another writer already has the database open",
        timestamp_order => "timestamps must be strictly increasing within a series",
        io_error => "database I/O error",
        poisoned_writer => "writer is unusable after a failed batch",
        else => "chronotail error",
    };
}

export fn ct_open_writer(
    path: ?[*]const u8,
    path_len: usize,
    codec_value: u8,
    out: ?*?*anyopaque,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    output.* = null;
    const path_bytes = bytes(path, path_len) orelse return invalid_argument;
    const codec = std.meta.intToEnum(chronotail.Codec, codec_value) catch return invalid_argument;
    const appender = chronotail.Appender.open(
        allocator,
        path_bytes,
        codec,
    ) catch |err| return statusFromError(err);
    const handle = allocator.create(Handle) catch {
        var owned = appender;
        owned.abort();
        return generic_error;
    };
    handle.* = .{ .writer = .{ .appender = appender } };
    output.* = handle;
    return ok;
}

export fn ct_append(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    timestamps: ?[*]const i64,
    values: ?[*]const f64,
    count: usize,
) callconv(.c) c_int {
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    const series_bytes = bytes(series, series_len) orelse return invalid_argument;
    var writer = switch (handle.*) {
        .writer => |*state| state,
        else => return wrong_handle,
    };
    if (writer.poisoned) return poisoned_writer;
    if (count > 0 and (timestamps == null or values == null)) return invalid_argument;
    const timestamp_slice = if (timestamps) |pointer| pointer[0..count] else &[_]i64{};
    const value_slice = if (values) |pointer| pointer[0..count] else &[_]f64{};
    writer.appender.appendBatch(series_bytes, timestamp_slice, value_slice) catch |err| {
        const status = statusFromError(err);
        if (status != timestamp_order and status != invalid_argument) writer.poisoned = true;
        return status;
    };
    return ok;
}

export fn ct_checkpoint(handle_pointer: ?*anyopaque, sync: u8) callconv(.c) c_int {
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var writer = switch (handle.*) {
        .writer => |*state| state,
        else => return wrong_handle,
    };
    if (writer.poisoned) return poisoned_writer;
    writer.appender.checkpoint(sync != 0) catch |err| {
        writer.poisoned = true;
        return statusFromError(err);
    };
    return ok;
}

export fn ct_open_reader(
    path: ?[*]const u8,
    path_len: usize,
    out: ?*?*anyopaque,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    output.* = null;
    const path_bytes = bytes(path, path_len) orelse return invalid_argument;
    const reader = chronotail.Reader.open(
        allocator,
        path_bytes,
    ) catch |err| return statusFromError(err);
    const handle = allocator.create(Handle) catch {
        var owned = reader;
        owned.close();
        return generic_error;
    };
    handle.* = .{ .reader = reader };
    output.* = handle;
    return ok;
}

export fn ct_refresh(handle_pointer: ?*anyopaque, changed: ?*u8) callconv(.c) c_int {
    const output = changed orelse return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.*) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    output.* = if (reader.refresh() catch |err| return statusFromError(err)) 1 else 0;
    return ok;
}

export fn ct_range(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    start: i64,
    end: i64,
    timestamps: ?[*]i64,
    values: ?[*]f64,
    capacity: usize,
    count: ?*usize,
) callconv(.c) c_int {
    const output_count = count orelse return invalid_argument;
    output_count.* = 0;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.*) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const series_bytes = bytes(series, series_len) orelse return invalid_argument;
    if (capacity > 0 and (timestamps == null or values == null)) return invalid_argument;
    var empty_timestamps: [0]i64 = .{};
    var empty_values: [0]f64 = .{};
    const timestamp_slice = if (timestamps) |pointer|
        pointer[0..capacity]
    else
        empty_timestamps[0..];
    const value_slice = if (values) |pointer| pointer[0..capacity] else empty_values[0..];
    const found = reader.rangeInto(
        series_bytes,
        start,
        end,
        timestamp_slice,
        value_slice,
    ) catch |err| return statusFromError(err);
    output_count.* = found;
    return if (found > capacity) buffer_too_small else ok;
}

export fn ct_close(handle_pointer: ?*anyopaque) callconv(.c) c_int {
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var status: c_int = ok;
    switch (handle.*) {
        .writer => |*writer| {
            if (writer.poisoned) {
                writer.appender.abort();
                status = poisoned_writer;
            } else {
                writer.appender.close() catch |err| {
                    status = statusFromError(err);
                };
            }
        },
        .reader => |*reader| reader.close(),
    }
    allocator.destroy(handle);
    return status;
}

fn bytes(pointer: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return null;
    return if (pointer) |value| value[0..len] else null;
}

fn getHandle(pointer: ?*anyopaque) ?*Handle {
    return if (pointer) |value| @ptrCast(@alignCast(value)) else null;
}

fn statusFromError(err: anyerror) c_int {
    return switch (err) {
        error.WouldBlock => writer_busy,
        error.TimestampNotIncreasing => timestamp_order,
        error.InvalidBatch,
        error.InvalidSeriesName,
        error.InvalidCodec,
        error.InvalidArguments,
        => invalid_argument,
        error.FileNotFound,
        error.AccessDenied,
        error.InputOutput,
        error.InvalidDatabase,
        error.ChecksumMismatch,
        => io_error,
        else => generic_error,
    };
}
