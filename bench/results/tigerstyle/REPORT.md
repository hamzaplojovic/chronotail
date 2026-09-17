# TigerStyle engineering report

## Scope and result

This pass audited Chronotail from the file format upward, in the required order: safety, performance, then developer experience. Format v6, C ABI v1, the public Zig/Python APIs, CLI behavior, checksums, recovery, snapshot semantics, and durability primitives are unchanged.

The primary architectural result is **prepared timestamp geometry**. Open, refresh, and first verification prepare proofs that let regular raw series select a block and record with exact arithmetic. Every estimate is bounded and guarded; irregular data retains binary search. The reader/writer catalog is now compile-time specialized, and query-hot immutable block metadata is separated from mutable verification state.

The final engine passes all build modes, deterministic simulation, release smoke tests, byte-for-byte v6 comparison, and the unchanged 225-measurement competitive suite.

## Mechanical model and ceilings

The machine model was written before engine changes in [`docs/performance/tigerstyle-machine-model.md`](../../../docs/performance/tigerstyle-machine-model.md). The host is an Apple M1 with 8 cores, 8 GiB unified memory, 16 KiB pages, 128-byte cache lines, APFS, and measured irregular/cache-line memory throughput of approximately 22.5–25.3 GiB/s.

Important consequences:

- A 16-byte logical record has a memory-traffic ceiling around 1.4–1.6 billion records/s before metadata, checks, copies, and stores.
- A 100-point raw query returns 1,600 logical bytes, placing the observed 8+ reader workload near the useful-memory-bandwidth ceiling.
- Warm point lookup is dependent-cache-latency and search bound, not bulk-bandwidth bound.
- Compressed decoding is serial dependency/CPU bound.
- Unchanged refresh is syscall bound and already close to its architectural minimum.
- Every 64th v6 checkpoint is a snapshot and therefore O(total catalog metadata); the other checkpoints are incremental.

Format-derived bounds are explicit: 4,093 raw records per block, 128 records per compressed chunk, at most 32 chunks per block, and at most 63 delta footers before a snapshot.

## Architecture

### State ownership

- `WriterSeries` and `ReaderSeries` are distinct compile-time types, both 96 bytes on the release target. The previous shared object was 65,624 bytes and forced readers to carry writer-only block buffers.
- Each writer block buffer has one stable allocation and owner; moving catalog entries never copies 64 KiB.
- `BlockIndex` is 40 bytes of immutable search metadata. `BlockVerification` is a parallel 24-byte cold array containing only cached bytes, the proven raw timestamp step, and a formal state.
- Verification states are `unverified`, `block`, and `compressed_structure`. Transitions have paired assertions.
- Refresh transfers cached verification only when the complete immutable block identity matches. Format v6's committed-prefix immutability makes this safe.
- A hash directory is prepared for catalogs above four series; tiny catalogs retain cheaper linear lookup. Assertions prove that directory hits still match the series name.

### Control and data planes

Existing-series appends and production mmap-reader queries allocate nothing. Series creation, open/recovery, refresh mmap replacement, checkpoint serialization, and first generic-backend verification are control-plane work. Catalog capacities are reserved from validated footer counts before parsing. The v6 footer chain uses a fixed 64-entry stack array rather than an unnecessary dynamic list.

### Timestamp strategy

1. Footer metadata is authenticated and used to detect constant full-block timestamp stride.
2. A guarded arithmetic estimate selects a block for regular layouts; malformed, partial, and irregular layouts fall back to binary search.
3. First raw-block verification checks checksum, header identity, exact min/max timestamps, and strict interior order in one pass.
4. If all timestamp deltas match, a checked 64-bit lower-bound calculation selects the record directly. Unit-step data uses subtraction only.
5. Irregular blocks retain binary search.

The initial 128-bit formulation emitted `__udivti3` on ARM64 and was removed. Current release assembly contains no `__udivti3` reference.

## Safety audit

### Improvements retained

- Raw payload timestamp order and header min/max are semantically validated after checksum verification.
- Footer entry counts, block counts, names, offsets, committed sizes, trailer candidates, chain regions, batch byte sizes, integer parsing, and serialization plans use checked arithmetic and file-derived bounds.
- Footer serialization is sized and reserved once before mutation.
- Trailer scanning rejects wrapping or impossible candidate regions before reads.
- Block parsing proves header and stored payload sizes before slicing.
- Refresh preserves verification only under exact identity and keeps block/verification array lengths paired.
- Compile-time assertions cover payload capacity, raw record capacity, checkpoint entry width, snapshot-counter width, compressed chunk bounds, and hot/cold metadata size ceilings.
- Runtime assertions flank append limits, block flushes, verification transitions, directory lookup, footer sizing, and parallel metadata arrays.
- New tests cover malicious checksummed-but-unordered raw timestamps, fixed-step boundaries and missing timestamps, truncated/corrupt tails, checked integer parsing, and refresh state.

### Remaining bounded risks

- Allocator failure is propagated throughout, but there is no exhaustive allocation-failure permutation test. Production query/steady append paths avoid allocation, limiting exposure.
- mmap and filesystem failures are propagated and simulator storage faults exercise short writes, failed writes, crashes, truncation, and corruption; macOS-specific mmap failure injection is not separately automated.
- The simulator's `runSeed` remains a 220-line centralized state machine. Splitting it would obscure operation ordering and fault-injection state, so it is an intentional exception rather than production hot code.

No checksums, validation, synchronization, or simulator invariants were weakened.

## Performance experiments

The complete retained/rejected ledger is in [`PERFORMANCE_LEDGER.md`](PERFORMANCE_LEDGER.md). Key focused results:

| Path | Pre-TigerStyle | Final | Change |
|---|---:|---:|---:|
| Dense one-point internal query | 3.55M/s | 18.99M/s | 5.35× |
| Raw 100-point internal query | 1.34M/s | 2.92M/s | 2.18× |
| Single-series append, paired loaded-host median | 12.49M/s | 14.09M/s | +12.8% |
| Eight-series append, paired median | 13.13M/s | 13.44M/s | +2.4% |
| 1-reader p50 under writer | 334 ns | 167 ns | 2.0× lower |
| 8-reader p99 under writer | 1,375 ns | 875 ns | 36% lower |
| 32-reader p99 under writer | 1,375 ns | 916 ns | 33% lower |

At 8 and 32 readers, faster readers consume more shared CPU/memory bandwidth and reduce observed writer throughput. In paired tests, 8-reader aggregate query throughput rose about 28% while writer throughput fell about 34%. This is a real scheduling/resource tradeoff, not hidden. No reader throttling or benchmark-specific production branch was introduced.

A dedicated scaling diagnostic confirms the memory ceiling:

| Readers | Aggregate queries/s | Writer records/s | Reader p99 |
|---:|---:|---:|---:|
| 1 | 2.80M | 11.00M | 833 ns |
| 2 | 3.64M | 7.74M | 1,125 ns |
| 4 | 5.90M | 6.43M | 1,125 ns |
| 8 | 6.74M | 6.26M | 1,083 ns |
| 16 | 8.20M | 3.25M | 1,083 ns |
| 32 | 8.65M | 2.38M | 1,000 ns |
| 64 | 8.46M | 1.41M | 1,041 ns |

Reader throughput plateaus at 16–64 readers near the 8.39M-query/s conservative machine ceiling. More reader threads after saturation transfer bandwidth from the writer rather than increasing aggregate reads.

Rejected changes include wide-division block estimation, forced varint inlining, removing formal block verification state, and an outlined warm verification helper. Each lost on measured throughput, code size, or safety.

## Unchanged competitive suite

Final run: [`bench/results/20260917-105244/`](../20260917-105244/)

- 225 measurements
- 45 engine/workload groups
- five repetitions each
- unchanged datasets, timing boundaries, durability definitions, competitor configuration, and validation
- raw SHA-256: `841c4121ac83500b5fe433a4c5e1123ee3139b828a195ec40b2490f99e4ee762`
- summary SHA-256: `057e35f229bd5514bbe2aca4e47aa157790527c22a1d758ead0eda9d5daf8193`

The final host was heavily loaded by unrelated Python test processes, OrbStack, the terminal, and UI processes. Absolute rates dropped across Chronotail, NanoTS, and SQLite, and variance was large. Therefore the final run is valid methodology evidence and a same-run competitor comparison, but **not a clean absolute before/after performance comparison** against the quieter `20260916-213249` run. Alternating same-host A/B diagnostics above isolate the code change more reliably.

Final same-run highlights:

- Chronotail point lookup: 1.88M/s, 2.14× NanoTS and 8.96× SQLite.
- Raw 100-point range: 1.23M/s, 23.32× NanoTS and 27.47× SQLite.
- 32-reader aggregate: 8.34M queries/s, 189.85× NanoTS and 37.31× SQLite.
- Chronotail loses 32-reader writer throughput to NanoTS: 1.33M/s versus 2.47M/s, while serving 190× NanoTS's reader query rate.
- Raw storage remains 16.02 bytes/point. Compressed smooth and random data use 7.18 and 10.78 bytes/point, respectively.

The full tables, latency distributions, methodology, durability caveat, and dependency-free charts are in [`BENCHMARKS.md`](../../../BENCHMARKS.md).

## Correctness and compatibility evidence

- Debug, ReleaseSafe, and ReleaseFast tests: pass.
- Final simulator: 1,000 seeds, 100,000,000 operations, 916 crashes, 815 short writes, 794 failed writes, 5,989 truncations, 5,961 corruptions, 59,114 checkpoint/reopen cycles, zero invariant failures.
- Deterministic compressed v6 output SHA-256 remains `5d9d52316916e250bab7ee474242776a223797f5ce9d5bf3f76f982fe94dc475`.
- C ABI v1 exports exactly the nine expected `ct_*` symbols.
- Artifact-only CLI, verify, inspect, Python wheel, compressed batch append, and Python reader smoke tests pass.
- Final archive SHA-256: `0b60e1d5ab9139aeda9da6424811b51c7b4912afe6ff25cc9dd2cd59a352e393`.

## Code quality and dependency audit

- Zero project Zig lines exceed 100 characters after formatting.
- Production methods remain below the approximate 70-line target. The two reported long engine functions are compile-time type factories containing methods, not individual functions.
- The 71-line standalone benchmark driver is non-production; the simulator state-machine exception is documented above.
- Persistent integer domains remain explicit (`u8/u16/u32/u64/i64`). `usize` is used for in-memory indexes and slice lengths, with checked conversion at persistent boundaries.
- There is no runtime storage dispatch in production and no third-party runtime dependency.
- Comments document ownership, proof obligations, format reasons, fallback behavior, and non-obvious tradeoffs rather than narrating syntax.

## Remaining bottlenecks

1. Compressed Gorilla decode remains a serial dependency chain and is the clearest CPU optimization target.
2. Many-reader raw ranges are at the machine's useful memory-bandwidth ceiling; reducing bytes touched matters more than additional instruction tricks.
3. Dense point lookup still performs mmap/header/verification-state work around the now-cheap arithmetic selection.
4. Snapshot checkpoints remain necessarily O(total metadata) every 64th checkpoint under frozen format v6.
5. High-reader-count writers compete with much faster readers for finite cores and memory bandwidth.
6. Reliable cold-cache testing and hardware instruction/cache counters remain unavailable without privileged cache purge and full Xcode/Instruments.

Further optimization should target compressed dependency removal, metadata bytes touched, or explicit API-level scheduling policy—not add generic layers or benchmark-specific branches.
