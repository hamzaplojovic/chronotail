# C API

Include `chronotail.h` and link `libchronotail.a` or the shared library. The
current library exposes C ABI v2; check `ct_abi_version() == 2` at startup when
the library can be selected dynamically.

```bash
clang -std=c11 app.c \
  -Izig-out/include \
  -Lzig-out/lib -lchronotail \
  -Wl,-rpath,"$PWD/zig-out/lib" \
  -o app
```

For an extracted release archive, replace `zig-out/include` and `zig-out/lib`
with its `include` and `lib` directories. Add the release `lib` directory to
`DYLD_LIBRARY_PATH` when the executable does not embed an rpath.

The header is authoritative for exact signatures, layouts, status values, and
lifetime contracts. No Zig type or allocator crosses the boundary.

## Error handling

Every operation except `ct_abi_version` and `ct_error_string` returns a status.
Keep the numeric value for program logic and use `ct_error_string` for display:

```c
#include "chronotail.h"
#include <stdio.h>
#include <stdlib.h>

static void check(int status, const char *operation) {
    if (status == CT_OK) return;
    fprintf(stderr, "%s: %s (%d)\n", operation,
            ct_error_string(status), status);
    exit(1);
}
```

`CT_BUFFER_TOO_SMALL` is a sizing result rather than corruption. Negative codes
represent errors. A handle is either a writer or reader; passing it to the wrong
operation returns `CT_WRONG_HANDLE`.

## Writer lifecycle

```c
#include "chronotail.h"
#include <stdint.h>
#include <string.h>

int write_points(void) {
    const char *path = "metrics.ctdb";
    const char *series = "cpu";
    int64_t timestamps[] = {1000, 1001, 1002};
    double values[] = {42.5, 43.1, 42.8};
    ct_handle *writer = NULL;

    check(ct_open_writer(path, strlen(path), CT_CODEC_COMPRESSED, &writer),
          "open writer");
    check(ct_prepare_append(writer, series, strlen(series), 3), "prepare");
    check(ct_append(writer, series, strlen(series), timestamps, values, 3),
          "append");
    check(ct_checkpoint_with_durability(writer, CT_DURABILITY_DISK),
          "checkpoint");
    check(ct_close(writer), "close writer");
    return 0;
}
```

The complete append batch is validated before mutation. Timestamps must be
strictly increasing and later than the prior series tail. Operational failure
poisons the writer; `ct_close` then aborts unpublished state and returns
`CT_POISONED_WRITER`.

`ct_prepare_append` reserves a maximum before the next checkpoint so steady
append performs no heap allocation. `ct_checkpoint(handle, 0|1)` remains a
convenience wrapper for memory or disk durability.

## Two-pass copied range

Call with zero capacity to obtain the required count, allocate equal-length
timestamp and value arrays, then retry:

```c
ct_handle *reader = NULL;
size_t count = 0;
check(ct_open_reader(path, strlen(path), &reader), "open reader");

int status = ct_range(reader, series, strlen(series), 0, INT64_MAX,
                      NULL, NULL, 0, &count);
if (status != CT_OK && status != CT_BUFFER_TOO_SMALL) {
    check(status, "size range");
}

int64_t *timestamps = malloc(count * sizeof(*timestamps));
double *values = malloc(count * sizeof(*values));
if (count != 0 && (timestamps == NULL || values == NULL)) return 1;

size_t actual = count;
check(ct_range(reader, series, strlen(series), 0, INT64_MAX,
               timestamps, values, count, &actual), "read range");
```

On `CT_BUFFER_TOO_SMALL`, `count` contains the total required capacity and the
provided buffers contain the available prefix. Use `ct_prepare_series` and
`ct_range_prepared` to avoid repeated series-name lookup. A prepared handle's
`reserved` field must remain zero.

## Bounded cursor

```c
ct_range_cursor cursor = {0};
check(ct_cursor_init(reader, series, strlen(series), start, end, &cursor),
      "cursor init");

int64_t timestamps[4096];
double values[4096];
while (!cursor.complete) {
    size_t count = 0;
    check(ct_cursor_next(reader, &cursor, timestamps, values, 4096, &count),
          "cursor next");
    consume(timestamps, values, count);
}
```

Zero-initialize `ct_range_cursor`; all reserved bytes must stay zero. Cursor
capacity must be positive.

## Aggregates and borrowed pages

```c
ct_series_handle prepared = {0};
ct_aggregate_result aggregate = {0};
check(ct_prepare_series(reader, series, strlen(series), &prepared), "prepare");
check(ct_aggregate_prepared(reader, prepared, start, end, &aggregate),
      "aggregate");
```

The aggregate returns count, minimum, maximum, sum, first, and last. Empty
ranges have count and sum zero and NaN for the other fields.

`ct_borrow_raw_page` returns pointers owned by the reader's mapped snapshot.
They remain valid only until `ct_refresh` adopts a new generation or
`ct_close` runs. The function can return `CT_PAGE_NOT_RAW`,
`CT_TIMESTAMP_NOT_FOUND`, or `CT_BORROWED_VIEW_UNAVAILABLE`.

## Refresh and close

```c
uint8_t changed = 0;
check(ct_refresh(reader, &changed), "refresh");
if (changed) {
    /* Recreate prepared handles and cursors; discard borrowed pointers. */
}
check(ct_close(reader), "close reader");
```

`ct_close` consumes the handle even when it reports an error. Do not reuse or
close it twice.

ABI v2 is not binary-compatible with C ABI v1. The original operation names are
retained where their source-level contracts still apply. Migration is exposed
through the CLI and Zig API, not the C ABI.

## API reference

| Symbol | Contract |
|---|---|
| `ct_abi_version` | Returns the loaded ABI version; current clients require `2`. |
| `ct_error_string` | Returns static display text for a status code. |
| `ct_open_writer` | Opens or creates a writer with raw or adaptive compression. |
| `ct_prepare_append` | Declares the per-series bound before the next checkpoint. |
| `ct_append` | Validates and appends one timestamp/value batch. |
| `ct_checkpoint_with_durability` | Publishes with `CT_DURABILITY_MEMORY` or `CT_DURABILITY_DISK`. |
| `ct_checkpoint` | Compatibility convenience accepting a boolean sync flag. |
| `ct_open_reader` | Opens and validates one immutable snapshot. |
| `ct_refresh` | Adopts a newer complete generation and reports whether it changed. |
| `ct_range` | Copies a named-series prefix and returns total required capacity. |
| `ct_prepare_series` | Resolves a series to a generation-bound handle. |
| `ct_range_prepared` | Performs the copied range using a prepared handle. |
| `ct_aggregate` / `ct_aggregate_prepared` | Computes count/min/max/sum/first/last. |
| `ct_cursor_init` / `ct_cursor_next` | Streams a range through fixed caller buffers. |
| `ct_borrow_raw_page` | Borrows snapshot-owned raw column pointers. |
| `ct_close` | Consumes a reader or writer handle even when teardown reports an error. |

The enum values and structure layouts in
[`include/chronotail.h`](../../include/chronotail.h) are authoritative. All
lengths are byte or element counts as documented by their parameter names;
strings are not required to be NUL-terminated.
