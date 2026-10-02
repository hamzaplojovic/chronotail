// Import internal tests into one module so `zig build test` runs them too.
test {
    _ = @import("checksum.zig");
    _ = @import("format.zig");
    _ = @import("page.zig");
    _ = @import("index.zig");
    _ = @import("manifest.zig");
    _ = @import("engine.zig");
    _ = @import("v6_reader.zig");
}
