# Chronotail v2 engine design

Status: accepted for implementation on the `v2` branch.

## Implementation status — 2026-09-17

Implemented on the branch:

- format v7's 64 KiB control region, authenticated empty generation, four
  rotating roots, predecessor identity, immutable pages/indexes/manifests, and
  external 128-bit BLAKE3 identities;
- independently encoded raw/base-step/delta-varint timestamp columns and
  raw/XOR-varint value columns with 128-point restart bounds;
- per-series append-specialized copy-on-write indexes, fixed-height traversal,
  persistent summaries, prepared series, persistent cursors, borrowed raw-page
  views, aggregate queries, and fixed-resolution aggregate windows;
- caller-declared writer capacity, allocation-free prepared append and warm
  query paths, bulk raw-column copies, and coalesced multi-node index writes;
- two-phase disk durability, writer poisoning, bounded root recovery, explicit
  v6 recognition, and a separate verified v6-to-v7 migration tool;
- C ABI v2 and Python 2.0 bindings while retaining the original source-level C
  entry points; ABI-v1 binary compatibility is not claimed;
- deterministic byte tests, checksummed-but-invalid semantic tests, v6 raw and
  compressed migration fixtures, the failure simulator, and the internal
  performance matrix with an ignored v1 baseline.

Deliberate implementation differences from the initial sketch:

- the bounded codecs are delta-varint and XOR-varint, not a claim of full
  delta-of-delta or Gorilla compatibility;
- reader refresh remaps the complete newly committed snapshot, invalidates
  handles/views, and does not retain old borrowed views; safe cross-refresh
  borrowing requires an explicit pinned-snapshot/reclamation design;
- page writes remain independently issued; only multi-node index levels are
  coalesced. Page-write coalescing remains an optional measured optimization,
  not a v2 correctness requirement.

Implementation evidence is complete: the full three-pass internal candidate
profile covers 179 workloads, all eight measured steady-state paths report zero
allocator activity, all release verification modes pass, and the extended
simulator completed 1,000 seeds and 100,000,000 operations with zero invariant
failures. See the [internal performance report](../v2-performance-report.md).
The unchanged public competitive benchmark is intentionally the next separate
run after handoff. No public v2 performance claim is made by this plan.

The remainder of this document preserves the accepted pre-implementation design
record. Where it differs from the implementation, the status and deliberate
difference sections above are authoritative.

## Objective

Chronotail v2 is a deterministic, bounded-memory, columnar time-series kernel
built from immutable pages and persistent indexes. It retains strictly ordered
timestamps, one committer, immutable reader snapshots, dependency-free runtime
paths, explicit durability, and deterministic simulation.

The redesign targets structural gains rather than format-v6 micro-optimizations:

- checkpoint work must not periodically scale with historical block count;
- recovery must start from redundant bounded root metadata rather than scan an
  arbitrary damaged tail;
- timestamps and values must be independently searchable and decodable;
- readers must support copied ranges, bounded cursors, and borrowed raw pages;
- aggregate queries must skip raw decoding through persistent summaries;
- data-plane work after open must remain allocation-free within declared bounds;
- immutable data units must have deterministic bytes and external identities so
  a future replication layer can transfer and repair them physically.

## File layout

The first 64 KiB is a fixed control region. It contains a format header and four
independent root slots. A valid root slot contains a generation, committed file
extent, manifest pointer, previous root identity, and its own checksum. Writers
rotate slots; a torn or corrupt new slot leaves older generations valid.

Everything after the control region is immutable and append-only:

1. Columnar data pages contain a header, restart directory, timestamp stream,
   value stream, statistics, and checksum.
2. Persistent index nodes map timestamp ranges to data pages or child nodes.
3. A manifest maps series names and IDs to index roots and tail state.

Pointers crossing persistent boundaries contain an offset, byte length, and
external 128-bit identity. Parent metadata authenticates the exact child and
therefore detects both damaged bytes and misdirected reads.

## Data pages

A physical write segment may contain multiple independently decoded logical
pages. Logical pages remain bounded near 64 KiB for random-query latency; writes
may combine pages to amortize syscalls.

Timestamp and value columns are encoded separately. Initial v2 codecs are:

- raw columnar timestamps and raw `f64` values;
- base-and-step timestamps when exact regularity is proven;
- delta/delta-of-delta timestamps with bounded restart groups;
- Gorilla-style values with bounded restart groups;
- adaptive per-page selection that must beat raw by a declared minimum.

Every page stores count, first and last timestamp, first and last value, minimum,
maximum, and deterministic aggregate state. Floating-point aggregate merge order
is fixed by tree order.

## Persistent index

Each series owns an append-specialized copy-on-write time tree. Appending changes
only the rightmost path. A checkpoint writes new leaves and copied right-spine
nodes, then publishes a manifest pointing at the new roots. Old roots remain
valid snapshots.

Reader traversal uses a fixed-height stack derived from address width and node
fanout. No recursive traversal is permitted. Index pages are mapped and checked
lazily; opening a reader must not materialize every historical block descriptor.

Internal nodes store combined statistics. Resolution-aware aggregate queries can
consume complete subtrees without visiting leaves or decoding point values.

## Writer pipeline

The writer resolves a series once, validates an entire homogeneous batch before
mutation, partitions it into bounded pages, encodes independent pages, writes
immutable bytes, updates right-spine index nodes, writes the manifest, and finally
publishes a root slot. Operational failure poisons the writer until abort.

The initial implementation is synchronous. A bounded parallel page builder may
be added only after deterministic output and the single-threaded baseline are
stable. Parallel completion order must never influence persistent bytes.

## Reader API

- Copied range: caller-owned timestamp and value buffers.
- Cursor range: bounded incremental progress without count-then-decode repetition.
- Borrowed raw view: immutable timestamp/value slices tied to snapshot lifetime.
- Aggregate range: count, minimum, maximum, first, last, sum, and resolution.
- Prepared series: string lookup occurs once outside repeated queries.

Reader refresh validates a newer root, maps only the newly committed extent, and
adopts an immutable snapshot. Existing snapshots and borrowed views remain valid
until explicitly closed.

## Compatibility and migration

Format v6 stays frozen. V2 recognizes v6 files and provides a verified migration
tool that reads committed v6 snapshots and writes a separate v7 file. It never
silently rewrites a v6 database in place. The v1 ABI remains available for source
compatibility; ABI v2 adds prepared-series, cursor, view, aggregate, and explicit
durability APIs.

## Verification gates

Each storage milestone requires:

- Debug, ReleaseSafe, and ReleaseFast tests;
- byte-determinism fixtures;
- malformed and checksummed-but-invalid page/index/root tests;
- deterministic crash, short-write, failed-write, truncation, and corruption
  simulation using the production-specialized engine;
- v6-to-v7 migration comparison over raw and compressed fixtures;
- the internal performance matrix compared against the saved v1 baseline;
- the unchanged public competitive benchmark only after v2 is complete.

No change is retained if it weakens a safety invariant or hides a measured
regression without an explicit, documented architectural tradeoff.
