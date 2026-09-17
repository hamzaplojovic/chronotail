# Rethinking Chronotail from first principles

## Conclusion

The highest-reward redesign is not to turn Chronotail into a smaller distributed
database. It is to make the embedded kernel a graph of bounded, immutable,
content-identified objects with one tiny atomic publication point. That change
simultaneously attacks v1's recovery scan, periodic snapshot cliff, interleaved
decode cost, aggregate decode cost, and future replication barrier.

## Whole-system redesign

- **Commit unit:** the database state is one authenticated root, not “whatever valid trailer can be found near the tail.”
- **Persistence unit:** data pages, index nodes, and manifests are immutable objects; mutation creates a new path and root.
- **Index ownership:** each series owns an append-specialized time tree, avoiding a global mutable index and allowing independent future transfer/repair.
- **Physical layout:** timestamps and values are separate columns because timestamp search, count queries, value scans, and compression have different work.
- **Query acceleration:** exact summaries live in the same authenticated tree, so aggregates skip complete subtrees and decode boundary pages only.
- **Recovery:** four fixed root slots bound election work while predecessor identities detect broken publication succession.
- **Durability:** data and metadata become durable before the root that names them; a second sync makes publication durable.
- **Memory:** fixed page geometry, tree height, cursor stack, and verification cache replace history-sized query structures.
- **API:** copied buffers, prepared handles, bounded cursors, borrowed raw pages, and aggregates make cost and ownership visible.
- **Migration:** v6 remains immutable historical input; conversion verifies it and writes a separate v7 output.
- **Simulation:** the engine stays generic over a compile-time file type so crash and corruption schedules exercise production logic.
- **Distribution seam:** external object identities and immutable manifests are the correct replication boundary, but consensus, membership, networking, repair policy, and backpressure remain outside v2.

## Lessons taken from TigerBeetle

TigerBeetle's architecture is valuable here as a way of thinking, not as code to
copy. The relevant lessons are safety before performance, bounds on every
resource, assertions at both sides of persistent boundaries, static data-plane
memory, batching across slow resources, explicit control/data planes, no runtime
dependency graph, deterministic simulation, and doing the high-multiple work in
the design phase. The source is the current official
[TigerStyle document](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

Chronotail deliberately does not copy TigerBeetle's consensus or distributed
state-machine architecture. An embedded time-series file has a different failure
and deployment model. The transferable idea is that immutable authenticated
units plus a small deterministic state transition make both correctness and
future distribution easier.

## Designs reconsidered and rejected

- **LSM tree:** ordered append has no overwrite workload to justify compaction, bloom filters, or read amplification.
- **Background workers:** they would add scheduling, shutdown, durability, and test state without removing essential synchronous work.
- **In-place pages or indexes:** they would make snapshots, crash recovery, checksums, and replication identities harder at once.
- **One global series tree:** it would couple independent series and enlarge every append's copy-on-write surface.
- **Unbounded mapping retention:** it makes borrowed views easy but turns refresh count into hidden virtual-memory growth.
- **Automatic v6 rewrite:** it risks destroying the only verified source during a major-format transition.
- **Runtime codec/storage dispatch:** compile-time specialization keeps hot loops direct and simulation on the same implementation.
- **Parallelism first:** synchronous deterministic bytes establish the reference behavior; parallel page building is a later bounded optimization.
- **A server in v2:** networking would dilute the kernel redesign and introduce operational promises unsupported by the current product scope.

## What “distributed-ready” actually means

Format v7 can name, transfer, verify, deduplicate, and repair immutable objects by
identity. A manifest/root can describe a complete snapshot, and per-series roots
permit partitioned transfer. That is useful groundwork, but it is not a
distributed database. A real distributed edition still needs a consensus model,
replica identity, quorum durability, membership changes, flow control,
anti-entropy, observability, and a simulator that includes network faults. Those
should be a separate design with explicit guarantees rather than implied by the
file format.

## Tradeoffs accepted in v2

- Small checkpoints write more structural metadata than v1 deltas in exchange for bounded recovery and history-independent checkpoint shape.
- A full reader refresh remaps the committed snapshot and invalidates handles/views; safe cross-refresh borrowing awaits pinned snapshots.
- Columnar raw storage optimizes range copies but may not win every single-point or tiny-batch workload.
- BLAKE3 identities cost more CPU than v1's FNV payload checksum but authenticate complete persistent objects and pointers.
- Manifest serialization still scales with series count; it is the clearest remaining structural ceiling.
- Page writes are independent today; coalescing them is a measured optimization, not a correctness shortcut.

## Completion rule

V2 implementation is complete only when format/migration tests,
Debug/ReleaseSafe/ReleaseFast, C and Python integration, deterministic
simulation, internal profiling against the saved v1 run, documentation checks,
and release smoke tests pass. The unchanged public competitive benchmark is the
next, separate evidence run after handoff, so development cannot tune against
competitor winners or present partial measurements as a release claim.
