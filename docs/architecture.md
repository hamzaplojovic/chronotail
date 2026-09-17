# Architecture

![Chronotail v2 architecture](assets/architecture.png)

Chronotail v2 is a synchronous, dependency-free storage kernel for strictly
ordered time series. `src/chronotail.zig` is the public Zig facade,
`src/c_api.zig` owns ABI translation, `src/cli.zig` is presentation, and
`src/internal/` owns format-v7 implementation details. `AppenderFor(File)` and
`ReaderFor(File)` specialize the same engine at compile time for `std.fs.File`
or deterministic simulated storage; production has no runtime storage dispatch.

## Persistent graph

The first 64 KiB is a fixed control region containing a checksummed format
header and four independent 4 KiB root slots. Creation publishes an
authenticated empty generation so the first data checkpoint already has a
valid fallback. Each root names a generation, committed extent, manifest,
previous-root identity, and its own 128-bit BLAKE3 identity. Recovery validates
a bounded set of slots and can fall back when the newest root, manifest, or
predecessor link is torn or invalid. Nonzero root slots with no valid candidate
fail closed instead of being mistaken for an empty database.

Everything after the control region is immutable and append-only:

1. Columnar data pages encode timestamps and values independently. Timestamps
   use raw, exact base-step, or restart-bounded delta-varint encoding; values use
   raw or restart-bounded XOR-varint encoding. A codec is retained only when it
   clears the declared minimum saving.
2. Per-series copy-on-write time trees map timestamp ranges to data pages.
   Appends rewrite only the right spine. Internal entries carry deterministic
   count/min/max/sum/first/last summaries.
3. A manifest maps stable series IDs and names to authenticated tree roots and
   summaries.

Every cross-object pointer contains an offset, byte length, object kind, and
external identity. Authentication proves exact bytes; decoders separately
validate bounds, reserved bytes, ordering, codecs, and summary relationships.

## Publication and durability

A checkpoint flushes pending pages, writes copied index nodes and the manifest,
then publishes the next rotating root. `.memory` durability makes the new root
visible without promising power-loss persistence. `.disk` performs:

```text
pages/index/manifest -> sync -> root slot -> sync
```

Operational write failure poisons the appender until `abort()`. Batch timestamp
and shape validation completes before mutation. Format-v6 files are recognized
but never rewritten: `migrate-v6` reads the last valid v6 snapshot and creates a
separate v7 database.

## Data plane

After open, mapped queries and prepared-series lookup allocate no heap memory.
Appender data-plane allocation is also eliminated when callers declare their
maximum points before the next checkpoint with `prepareSeries`. Fixed bounds
come from the 64 KiB page, 4 KiB index fanout, eight-level maximum tree height,
caller buffers, and a fixed verification cache.

Copied ranges bulk-copy aligned raw columns. Persistent cursors retain a bounded
tree stack and page position between calls. Raw-page views borrow immutable
mapped timestamp/value slices until reader refresh or close. Aggregate and
fixed-resolution window queries consume complete subtree summaries and decode
only boundary pages.

## Snapshot lifecycle

A reader maps only the committed extent selected at open. `refresh()` validates
and maps a newer complete generation, replaces the old snapshot, clears the
verification cache, and invalidates prepared handles, cursors, and borrowed
views. Handles carry their generation and fail with `StaleSeriesHandle` rather
than silently targeting a different catalog entry.

The current implementation remaps the complete new committed extent during
refresh. Retaining old mappings or mapping only appended extents was rejected
for v2 because borrowed-view lifetime would otherwise require explicit pinning
and bounded reclamation. A separate snapshot object is the preferred future
design if cross-refresh view lifetime becomes necessary.

## Verification and simulation

`verifyPath` walks every reachable manifest, index node, and data page; validates
identities and semantic relationships; and rejects overlapping physical object
ranges. The deterministic simulator injects crashes, short and failed writes,
truncation, and corruption through the same generic engine. Format tests also
forge valid checksums around semantically invalid roots, indexes, and pages to
ensure identity checks never substitute for structural validation.

Production verification caching is tied to one immutable mmap snapshot.
Generic storage has no mmap immutability guarantee and therefore
re-authenticates every index/page read; this is what lets corruption simulation
mutate its backing bytes without turning a prior cache hit into silent data.
