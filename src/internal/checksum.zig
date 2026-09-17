const std = @import("std");

/// Persistent identities use the first 128 bits of BLAKE3. The complete
/// algorithm and truncation width are part of format v7 and therefore do not
/// depend on target-specific hash implementations or native integer layout.
pub const Identity = [16]u8;
pub const zero: Identity = [_]u8{0} ** 16;

pub fn calculate(bytes: []const u8) Identity {
    var full: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &full, .{});
    return full[0..16].*;
}

pub fn equal(a: Identity, b: Identity) bool {
    return std.crypto.timing_safe.eql([16]u8, a, b);
}

test "identity is deterministic and sensitive to every byte" {
    const first = calculate("chronotail-v2");
    const second = calculate("chronotail-v2");
    const changed = calculate("chronotail-v3");
    try std.testing.expect(equal(first, second));
    try std.testing.expect(!equal(first, changed));
}
