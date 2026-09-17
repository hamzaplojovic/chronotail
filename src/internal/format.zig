const std = @import("std");
const checksum = @import("checksum.zig");

pub const version: u8 = 7;
pub const file_header = [_]u8{ 'C', 'T', 'D', 'B', version };
pub const control_size: usize = 64 * 1024;
pub const root_slot_count: usize = 4;
pub const root_slot_size: usize = 4 * 1024;
pub const root_slot_base: usize = 4 * 1024;
pub const page_size: usize = 64 * 1024;
pub const page_header_size: usize = 128;
pub const index_node_size: usize = 4 * 1024;
pub const pointer_size: usize = 32;
pub const root_identity_offset: usize = root_slot_size - 16;

pub const header_magic = "CTDBHDR7";
pub const root_magic = "CTROOT07";
pub const data_magic = "CTPAGE07";
pub const index_magic = "CTINDEX7";
pub const manifest_magic = "CTMANIF7";

pub const PointerKind = enum(u8) {
    data = 1,
    index = 2,
    manifest = 3,
};

pub const Pointer = struct {
    offset: u64,
    size: u32,
    kind: PointerKind,
    identity: checksum.Identity,

    pub fn encode(self: Pointer, output: *[pointer_size]u8) void {
        @memset(output, 0);
        std.mem.writeInt(u64, output[0..8], self.offset, .little);
        std.mem.writeInt(u32, output[8..12], self.size, .little);
        output[12] = @intFromEnum(self.kind);
        @memcpy(output[16..32], &self.identity);
    }

    pub fn decode(input: *const [pointer_size]u8) !Pointer {
        const kind = std.meta.intToEnum(PointerKind, input[12]) catch
            return error.InvalidPointer;
        if (!allZero(input[13..16])) return error.InvalidPointer;
        return .{
            .offset = std.mem.readInt(u64, input[0..8], .little),
            .size = std.mem.readInt(u32, input[8..12], .little),
            .kind = kind,
            .identity = input[16..32].*,
        };
    }

    pub fn validate(self: Pointer, committed_size: u64) !void {
        if (self.size == 0) return error.InvalidPointer;
        if (self.offset < control_size) return error.InvalidPointer;
        const end = std.math.add(u64, self.offset, self.size) catch
            return error.InvalidPointer;
        if (end > committed_size) return error.InvalidPointer;
    }
};

pub const Root = struct {
    generation: u64,
    committed_size: u64,
    manifest: Pointer,
    previous_identity: checksum.Identity,

    pub fn encode(self: Root, output: *[root_slot_size]u8) void {
        @memset(output, 0);
        @memcpy(output[0..8], root_magic);
        std.mem.writeInt(u64, output[8..16], self.generation, .little);
        std.mem.writeInt(u64, output[16..24], self.committed_size, .little);
        var pointer_bytes: [pointer_size]u8 = undefined;
        self.manifest.encode(&pointer_bytes);
        @memcpy(output[24..56], &pointer_bytes);
        @memcpy(output[56..72], &self.previous_identity);
        const root_identity = checksum.calculate(output[0..root_identity_offset]);
        @memcpy(output[root_identity_offset..root_slot_size], &root_identity);
    }

    pub fn decode(input: *const [root_slot_size]u8) !Root {
        if (!std.mem.eql(u8, input[0..8], root_magic)) return error.InvalidRoot;
        if (!allZero(input[72..root_identity_offset])) return error.InvalidRoot;
        const expected = checksum.calculate(input[0..root_identity_offset]);
        if (!checksum.equal(expected, input[root_identity_offset..root_slot_size].*))
            return error.InvalidRoot;
        const root = Root{
            .generation = std.mem.readInt(u64, input[8..16], .little),
            .committed_size = std.mem.readInt(u64, input[16..24], .little),
            .manifest = try Pointer.decode(input[24..56]),
            .previous_identity = input[56..72].*,
        };
        if (root.generation == 0) return error.InvalidRoot;
        try root.manifest.validate(root.committed_size);
        if (root.manifest.kind != .manifest) return error.InvalidRoot;
        return root;
    }

    pub fn identity(encoded: *const [root_slot_size]u8) checksum.Identity {
        return encoded[root_identity_offset..root_slot_size].*;
    }
};

pub fn rootSlotOffset(index: usize) !u64 {
    if (index >= root_slot_count) return error.InvalidRootSlot;
    return root_slot_base + index * root_slot_size;
}

pub fn encodeFileHeader(output: *[control_size]u8) void {
    @memset(output, 0);
    @memcpy(output[0..file_header.len], &file_header);
    @memcpy(output[8..16], header_magic);
    std.mem.writeInt(u32, output[16..20], control_size, .little);
    std.mem.writeInt(u32, output[20..24], root_slot_count, .little);
    std.mem.writeInt(u32, output[24..28], root_slot_size, .little);
    std.mem.writeInt(u32, output[28..32], page_size, .little);
    const identity = checksum.calculate(output[0..48]);
    @memcpy(output[48..64], &identity);
}

pub fn validateFileHeader(input: *const [control_size]u8) !void {
    if (!std.mem.eql(u8, input[0..file_header.len], &file_header))
        return error.InvalidHeader;
    if (!allZero(input[5..8])) return error.InvalidHeader;
    if (!std.mem.eql(u8, input[8..16], header_magic)) return error.InvalidHeader;
    if (std.mem.readInt(u32, input[16..20], .little) != control_size)
        return error.InvalidHeader;
    if (std.mem.readInt(u32, input[20..24], .little) != root_slot_count)
        return error.InvalidHeader;
    if (std.mem.readInt(u32, input[24..28], .little) != root_slot_size)
        return error.InvalidHeader;
    if (std.mem.readInt(u32, input[28..32], .little) != page_size)
        return error.InvalidHeader;
    if (!allZero(input[32..48])) return error.InvalidHeader;
    const expected = checksum.calculate(input[0..48]);
    if (!checksum.equal(expected, input[48..64].*)) return error.InvalidHeader;
    if (!allZero(input[64..root_slot_base])) return error.InvalidHeader;
    const root_slots_end = root_slot_base + root_slot_count * root_slot_size;
    if (!allZero(input[root_slots_end..control_size])) return error.InvalidHeader;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

comptime {
    std.debug.assert(control_size % root_slot_size == 0);
    std.debug.assert(root_slot_base + root_slot_count * root_slot_size <= control_size);
    std.debug.assert(page_header_size < page_size);
    std.debug.assert(pointer_size == 32);
    std.debug.assert(root_identity_offset > 72);
}

test "pointer encoding is portable and validates committed bounds" {
    const pointer = Pointer{
        .offset = control_size,
        .size = 4096,
        .kind = .manifest,
        .identity = checksum.calculate("manifest"),
    };
    var encoded: [pointer_size]u8 = undefined;
    pointer.encode(&encoded);
    const decoded = try Pointer.decode(&encoded);
    try std.testing.expectEqual(pointer.offset, decoded.offset);
    try std.testing.expectEqual(pointer.size, decoded.size);
    try std.testing.expectEqual(pointer.kind, decoded.kind);
    try std.testing.expect(checksum.equal(pointer.identity, decoded.identity));
    try decoded.validate(control_size + 4096);
    try std.testing.expectError(error.InvalidPointer, decoded.validate(control_size + 4095));
}

test "root slots reject torn or nonzero trailing bytes" {
    const root = Root{
        .generation = 7,
        .committed_size = control_size + 4096,
        .manifest = .{
            .offset = control_size,
            .size = 4096,
            .kind = .manifest,
            .identity = checksum.calculate("manifest"),
        },
        .previous_identity = checksum.zero,
    };
    var encoded: [root_slot_size]u8 = undefined;
    root.encode(&encoded);
    const decoded = try Root.decode(&encoded);
    try std.testing.expectEqual(root.generation, decoded.generation);
    encoded[40] ^= 1;
    try std.testing.expectError(error.InvalidRoot, Root.decode(&encoded));
    root.encode(&encoded);
    encoded[100] = 1;
    try std.testing.expectError(error.InvalidRoot, Root.decode(&encoded));
    root.encode(&encoded);
    std.mem.writeInt(u64, encoded[16..24], control_size, .little);
    const forged_identity = checksum.calculate(encoded[0..root_identity_offset]);
    @memcpy(encoded[root_identity_offset..], &forged_identity);
    try std.testing.expectError(error.InvalidPointer, Root.decode(&encoded));
}

test "file header is deterministic and checksummed" {
    var first: [control_size]u8 = undefined;
    var second: [control_size]u8 = undefined;
    encodeFileHeader(&first);
    encodeFileHeader(&second);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try validateFileHeader(&first);
    first[20] ^= 1;
    try std.testing.expectError(error.InvalidHeader, validateFileHeader(&first));
    encodeFileHeader(&first);
    first[64] = 1;
    try std.testing.expectError(error.InvalidHeader, validateFileHeader(&first));
    encodeFileHeader(&first);
    first[root_slot_base + root_slot_count * root_slot_size] = 1;
    try std.testing.expectError(error.InvalidHeader, validateFileHeader(&first));
}
