# Chronotail mechanical model

> Historical pre-redesign model for v1/format v6. Its bottlenecks motivated the
> [v2 design](../plans/2026-09-17-v2-engine-design.md); statements describing the
> “current architecture” below intentionally describe v1 and are not v2 claims.

Status: pre-architecture model. No engine changes were made while deriving it.

## Machine and conservative ceilings

Host: Apple M1, 8 cores, 8 GiB unified memory, 16 KiB pages, 128-byte cache lines, APFS on the internal SSD. The performance cores run at approximately 3.2 GHz, but frequency is dynamic, so cycle estimates are ranges rather than measurements.

A local pointer-chasing/cache-line read probe over 256 MiB sustained 22.5–25.3 GiB/s. This is a deliberately conservative useful-data bandwidth for irregular engine access. Sequential hardware bandwidth can be higher; this model uses 25 GiB/s unless a path is demonstrably cache-resident. Existing durable checkpoints measured 0.32 ms median at a 1 MiB logical interval and 0.76 ms at 10 MiB. These include filesystem behavior and are more useful than a synthetic SSD headline.

Format constants establish hard local bounds:

- 64 KiB block; 48-byte header.
- 16 bytes per raw record; at most 4,093 records per block.
- 128 records per compressed mini-chunk; at most 32 chunks per block.
- At most 63 delta footers before a snapshot.
- Footer series/block counts are `u32`; names are at most `u16` bytes; offsets are `u64`.

At 25 GiB/s, pure transfer ceilings are approximately:

- 1.68 billion 16-byte records/s for one read or write stream.
- 839 million records/s if each record causes 16 bytes read and 16 bytes written.
- 8.39 million 100-point raw queries/s for 3,200 useful bytes/query (1,600 input plus 1,600 output), before search and control overhead.

These are bandwidth ceilings, not achievable API ceilings. Dependencies, branches, ABI crossings, checksums, and latency lower them.

## Current architecture in machine terms

The writer and reader currently share one large `Series` representation. It includes name/index metadata, writer-only pending state, and an inline 64 KiB block buffer. Reader catalog reconstruction therefore allocates and moves writer-only storage. A block index is approximately 56 bytes: block bounds and location share cache lines with codec, verification flags, and a cached slice. With 128-byte cache lines, binary search touches roughly one line per dependent probe and only two entries fit per line.

Production readers mmap the file. Each reader owns mutable catalog/index and verification flags, while immutable block bytes are shared by the page cache. Raw warm queries do no allocation, syscall, checksum, or header parsing. Writer append is allocation-free between block-index growth events. Compressed scratch is stack-resident. Checkpoint footer storage is reused.

This suggests a likely “super idea”: **separate immutable prepared reader snapshots from mutable writer state, and split query-hot search metadata from cold block/control metadata**. It can remove reader-only waste and duplicated mutable facts while enabling a search policy prepared once at open/refresh. This is a hypothesis, not yet a decision.

## Operation models

### Raw single append

Minimum correct work:

1. Resolve series.
2. Compare one timestamp with the authoritative tail.
3. Encode/store 16 bytes in the pending block.
4. Increment pending count and update tail/dirty state.
5. Amortized per block: checksum 65,488 payload bytes, issue one `pwrite`, and append one block descriptor.

Current extra work includes C handle/tag dispatch, repeated series-name comparison, bounds/error branches, and occasional block-index allocation. Raw flush no longer copies the payload.

Resource model:

- Disk/page cache: 16 logical bytes/record plus 48 bytes/block and footer overhead.
- Memory traffic: roughly 16-byte record write plus metadata; block checksum rereads 16 bytes/record, then kernel/file-page copying dirties another 16 bytes/record.
- CPU: encode two 64-bit values, timestamp/order branches, and 16 serial FNV-1a byte steps amortized during flush.
- Syscalls: one `pwrite` per 4,093 records; explicit checkpoint adds footer/trailer writes and optionally `fsync`.
- Allocation: none normally; possible geometric index growth on block rollover.

FNV's serial multiply/XOR chain gives a more realistic CPU ceiling than bandwidth. At roughly 2–4 cycles per dependent byte step, checksum work alone implies about 50–100 million records/s per writer core. Current no-sync append is 26.8M/s: approximately 27–54% of this plausible ceiling and only 0.43 GiB/s logical. Classification: **CPU/algorithm bound between rollovers; checksum and page-cache write bound at rollover; filesystem bound at durable checkpoint**.

### Batched append

Minimum work differs only in control amortization:

- Resolve series once.
- Prove `old_tail < first` and every adjacent timestamp increases.
- Encode contiguous records.
- Update metadata once per batch where possible.

Current code still invokes record encoding/metadata updates per point and validates with a scalar loop. The data itself is contiguous, so the theoretical transfer ceiling is far above current rates. The budget is removal of per-record control, vector-friendly validation, and contiguous encode/copy. Classification: **CPU/branch bound**, with checksum/write rollover costs amortized.

### Checkpoint

Minimum work:

1. Flush each nonempty pending series block.
2. Serialize descriptors for new blocks/series into a delta footer.
3. Hash footer bytes.
4. Write footer and 32-byte trailer.
5. Optionally synchronize.

Delta checkpoint CPU work is O(series + newly committed blocks). Every 64th checkpoint is a v6 snapshot and is O(all series + all blocks). That full snapshot is an unavoidable v6 latency cliff: it bounds recovery-chain depth but makes one checkpoint proportional to database history. Current code has no hidden full scan on ordinary deltas, but snapshot checkpoints are explicitly database-size work.

Syscalls are one `pwrite` per pending block, one footer write, one trailer write, and optional `fsync`. Current 10 MiB durable throughput is 24.0M records/s and only 3% above the prior engine because sync dominates. Classification: **filesystem/synchronization bound for durable checkpoints; serialization/checksum bound for unsynchronized high-frequency checkpoints**.

### Warm raw point lookup

Minimum work with arbitrary strictly increasing timestamps:

1. Resolve series.
2. Identify block.
3. Identify record within block.
4. Read one 16-byte record and write one timestamp/value result.

Current work:

- Linear series-name search.
- Binary search over approximately 245 block descriptors for the 1M-point dataset: about 8 dependent probes.
- Binary search within up to 4,093 records: about 12 dependent probes.
- Codec branch and range-loop setup.
- One result copy.

A generic binary search therefore requires around 20 dependent loads/branches before the useful 16-byte result. Bandwidth is irrelevant; latency and branch prediction dominate. A prepared dense/near-linear timestamp model could approach one estimate, a bounded correction, and one record load. A plausible cache-resident minimum is 30–100 ns/query (10–33M/s), while arbitrary cold index probes are slower. Current average is 373 ns/query (2.68M/s), p50 125 ns. Classification: **algorithm and dependent-cache-latency bound**. Estimated budget: roughly 3–10x in favorable timestamp distributions, less for adversarial irregular series.

### Warm raw range lookup

Minimum work:

- Pay point-search cost once.
- Sequentially read and output each adjacent record.
- Stop at the end timestamp or block boundary.

For 100 points, useful traffic is about 3.2 KiB/query. The 25 GiB/s ceiling is 8.39M queries/s. Current single-reader performance is 1.74M/s, about 21% of that conservative bandwidth ceiling. Search overhead is significant at width 100. In the 8/32-reader competitive tests, aggregate throughput is 8.39/8.61M queries/s, corresponding to about 26.8/27.6 GB/s of useful input+output alone. Those runs are already approximately at the measured memory ceiling. Classification: **single reader: CPU/search bound; many readers: memory-bandwidth bound**.

For ranges of 1,000–full-series width, search amortizes away. The plausible ceiling approaches 839M returned points/s based on 32 useful bytes/point. Branching, endian loads, caller buffer stores, and cross-block checks reduce it. Width-specific diagnostics are required before changing the loop.

### Compressed range

Minimum work:

- Binary-search at most 32 chunk checkpoints.
- Start from the preceding 128-record checkpoint.
- Sequentially reconstruct timestamp delta-of-delta and Gorilla XOR state.
- Decode skipped prefix plus requested records.

A random 100-point query decodes approximately 64 skipped records on average plus 100 results, often crossing a chunk: about 164 stateful records. Current 329k queries/s therefore means roughly 54M decoded records/s. At 3.2 GHz this is approximately 59 cycles/decoded record, including search and output. The serial varint/Gorilla dependency suggests a plausible 20–40 cycle lower bound, giving only about 1.5–3x remaining CPU budget without a format change. Classification: **CPU/dependency/branch bound**, not bandwidth bound.

### Reader refresh

Unchanged refresh minimum under cross-process file semantics is one observation of file size or generation. Chronotail performs one `fstat` and returns if size is unchanged. The 2M-call probe takes 0.79s, about 395 ns/call or 2.53M refreshes/s. Classification: **syscall bound and near the architectural minimum**.

Changed refresh must find/validate the latest trailer/footer, reconstruct at most 64 footer-chain nodes, build a new catalog, preserve only verification state tied to identical immutable block descriptors, map the new file extent, and atomically replace reader-owned state. It allocates and copies substantial writer-only `Series` storage today. Classification: **control-plane allocation/parsing bound**, with explicit footer-chain bound but database-size metadata work at snapshots.

### Open/reopen

Open reads the header, searches backward in 64 KiB windows for a valid trailer, verifies footer checksums, reconstructs at most 64 footer nodes, allocates series/index state, and mmaps the file. Normal valid files inspect the tail and footer chain; corrupted/trailing data can force scanning toward the file start. Thus worst-case recovery search is O(file size), intentionally bounded by file size but capable of high latency.

Current reader open is about 0.29 ms for the diagnostic database. Classification: **control-plane syscall, allocation, checksum, and parsing bound**. It is the correct place to spend work that can remove data-plane work.

### Verify

Verification must read every committed block, checksum every payload, decode all timestamps (and compressed values) to prove ordering/format invariants, verify footer-chain regions, and sort/check file intervals. Minimum complexity is O(file bytes + records + footer bytes). Raw verification is checksum/memory/disk bound; compressed verification is codec CPU bound. It is intentionally control-plane work and cannot safely be reduced below one complete pass.

### One writer with 1/8/32 readers

Readers own no shared engine lock or atomic and access immutable mapped bytes. Remaining interference is scheduler, shared cache, unified-memory bandwidth, and filesystem/page-cache activity from the writer.

- 1 reader: 2.32M 100-point queries/s, approximately 7.4 GB/s useful input+output; writer 14.7M records/s. Reader remains CPU/search bound.
- 8 readers: 8.39M queries/s, approximately 26.8 GB/s useful traffic; writer 8.23M records/s.
- 32 readers: 8.61M queries/s, approximately 27.6 GB/s useful traffic; writer 7.90M records/s.

The 8-to-32 plateau matches the measured 25 GiB/s useful-data ceiling. Writer loss is primarily memory/cache/scheduler interference, not engine synchronization. Classification: **memory-bandwidth bound at 8+ readers; CPU/core bound at one reader**.

## Bounds audit before architecture changes

Clearly bounded:

- Records/block: 4,093.
- Compressed chunks/block: 32; records/chunk: 128.
- Footer-chain traversal: 64.
- Binary search iterations: logarithmic in block count and at most 12 within a block.
- Compressed decode for one selected chunk: 128 records; a range may consume further chunks proportional to requested output.
- Name length, series IDs, footer entry counts, block counts: bounded by on-disk integer widths and file size.

Potential latency/memory cliffs requiring design work:

- Snapshot footer construction every 64 checkpoints is O(total block count).
- Block-index arrays grow geometrically during writer operation.
- Reader catalog reconstruction allocates/moves inline 64 KiB buffers that readers never use.
- Series lookup is O(series count) on every append/query.
- Full or huge ranges are O(matches), as required, but C capacity discovery still decodes/counts every match.
- Corrupt-tail footer search can be O(file size).
- Verification interval storage grows with every block/footer region and is sorted O(regions log regions).

No recursion exists in the engine. All apparent unbounded loops are bounded by file size, footer counts, block record counts, requested result cardinality, or integer-domain limits, but several bounds are too indirect to provide predictable memory/tail latency.

## Allocation model before architecture changes

After writer open:

- Normal point append: zero allocation.
- Block rollover: block-index capacity may grow.
- New series: name, series array, and index allocations.
- Checkpoint: reused footer buffer, but it may grow when a larger footer/snapshot appears.

After production reader open:

- Warm mapped raw/compressed lookup: zero allocation.
- First block verification: zero allocation on mmap path.
- Refresh with change: allocates a complete replacement catalog and mapping.
- Reader series objects unnecessarily contain writer block buffers.

The embedded domain does not justify a fixed global maximum database size or series count. Dynamic allocation at open/control-plane reconstruction remains appropriate, but capacities should be derived from parsed footer/file facts, allocated once, and represented separately from data-plane state.

## Control plane and data plane target

Data plane:

- append/batched append against an existing series;
- point/range lookup against an immutable prepared snapshot;
- raw and Gorilla inner loops.

It should perform no heap allocation, footer parsing, name ownership changes, checksum repetition, header decoding, filesystem metadata syscall, or catalog mutation.

Control plane:

- create/open/recovery;
- series creation;
- block rollover/index capacity planning;
- checkpoint/footer construction and sync;
- reader refresh/snapshot replacement;
- initial block verification and corruption state transition;
- verify/inspect.

The central architectural investigation is whether open/refresh can produce a compact immutable `ReaderSnapshot` containing a series directory, hot timestamp search index, cold block descriptors, verified-byte ownership/lifetime, and a measured search strategy. Writer state should be a separate type rather than a reader/writer union disguised as one `Series`.

## Optimization budget and investigation order

1. **Safety and state ownership:** split reader/writer state; formalize unverified→verified immutable transitions tied to mapping generation and exact block identity.
2. **Reader memory:** remove 64 KiB writer buffers from every reader series and allocate catalog arrays from known footer counts.
3. **Timestamp mapping:** compare binary, interpolation-with-bounded-fallback, hint, and two-level layouts across dense, sparse, and irregular data. Any estimator must be correctness-neutral and bounded.
4. **Series directory:** move name resolution off repeated linear scans without adding data-plane allocation or mutable cache invalidation.
5. **Batched writer:** isolate validation/encoding loops and measure scalar versus vector forms.
6. **Range widths:** measure 1/10/100/1,000/10,000/cross-block/full-series before changing sequential traversal.
7. **Checkpoint bounds:** make delta versus snapshot cost explicit and assert footer-chain/snapshot relationships; v6 prevents making snapshot work independent of database size.
8. **Only then:** reconsider compact SoA indexes, prefetch, SIMD, or codec micro-operations based on profiles and assembly.

This model predicts the largest non-format opportunities are prepared timestamp mapping for point lookup, reader/writer state separation, and batch append control amortization. It predicts little honest upside in unchanged refresh or many-reader raw ranges because those paths are already at syscall and memory-bandwidth ceilings respectively.
