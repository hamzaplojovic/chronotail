# Architecture

![Chronotail architecture](assets/architecture.svg)

Chronotail is a synchronous, dependency-free storage kernel for strictly
ordered time series. One writer publishes complete generations; readers hold
immutable committed snapshots and never coordinate with the writer through an
engine lock.

The public layers stay thin:

```text
Zig API ─────────────┐
C ABI ───────────────┼── storage engine ── portable .ctdb file
Python binding ──────┤
CLI ─────────────────┘
```

`src/chronotail.zig` is the Zig facade, `src/c_api.zig` translates ABI calls,
and `src/cli.zig` handles terminal presentation. `src/internal/` owns format-v7
mechanics. `AppenderFor(File)` and `ReaderFor(File)` specialize the same engine
at compile time for `std.fs.File` or deterministic simulated storage; production
has no runtime storage dispatch.

## Persistent object graph

The first 64 KiB is a fixed control region containing the format header and four
independent 4 KiB root slots. Everything after it is immutable and append-only.

```text
control region
  └── elected root (generation, committed extent, predecessor identity)
        └── manifest (stable series IDs and names)
              ├── series A time-tree root
              │     ├── authenticated index nodes with summaries
              │     └── authenticated columnar data pages
              └── series B time-tree root
                    ├── authenticated index nodes with summaries
                    └── authenticated columnar data pages
```

Creation publishes an authenticated empty generation. A later root names its
generation, committed extent, manifest, previous-root identity, and its own
128-bit BLAKE3 identity. Recovery validates a fixed set of root candidates and
can fall back when the newest root, manifest, or predecessor relationship is
incomplete. Nonzero root slots with no valid candidate fail closed.

Every cross-object pointer includes an offset, byte length, object kind, and
external identity. Authentication establishes exact bytes; decoders separately
validate bounds, reserved fields, ordering, codecs, and summary relationships.

## Columnar data pages

A 64 KiB data page encodes timestamps and values independently:

- timestamps use raw, exact base-step, or restart-bounded delta-varint encoding;
- values use raw or restart-bounded XOR-varint encoding;
- a compressed representation is retained only when it clears the declared
  minimum saving;
- every page carries exact count, timestamp bounds, and value summaries.

Separate columns let raw ranges bulk-copy timestamps and values, let timestamp
search avoid value decode, and let compression specialize each domain.

## Per-series copy-on-write indexes

Each series owns an append-specialized time tree. Leaves point to data pages;
internal entries point to child nodes and repeat exact subtree summaries. An
append rewrites only the right spine and publishes a new tree root. Fixed page
geometry and a maximum eight-level tree bound every traversal stack.

The summaries carry count, minimum, maximum, sum, first, last, and timestamp
bounds. Aggregate queries merge fully covered entries and decode only partially
covered boundary pages.

## Writer path

The writer validates an entire batch before mutation. Timestamps must increase
within the batch and begin after the series tail.

```text
validate batch
    → fill column buffers
    → encode and authenticate full pages
    → append copied index paths
    → write manifest
    → publish next root
```

`prepareSeries` reserves the page descriptors required by a caller-declared
maximum before the next checkpoint. Appending to that prepared series then uses
no heap allocation in the data plane. New-series creation and checkpoint
construction remain control-plane work and may allocate.

An operational write failure poisons the appender. It may be aborted, but it
cannot publish a partially mutated generation.

## Publication and durability

A memory checkpoint writes pages, copied index nodes, and the manifest before
publishing the next rotating root. Disk durability adds synchronization on both
sides of root publication:

```text
immutable objects → sync → root slot → sync
```

The root is the visibility boundary. Bytes beyond its committed extent are not
part of the snapshot. See [durability and recovery](durability.md) for failure
cases and operational guidance.

## Reader path

A production reader maps only the committed extent selected at open. Prepared
series handles avoid repeated UTF-8 hashing and carry their snapshot generation.
The main read shapes are:

- copied range into equal-length caller buffers;
- a persistent cursor that makes bounded progress with a fixed tree stack;
- borrowed timestamp/value slices from a raw mapped page;
- aggregate or fixed-resolution windows backed by persistent summaries.

Mapped reads and prepared-series lookup allocate no heap memory after open.
Borrowed views remain valid only until refresh or close.

## Snapshot refresh

`refresh()` first validates a newer complete generation, maps its committed
extent, and only then replaces the current snapshot. Replacement clears the
verification cache and invalidates prepared handles, cursors, and borrowed
views. Stale handles fail explicitly instead of silently resolving against a
different catalog generation.

The implementation currently remaps the complete committed extent. Retaining
old mappings or mapping only appended segments would require explicit snapshot
pinning and bounded reclamation; that belongs in a future snapshot API.

## Verification and simulation

`verifyPath` walks every reachable manifest, index node, and data page. It
authenticates bytes, validates semantic relationships, and rejects overlapping
physical ranges. Tests also forge valid identities around semantically invalid
objects to prove authentication never substitutes for structure checks.

The deterministic simulator injects crashes, short writes, failed writes,
truncation, and corruption through the compile-time file seam. Generic mutable
simulated storage reauthenticates every returned object, while immutable
production mappings can safely retain a per-snapshot verification cache.

## Compatibility boundary

Current files use format v7 and the native library exports C ABI v2. Format v6
is supported only as verified input to a separate-file migration. The engine
never rewrites a v6 database in place; see the [migration guide](migration.md).
