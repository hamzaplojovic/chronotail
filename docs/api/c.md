# C API v2

Include `chronotail.h` and link `libchronotail.a` or the platform shared library.
`ct_abi_version()` returns `2`; the header is the authority for exact signatures,
layouts, status values, and lifetime contracts.

The ABI uses opaque reader/writer handles and caller-owned buffers. No Zig type
or allocator crosses the boundary. Existing source-level operations remain:
`ct_open_writer`, `ct_append`, `ct_checkpoint`, `ct_open_reader`, `ct_refresh`,
`ct_range`, `ct_close`, and `ct_error_string`. ABI v2 does not claim binary
compatibility with ABI v1.

V2 adds:

- `ct_prepare_append` to reserve a declared append bound and avoid data-plane
  allocation until the next checkpoint;
- `ct_checkpoint_with_durability` with `CT_DURABILITY_MEMORY` and
  `CT_DURABILITY_DISK`;
- `ct_prepare_series` and `ct_range_prepared` for lookup-free repeated queries;
- `ct_aggregate` and `ct_aggregate_prepared` for persistent-summary queries;
- `ct_cursor_init` and `ct_cursor_next` for bounded range batches;
- `ct_borrow_raw_page` for zero-copy raw columns.

`ct_series_handle.reserved` and all cursor reserved bytes must be zero. Prepared
handles become invalid after `ct_refresh` and return `CT_STALE_SERIES`. Borrowed
page pointers remain valid only until refresh or close. `ct_range` and
`ct_range_prepared` return `CT_BUFFER_TOO_SMALL` and the required count when the
provided buffers cannot hold the full result. Append batches are validated
before mutation; operational failure poisons the writer.

V2 currently has no C migration entry point. Use `chronotail migrate-v6` or the
Zig `migrateV6` API for explicit v6-to-v7 conversion.
