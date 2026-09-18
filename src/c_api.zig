const std = @import("std");
const chronotail = @import("chronotail");

const allocator = std.heap.c_allocator;

const WriterState = struct {
    appender: chronotail.Appender,
    poisoned: bool = false,
};

const HandleState = union(enum) {
    writer: WriterState,
    reader: chronotail.Reader,
};

const Handle = struct {
    token: u64,
    state: HandleState,
};

var next_handle_token = std.atomic.Value(u64).init(1);

fn handleToken() u64 {
    return next_handle_token.fetchAdd(1, .monotonic);
}

const ok = 0;
const buffer_too_small = 1;
const generic_error = -1;
const invalid_argument = -2;
const wrong_handle = -3;
const writer_busy = -4;
const timestamp_order = -5;
const io_error = -6;
const poisoned_writer = -7;
const stale_series = -8;
const page_not_raw = -9;
const timestamp_not_found = -10;
const borrowed_view_unavailable = -11;

const CSeriesHandle = extern struct {
    index: u32,
    reserved: u32 = 0,
    generation: u64,
};

const CAggregate = extern struct {
    count: u64,
    minimum: f64,
    maximum: f64,
    sum: f64,
    first: f64,
    last: f64,
};

const CPoint = extern struct {
    timestamp: i64,
    value: f64,
};

const CRangeCursor = extern struct {
    series: CSeriesHandle,
    next_timestamp: i64,
    end: i64,
    complete: u8,
    reserved: [7]u8 = [_]u8{0} ** 7,
};

const CursorState = struct {
    owner: *Handle,
    owner_token: u64,
    native: chronotail.RangeCursor,
};

const CRawPage = extern struct {
    timestamps: [*]const i64,
    values: [*]const f64,
    count: usize,
    timestamp_min: i64,
    timestamp_max: i64,
};

comptime {
    std.debug.assert(@sizeOf(CSeriesHandle) == 16);
    std.debug.assert(@alignOf(CSeriesHandle) == 8);
    std.debug.assert(@offsetOf(CSeriesHandle, "index") == 0);
    std.debug.assert(@offsetOf(CSeriesHandle, "reserved") == 4);
    std.debug.assert(@offsetOf(CSeriesHandle, "generation") == 8);

    std.debug.assert(@sizeOf(CAggregate) == 48);
    std.debug.assert(@alignOf(CAggregate) == 8);
    std.debug.assert(@offsetOf(CAggregate, "count") == 0);
    std.debug.assert(@offsetOf(CAggregate, "minimum") == 8);
    std.debug.assert(@offsetOf(CAggregate, "maximum") == 16);
    std.debug.assert(@offsetOf(CAggregate, "sum") == 24);
    std.debug.assert(@offsetOf(CAggregate, "first") == 32);
    std.debug.assert(@offsetOf(CAggregate, "last") == 40);

    std.debug.assert(@sizeOf(CPoint) == 16);
    std.debug.assert(@alignOf(CPoint) == 8);
    std.debug.assert(@offsetOf(CPoint, "timestamp") == 0);
    std.debug.assert(@offsetOf(CPoint, "value") == 8);
    std.debug.assert(@sizeOf(CPoint) == @sizeOf(chronotail.Point));
    std.debug.assert(@alignOf(CPoint) == @alignOf(chronotail.Point));

    std.debug.assert(@sizeOf(CRangeCursor) == 40);
    std.debug.assert(@alignOf(CRangeCursor) == 8);
    std.debug.assert(@offsetOf(CRangeCursor, "series") == 0);
    std.debug.assert(@offsetOf(CRangeCursor, "next_timestamp") == 16);
    std.debug.assert(@offsetOf(CRangeCursor, "end") == 24);
    std.debug.assert(@offsetOf(CRangeCursor, "complete") == 32);
    std.debug.assert(@offsetOf(CRangeCursor, "reserved") == 33);

    std.debug.assert(@sizeOf(CRawPage) == 40);
    std.debug.assert(@alignOf(CRawPage) == 8);
    std.debug.assert(@offsetOf(CRawPage, "timestamps") == 0);
    std.debug.assert(@offsetOf(CRawPage, "values") == 8);
    std.debug.assert(@offsetOf(CRawPage, "count") == 16);
    std.debug.assert(@offsetOf(CRawPage, "timestamp_min") == 24);
    std.debug.assert(@offsetOf(CRawPage, "timestamp_max") == 32);
}

export fn ct_abi_version() callconv(.c) u32 {
    return 2;
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
        stale_series => "prepared series handle is stale after refresh",
        page_not_raw => "page does not use raw timestamp and value columns",
        timestamp_not_found => "timestamp is not contained in a page",
        borrowed_view_unavailable => "borrowed views require a mapped production reader",
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
    handle.* = .{
        .token = handleToken(),
        .state = .{ .writer = .{ .appender = appender } },
    };
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
    var writer = switch (handle.state) {
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

export fn ct_prepare_append(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    maximum_points_before_checkpoint: usize,
) callconv(.c) c_int {
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var writer = switch (handle.state) {
        .writer => |*state| state,
        else => return wrong_handle,
    };
    if (writer.poisoned) return poisoned_writer;
    const name = bytes(series, series_len) orelse return invalid_argument;
    writer.appender.prepareSeries(
        name,
        maximum_points_before_checkpoint,
    ) catch |err| return statusFromError(err);
    return ok;
}

export fn ct_checkpoint(handle_pointer: ?*anyopaque, sync: u8) callconv(.c) c_int {
    return checkpointWithDurability(
        handle_pointer,
        if (sync == 0) .memory else .disk,
    );
}

export fn ct_checkpoint_with_durability(
    handle_pointer: ?*anyopaque,
    durability_value: u8,
) callconv(.c) c_int {
    const durability = std.meta.intToEnum(
        chronotail.Durability,
        durability_value,
    ) catch return invalid_argument;
    return checkpointWithDurability(handle_pointer, durability);
}

fn checkpointWithDurability(
    handle_pointer: ?*anyopaque,
    durability: chronotail.Durability,
) c_int {
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var writer = switch (handle.state) {
        .writer => |*state| state,
        else => return wrong_handle,
    };
    if (writer.poisoned) return poisoned_writer;
    writer.appender.checkpointWithDurability(durability) catch |err| {
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
    handle.* = .{ .token = handleToken(), .state = .{ .reader = reader } };
    output.* = handle;
    return ok;
}

export fn ct_refresh(handle_pointer: ?*anyopaque, changed: ?*u8) callconv(.c) c_int {
    const output = changed orelse return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
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
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const series_bytes = bytes(series, series_len) orelse return invalid_argument;
    const buffers = rangeBuffers(timestamps, values, capacity) orelse return invalid_argument;
    const found = reader.rangeInto(
        series_bytes,
        start,
        end,
        buffers.timestamps,
        buffers.values,
    ) catch |err| return statusFromError(err);
    output_count.* = found;
    return if (found > capacity) buffer_too_small else ok;
}

export fn ct_prepare_series(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    out: ?*CSeriesHandle,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const name = bytes(series, series_len) orelse return invalid_argument;
    const prepared = reader.prepare(name) catch |err| return statusFromError(err);
    output.* = .{ .index = prepared.index, .generation = prepared.generation };
    return ok;
}

export fn ct_range_prepared(
    handle_pointer: ?*anyopaque,
    prepared: CSeriesHandle,
    start: i64,
    end: i64,
    timestamps: ?[*]i64,
    values: ?[*]f64,
    capacity: usize,
    count: ?*usize,
) callconv(.c) c_int {
    const output_count = count orelse return invalid_argument;
    output_count.* = 0;
    if (prepared.reserved != 0) return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const buffers = rangeBuffers(timestamps, values, capacity) orelse return invalid_argument;
    const found = reader.rangePreparedInto(
        .{ .index = prepared.index, .generation = prepared.generation },
        start,
        end,
        buffers.timestamps,
        buffers.values,
    ) catch |err| return statusFromError(err);
    output_count.* = found;
    return if (found > capacity) buffer_too_small else ok;
}

export fn ct_range_points(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    start: i64,
    end: i64,
    points: ?[*]CPoint,
    capacity: usize,
    count: ?*usize,
) callconv(.c) c_int {
    const output_count = count orelse return invalid_argument;
    output_count.* = 0;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const series_bytes = bytes(series, series_len) orelse return invalid_argument;
    const output = pointBuffer(points, capacity) orelse return invalid_argument;
    const found = reader.rangePoints(
        series_bytes,
        start,
        end,
        output,
    ) catch |err| return statusFromError(err);
    output_count.* = found;
    return if (found > capacity) buffer_too_small else ok;
}

export fn ct_range_points_prepared(
    handle_pointer: ?*anyopaque,
    prepared: CSeriesHandle,
    start: i64,
    end: i64,
    points: ?[*]CPoint,
    capacity: usize,
    count: ?*usize,
) callconv(.c) c_int {
    const output_count = count orelse return invalid_argument;
    output_count.* = 0;
    if (prepared.reserved != 0) return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const output = pointBuffer(points, capacity) orelse return invalid_argument;
    const found = reader.rangePreparedPoints(
        .{ .index = prepared.index, .generation = prepared.generation },
        start,
        end,
        output,
    ) catch |err| return statusFromError(err);
    output_count.* = found;
    return if (found > capacity) buffer_too_small else ok;
}

export fn ct_aggregate(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    start: i64,
    end: i64,
    out: ?*CAggregate,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const name = bytes(series, series_len) orelse return invalid_argument;
    const result = reader.aggregate(name, start, end) catch |err| return statusFromError(err);
    output.* = .{
        .count = result.count,
        .minimum = result.minimum,
        .maximum = result.maximum,
        .sum = result.sum,
        .first = result.first,
        .last = result.last,
    };
    return ok;
}

export fn ct_aggregate_prepared(
    handle_pointer: ?*anyopaque,
    prepared: CSeriesHandle,
    start: i64,
    end: i64,
    out: ?*CAggregate,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    if (prepared.reserved != 0) return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const result = reader.aggregatePrepared(
        .{ .index = prepared.index, .generation = prepared.generation },
        start,
        end,
    ) catch |err| return statusFromError(err);
    output.* = .{
        .count = result.count,
        .minimum = result.minimum,
        .maximum = result.maximum,
        .sum = result.sum,
        .first = result.first,
        .last = result.last,
    };
    return ok;
}

export fn ct_cursor_init(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    start: i64,
    end: i64,
    out: ?*CRangeCursor,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const name = bytes(series, series_len) orelse return invalid_argument;
    const cursor = reader.cursor(name, start, end) catch |err| return statusFromError(err);
    output.* = .{
        .series = .{ .index = cursor.series.index, .generation = cursor.series.generation },
        .next_timestamp = cursor.next_timestamp,
        .end = cursor.end,
        .complete = @intFromBool(cursor.complete),
    };
    return ok;
}

export fn ct_cursor_next(
    handle_pointer: ?*anyopaque,
    cursor: ?*CRangeCursor,
    timestamps: ?[*]i64,
    values: ?[*]f64,
    capacity: usize,
    count: ?*usize,
) callconv(.c) c_int {
    const cursor_state = cursor orelse return invalid_argument;
    const output_count = count orelse return invalid_argument;
    output_count.* = 0;
    if (cursor_state.series.reserved != 0 or !allZero(&cursor_state.reserved) or
        cursor_state.complete > 1 or capacity == 0) return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const buffers = rangeBuffers(timestamps, values, capacity) orelse return invalid_argument;
    var native = chronotail.RangeCursor{
        .series = .{
            .index = cursor_state.series.index,
            .generation = cursor_state.series.generation,
        },
        .next_timestamp = cursor_state.next_timestamp,
        .end = cursor_state.end,
        .complete = cursor_state.complete != 0,
    };
    const found = reader.cursorNext(
        &native,
        buffers.timestamps,
        buffers.values,
    ) catch |err| return statusFromError(err);
    cursor_state.next_timestamp = native.next_timestamp;
    cursor_state.complete = @intFromBool(native.complete);
    output_count.* = found;
    return ok;
}

export fn ct_cursor_state_create(
    handle_pointer: ?*anyopaque,
    series: ?[*]const u8,
    series_len: usize,
    start: i64,
    end: i64,
    out: ?*?*anyopaque,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    output.* = null;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const name = bytes(series, series_len) orelse return invalid_argument;
    const native = reader.cursor(name, start, end) catch |err| return statusFromError(err);
    const state = allocator.create(CursorState) catch return generic_error;
    state.* = .{
        .owner = handle,
        .owner_token = handle.token,
        .native = native,
    };
    output.* = state;
    return ok;
}

export fn ct_cursor_state_next(
    handle_pointer: ?*anyopaque,
    cursor_pointer: ?*anyopaque,
    timestamps: ?[*]i64,
    values: ?[*]f64,
    capacity: usize,
    count: ?*usize,
    complete: ?*u8,
) callconv(.c) c_int {
    const state: *CursorState = @ptrCast(@alignCast(cursor_pointer orelse
        return invalid_argument));
    const output_count = count orelse return invalid_argument;
    const output_complete = complete orelse return invalid_argument;
    output_count.* = 0;
    output_complete.* = 0;
    if (capacity == 0) return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    if (state.owner != handle or state.owner_token != handle.token) return wrong_handle;
    var reader = switch (handle.state) {
        .reader => |*reader_state| reader_state,
        else => return wrong_handle,
    };
    const buffers = rangeBuffers(timestamps, values, capacity) orelse return invalid_argument;
    const found = reader.cursorNext(
        &state.native,
        buffers.timestamps,
        buffers.values,
    ) catch |err| return statusFromError(err);
    output_count.* = found;
    output_complete.* = @intFromBool(state.native.complete);
    return ok;
}

export fn ct_cursor_state_destroy(cursor_pointer: ?*anyopaque) callconv(.c) void {
    const state: *CursorState = @ptrCast(@alignCast(cursor_pointer orelse return));
    allocator.destroy(state);
}

export fn ct_borrow_raw_page(
    handle_pointer: ?*anyopaque,
    prepared: CSeriesHandle,
    timestamp: i64,
    out: ?*CRawPage,
) callconv(.c) c_int {
    const output = out orelse return invalid_argument;
    if (prepared.reserved != 0) return invalid_argument;
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var reader = switch (handle.state) {
        .reader => |*state| state,
        else => return wrong_handle,
    };
    const view = reader.borrowRawPage(
        .{ .index = prepared.index, .generation = prepared.generation },
        timestamp,
    ) catch |err| return statusFromError(err);
    output.* = .{
        .timestamps = view.timestamps.ptr,
        .values = view.values.ptr,
        .count = view.timestamps.len,
        .timestamp_min = view.timestamp_min,
        .timestamp_max = view.timestamp_max,
    };
    return ok;
}

export fn ct_close(handle_pointer: ?*anyopaque) callconv(.c) c_int {
    const handle = getHandle(handle_pointer) orelse return invalid_argument;
    var status: c_int = ok;
    switch (handle.state) {
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

fn allZero(bytes_slice: []const u8) bool {
    for (bytes_slice) |byte| if (byte != 0) return false;
    return true;
}

const CRangeBuffers = struct { timestamps: []i64, values: []f64 };

fn rangeBuffers(
    timestamps: ?[*]i64,
    values: ?[*]f64,
    capacity: usize,
) ?CRangeBuffers {
    if (capacity > 0 and (timestamps == null or values == null)) return null;
    var empty_timestamps: [0]i64 = .{};
    var empty_values: [0]f64 = .{};
    return .{
        .timestamps = if (timestamps) |pointer| pointer[0..capacity] else empty_timestamps[0..],
        .values = if (values) |pointer| pointer[0..capacity] else empty_values[0..],
    };
}

fn pointBuffer(points: ?[*]CPoint, capacity: usize) ?[]chronotail.Point {
    if (capacity > 0 and points == null) return null;
    var empty: [0]chronotail.Point = .{};
    return if (points) |pointer|
        @as([*]chronotail.Point, @ptrCast(pointer))[0..capacity]
    else
        empty[0..];
}

fn statusFromError(err: anyerror) c_int {
    return switch (err) {
        error.WouldBlock => writer_busy,
        error.TimestampNotIncreasing => timestamp_order,
        error.InvalidBatch,
        error.InvalidSeriesName,
        error.InvalidCodec,
        error.InvalidArguments,
        error.SeriesNotFound,
        => invalid_argument,
        error.StaleSeriesHandle => stale_series,
        error.PageNotRaw => page_not_raw,
        error.TimestampNotFound => timestamp_not_found,
        error.BorrowedViewUnavailable => borrowed_view_unavailable,
        error.WriterPoisoned => poisoned_writer,
        error.FileNotFound,
        error.AccessDenied,
        error.InputOutput,
        error.InvalidDatabase,
        error.FormatV6RequiresMigration,
        error.ChecksumMismatch,
        => io_error,
        else => generic_error,
    };
}
