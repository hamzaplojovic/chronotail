# Chronotail v2 pitch

Each focus is intentionally one line:

- Replace tail scanning with four authenticated roots so recovery work is fixed and bounded.
- Replace historical footer reconstruction with immutable manifests and per-series copy-on-write time trees.
- Store timestamps and values as separate columns so each query decodes only what it needs.
- Give every persistent object an external BLAKE3 identity so corruption and misdirected reads are detectable.
- Make checkpoints proportional to new pages plus a bounded right spine instead of total history.
- Make raw copied reads two bulk memory transfers instead of a record-by-record decode loop.
- Make repeated queries resolve a series once through generation-checked prepared handles.
- Make large ranges incremental through fixed-height persistent cursors and caller-owned buffers.
- Make raw consumers truly zero-copy through borrowed mapped pages with explicit snapshot lifetimes.
- Make aggregates skip point decoding through deterministic summaries stored at every tree level.
- Make durability explicit as memory publication or data-sync-root-sync disk publication.
- Make steady append allocation-free when the caller declares its maximum points before checkpoint.
- Keep all loops, stacks, caches, page sizes, identities, and persistent integer domains explicitly bounded.
- Keep v6 frozen and migrate into a separate v7 file only after full checksum and semantic validation.
- Keep Chronotail an embedded kernel while making immutable objects replication-ready for a future distributed layer.
- Measure changes internally against the saved v1 baseline before touching the unchanged public benchmark.

The design follows TigerBeetle's published priority order—safety, then performance,
then developer experience—and its emphasis on bounded resources, batching,
static data-plane memory, explicit types, and deterministic simulation:
[TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
