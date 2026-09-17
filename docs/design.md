# Design rationale

Chronotail's central design is a bounded graph of immutable, content-identified
objects with one small atomic publication point. That single choice removes
tail-scanning recovery, history-sized checkpoint reconstruction, interleaved
record decoding, and full-point aggregate scans while creating a clean future
replication boundary.

## Product focus

- Bound recovery with four authenticated roots instead of scanning an arbitrary file tail.
- Publish immutable manifests and per-series copy-on-write time trees instead of reconstructing mutable history.
- Store timestamps and values in separate columns so queries decode only what they use.
- Authenticate every persistent object and cross-object pointer with an external BLAKE3 identity.
- Make checkpoints proportional to new pages plus a bounded right spine rather than total history.
- Bulk-copy aligned raw columns rather than decoding raw records one at a time.
- Resolve repeated series queries once with generation-checked prepared handles.
- Stream large ranges through fixed-height cursors and caller-owned bounded buffers.
- Expose true zero-copy raw-page views with explicit snapshot lifetimes.
- Answer aggregates from persistent tree summaries and decode only boundary pages.
- Separate memory publication from data-sync-root-sync disk publication.
- Keep prepared append allocation-free within a caller-declared checkpoint bound.
- Derive every loop, stack, cache, page, and persistent integer bound explicitly.
- Keep format v6 immutable and migrate into a verified separate format-v7 file.
- Keep the product an embedded kernel while making immutable objects usable by a future replication design.

## Whole-system model

| Concern | Design choice | Result |
|---|---|---|
| Commit | One authenticated rotating root | A reader adopts a complete generation or keeps an older one. |
| Persistence | Immutable pages, indexes, and manifests | Snapshots and recovery do not depend on in-place repair. |
| Indexing | One append-specialized time tree per series | Independent series evolve without rewriting a global index. |
| Layout | Separate timestamp and value columns | Search, raw copy, compression, and aggregates can specialize. |
| Query acceleration | Exact summaries in every tree entry | Complete subtrees answer count/min/max/sum/first/last without point decode. |
| Memory | Fixed geometry plus caller bounds | Prepared data paths allocate no heap memory after setup. |
| Simulation | Compile-time file abstraction | Production logic runs against deterministic fault injection without runtime dispatch. |
| Migration | Verified copy into a new file | A major format change never destroys its only source. |

## TigerStyle lessons

The design applies the transferable parts of TigerBeetle's engineering style:
safety before performance, explicit bounds, assertions at persistent
boundaries, static data-plane memory, batching across slow resources, separate
control and data planes, no runtime dependency graph, and deterministic
simulation. The reference is TigerBeetle's official
[TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

Chronotail does not copy TigerBeetle's consensus or distributed state machine.
An embedded file has a different deployment and failure model. The shared idea
is that immutable authenticated units and small deterministic state transitions
make correctness, performance, and future transfer easier to reason about.

## Alternatives rejected

- **LSM tree:** ordered append has no overwrite workload to justify compaction,
  bloom filters, or read amplification.
- **Background workers:** they add scheduling, shutdown, durability, and test
  states without removing essential synchronous work.
- **In-place pages or indexes:** they make snapshots, crash recovery,
  authentication, and replication identities harder together.
- **One global series tree:** it couples independent streams and enlarges every
  append's copy-on-write surface.
- **Unbounded mapping retention:** convenient borrowed views would turn refresh
  count into hidden virtual-memory growth.
- **Automatic v6 rewrite:** a failed major migration could destroy the only
  verified source.
- **Runtime codec or storage dispatch:** compile-time specialization keeps hot
  loops direct and simulation on the production implementation.
- **Parallelism first:** deterministic bytes and a synchronous reference model
  must exist before bounded parallel page construction can be trusted.
- **A server in the current release:** networking would add operational promises
  unrelated to the embedded kernel.

## Tradeoffs accepted

- Small checkpoints write more structural metadata than v1 deltas in exchange
  for bounded recovery and history-independent publication shape.
- Reader refresh remaps the complete committed snapshot and invalidates prior
  handles and views; safe retention requires pinned snapshots.
- Columnar raw pages favor range copying but need not win every point lookup or
  tiny batch.
- BLAKE3 identities cost more CPU than the old payload checksum but authenticate
  complete objects and the pointers that name them.
- Manifest serialization still scales with series count and remains the clearest
  structural ceiling.
- Data pages are written independently today; measured bounded coalescing is a
  follow-up optimization, not a correctness shortcut.

## What distribution-ready means

Format v7 can name, verify, deduplicate, transfer, and repair immutable objects.
A root describes a complete snapshot, and per-series roots provide partitionable
transfer units. That is useful groundwork, not a distributed database.

A distributed edition would still require consensus, replica identity, quorum
durability, membership changes, backpressure, anti-entropy, observability, and a
network-fault simulator. Those guarantees belong in a separate explicit design.

See [architecture](architecture.md) for the implemented mechanics and the
[optimization roadmap](performance/optimization-roadmap.md) for measured next
experiments.
