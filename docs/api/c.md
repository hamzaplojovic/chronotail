# C API v1

Include `chronotail.h` and link `libchronotail.a` or `libchronotail.dylib`. Version 1.0.0 supports macOS ARM64.

- `ct_abi_version()` returns `1`.
- `ct_open_writer()` opens the exclusive writer.
- `ct_append()` accepts an all-or-nothing timestamp/value batch.
- `ct_checkpoint()` publishes a checkpoint and optionally calls `fsync`.
- `ct_open_reader()` opens an immutable reader snapshot.
- `ct_refresh()` adopts a newer completed checkpoint.
- `ct_range()` writes points into caller-owned buffers.
- `ct_close()` closes either handle.
- `ct_error_string()` describes status codes.

No Zig type or allocator crosses the ABI. See `include/chronotail.h` for exact signatures and status constants.
