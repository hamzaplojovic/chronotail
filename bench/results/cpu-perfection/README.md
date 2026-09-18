# CPU-perfection experiment ledger

Experiments on `perf/cpu-perfection` use format v7 and C ABI v2. Retired
instructions per public logical operation are primary; generated ARM64 body
size and repeated ReleaseFast timings are local proxies where CPU counters are
unavailable. Correctness gates and persistent bytes are non-negotiable.

## Rejected: writer-only ordered page encoding and bounded clearing

The candidate gave `flushSeries` an encoder entry point that skipped the page
ordering scan already performed by `appendBatch`, and replaced the apparent
64 KiB page-buffer clear with clearing only the header and alignment padding.
Debug, ReleaseSafe, ReleaseFast, and deterministic simulator gates passed.

The optimized production result was unchanged. In both `origin/main` at
`07234b5` and the candidate, ARM64 `flushSeries` occupied `0x5ec` bytes
(`0x100002484..0x100002a70`), contained 379 instructions, and its disassembly
was byte-for-byte identical. LLVM had already removed the redundant scan and
dead stores after inlining. A sequential five-pass timing comparison was
discarded because system-wide unrelated slowdowns showed thermal bias. The
candidate was rejected because it added an internal API and proof obligation
without removing production work.

A later follow-up covered the new direct-full-page append path as well. Moving
the encoder body behind a compile-time `ordered` helper regressed common batch
rows 20% to 63%; forcing the helper inline still left most raw rows 4.6% to
7.9% slower and most compressed rows 7.9% to 17.1% slower. Although one
compressed pattern row improved 28.3%, the wrapper disrupted more profitable
whole-function optimization. The follow-up was also reverted.

## Retained: carry the new root summary out of index append

`index.append` already constructs an `Entry` containing the new root pointer and
its exact aggregate summary. It now returns that entry. The checkpoint path no
longer rereads the root it just wrote, hashes it with BLAKE3, decodes every
entry, and recomputes its summary. This removes one `pread`, one file-size query,
one checksum, and one full node validation per modified series per checkpoint;
readers still authenticate the object normally.

Five alternating quick matrices measured unsynced checkpoint throughput gains
of 58.2% raw and 37.7% compressed. Fsync figures were noisy because device
synchronization dominates them. All stored sizes remained unchanged. The
matrix's inherited v6-era `snapshot-only`/`delta-only` cadence split was found
to be meaningless for v7 and removed rather than cited as evidence.

## Retained: exact-range search and active verified page

Strict ordering means an exact range needs one lower-bound result and one
equality check, not a second search/decoder loop. Production mmap readers now also
retain the last authenticated page view per series. Reuse compares the complete
persistent pointer and is valid only for the immutable mapped snapshot;
`refresh` replaces the runtime array, while generic/simulator storage continues
to authenticate every access.

Across five alternating quick matrices, prepared raw point-query medians rose
13.0% to 58.8% over 1, 4, 8, 64, and 256 series. The broader point matrix rose
16.2% to 161.8% depending on encoding and data pattern. The cache also benefits
sequential wider ranges that remain on one page. These timings include both the
one-search and verified-page changes; their machine-level work removals are
separate and mechanically bounded.

## Retained: restart-aware delta timestamp search

The old lower bound performed binary search over logical points, but every
probe reconstructed a delta timestamp from its restart anchor. The new search
binary-searches the encoded group anchors, then decodes at most one 128-point
group in order. Five alternating quick matrices measured irregular compressed
query gains of 103.9% at width 1, 116.1% at width 10, 58.4% at width 100, and
21.1% at width 1,000. Full scans were effectively unchanged because their cost
is record decoding, not the initial seek.

## Retained: reuse decoded count-boundary timestamps

Delta lower-bound already decodes the winning restart group and knows its
matched timestamp. `countRange` used to discard that value and reconstruct the
same group with `timestampAt` solely to decide whether the inclusive end exists.
Its internal bound result now carries the decoded timestamp, removing the
second group replay at both exact and upper boundaries. Focused five-run
irregular-compressed count medians improved about 3% to 10% across adjacent
runs. Applying the same result object inside the copy kernel was tested and
reverted because wider compressed ranges showed a repeatable code-layout cost;
the retained change is isolated to count-only work.

## Rejected: mapped fixed-window traversal and incremental buckets

The candidate replaced production `index.Node` traversal with mmap views and
replaced per-point bucket division with boundary tracking plus rare division on
large gaps. Five baseline-first runs measured raw +1.6% but compressed -8.0%.
Five candidate-first runs measured raw -5.1% and compressed -0.6%. The added
branches and hot code did not repay the removed work in the current window
workload, so the simpler original kernel was restored.

## Rejected: persist page decoders in the Zig cursor

The candidate retained timestamp and value decoder state across bounded cursor
calls, avoiding restart-group replay when a chunk ends within a compressed
group. The public benchmark matrix was extended to cover both codecs at 16,
128, 1,024, and 4,096-point capacities, plus a read-API-only mode so unrelated
phases do not perturb the measurement.

In an adjacent five-run ReleaseFast A/B, the candidate improved compressed
16-point chunks by 48.7%, but regressed compressed capacities of 128 or more by
13.6% to 25.8%. Raw cursor throughput fell 3.7% at capacity 16 and 21.3% to
25.2% at larger capacities. Keeping large optional decoder objects in the
cursor made the common register-local loop worse. The implementation was
reverted; a future small-compressed-chunk specialization must isolate that win
without taxing raw or naturally restart-aligned chunks.

## Rejected: manually increment base-step timestamp cursors

The candidate replaced `base + step * index` in the regular-timestamp cursor
with one initial seek followed by an explicit addition per point. Two focused
five-run query passes around a five-run baseline were mixed: dense range cells
spanned roughly -6.6% to +39.5%, with reversals between otherwise equivalent
patterns and widths. LLVM can strength-reduce the indexed loop already; making
the induction state explicit changed surrounding code generation without a
uniformly lower-cost result. The candidate was reverted instead of retaining a
source-level optimization that was not a reliable machine-code optimization.

## Rejected: special-case unit timestamp steps

Dense pages have `timestamp_step == 1`, so the candidate bypassed quotient and
remainder calculation in `lowerBound`. An initial five-run comparison looked
strong, but a second baseline run immediately after the candidate disproved
that attribution. Against the adjacent baseline, dense range medians ranged
from -4.9% to +5.3%, while count-only rows stayed within about +/-1%. The extra
branch trades against division latency that is already hidden by the rest of
these kernels. The branch-free general formula was restored.

## Rejected: duplicate trusted index-entry decoder

Mapped index nodes are fully authenticated before entering the verification
cache, so the candidate added an infallible entry decoder that skipped enum and
reserved-byte checks on every later `entryAt`. In five focused public query
runs against an adjacent five-run baseline, most medians remained within about
+/-3%, with contradictory larger outliers in both directions. Index traversal
touches too few entries for the duplicate decoder to repay its second parsing
path, and the existing `catch unreachable` already makes malformed cached data
a cold path after authentication. The candidate was removed.

## Retained: compile-time range sinks

The range engine previously carried nullable file, buffer, and profile sinks
through one large runtime kernel even though public calls select exactly one
mode. It now instantiates count, caller-buffer, file-stream, and profiling
variants at compile time. Each hot loop contains only its applicable output and
timing work; validation and traversal remain shared source.

Two consecutive five-run ReleaseFast candidate passes were stable. Relative to
the adjacent five-run baseline, count-only throughput improved 2.1% for the
irregular compressed case, 6.6% to 9.1% for the other compressed cases, and
10.0% to 14.0% for raw cases. Many bounded-copy range cells improved 6% to 11%;
the few negative full-range cells were within the run-to-run noise seen between
identical candidate passes. The installed C-library text grew only 336 bytes
(249,824 to 250,160 bytes, +0.13%), keeping the specialization well below an
I-cache-sized expansion.

## Retained: zero-capacity reads use the count kernel

`rangePreparedInto` with empty buffers is the C ABI's exact-size query and the
first pass used by Go `Range`, but it previously selected the copy kernel. That
prevented fully covered pages from using index point counts and forced every
page to be opened. Empty buffers now route directly to the compile-time count
variant; non-empty truncating-copy semantics are unchanged.

Five-run public API medians for a 100,000-point full-range size query improved
from about 1.01 million to 8.64 million operations/second raw (8.5x), and from
0.299 million to 8.89 million operations/second compressed (29.7x).

## Retained: fuse compression with value statistics

Compressed page construction previously walked every value once to encode it
and again to calculate min, max, and sum. The compression pass now accumulates
those exact-order statistics while each value is already hot. If compression
falls back, it reports the observed prefix and statistics continue from that
index, so no value is classified twice. The raw-codec path remains the original
implementation.

Five-run ReleaseFast append medians improved 2.3% to 13.1% across every
compressed batch size. The pattern matrix improved 3.7% to 45.2% for all dense
value patterns, 0.8% to 24.2% for irregular patterns, and 0.0% to 30.2% for
sparse patterns. Raw batch rows remained within ordinary run noise. Direct page
tests and the whole-file raw/compressed format-v7 golden hashes remain exact,
confirming identical statistics and bytes.

## Retained: fuse compressed-value validation with statistics

First-touch authentication previously parsed every XOR varint to validate the
restart stream, then decoded the complete value stream again to verify first,
last, min, max, and sum. Structural validation now reconstructs each value as
it consumes the already-bounded varint and accumulates the exact same ordered
statistics. Raw values retain their original validation scan.

Five-run first-touch profile medians fell 4.1% for compressed random values,
16.2% to 20.5% for compressed smooth values, and 30.5% for compressed spiky
values. Raw cases stayed within +/-2.9% noise. A forged-checksum corruption test
confirms that altered compressed statistics are still rejected, and all direct
page and format-v7 golden tests pass.

## Retained: single-pass index decode fold

Index decode previously validated entry ordering in its decode loop, stored all
entries, then called `summarize`, which walked the entries and checked ordering
again. Decode and encode now share one `extendSummary` operation, and decode
folds the authenticated summary during its existing entry pass. This removes a
complete entry-array traversal and one duplicate ordering comparison per entry.

The effect is deliberately small because a node has at most a few dozen
entries: five-run first-touch medians improved 0% to 6.1% for compressed cases
and were within -3.1% to +2.8% noise for raw cases. The change is retained on
the mechanical operation-count reduction and simpler single-source invariant;
all direct index corruption and persistent-append tests pass.

## Retained: encoder-derived index summaries

`writeLevel` used to summarize each child group, assign that result to a node,
then call `index.encode`, which summarized the same entries again to validate
the supplied field. The encoder now derives and stores the node summary itself,
so an inconsistent caller-supplied summary is no longer an internal state and
each written node has one summary fold. Five-run unsynced checkpoint medians
were effectively neutral (about -3.2% to +2.1% depending on metric/codec), but
the exact duplicate traversal is mechanically removed and the API is simpler.

## Retained: stack-backed persistent-index scratch

Persistent-index append used the general allocator for several short-lived
entry lists on every checkpoint. It now uses an 8 KiB stack-backed allocator
with the caller's allocator as transparent fallback, so ordinary right-spine
updates allocate no heap scratch while arbitrarily large checkpoints retain
the same behavior.

Across five ReleaseFast checkpoint runs, unsynced throughput improved 4.7% raw
and 8.3% compressed. Median p50 latency fell about 14% for both codecs. Direct
multi-level persistent-index tests pass, including the fallback-capable code
path's existing size/error bounds.

## Retained: contiguous manifest name ownership

Manifest decode previously allocated and copied every series name separately,
then readers inherited those individually owned strings. Decoding now derives
the exact aggregate name bytes from the authenticated manifest geometry,
allocates one slab, and places every name slice in it. Reader open and refresh
transfer the slab alongside the series array and free both as single owned
objects. Writer open still duplicates names into its long-lived writer state,
but its temporary decoded manifest also uses the slab.

The public control-plane matrix now includes a 1,024-series open case. Across
five repetitions, median p50 reader-open latency fell from about 1.58 ms to
0.331 ms: 4.8x faster, or 79% lower. The manifest portion also removes 1,023
allocator calls for that dataset. Direct manifest round-trip and mapped refresh
tests pass under the testing allocator.

## Retained: contiguous reopened-writer buffers

Appender reopen previously made two full-page buffer allocations and one name
copy for every existing series. Existing series now borrow slices from two
contiguous timestamp/value slabs and the transferred manifest name slab; the
appender owns those three allocations. Per-series ownership flags keep newly
created series independent. This preserves the existing guarantee that an
append to any reopened series has its page buffers preallocated.

The new 1,024-series public appender-open benchmark improved median p50 latency
from about 2.13 ms to 0.310 ms: 6.9x faster, or 85.5% lower. It also replaces
2,048 buffer allocations and 1,024 name allocations with three total slab
allocations for that dataset. Reopen, append, checkpoint, and range round-trip
tests pass.

## Retained: single-probe series-directory construction

Reader open used `contains` followed by `putAssumeCapacityNoClobber`, hashing
and probing every manifest name twice to reject duplicates. It now uses the
hash map's found-or-inserted result, preserving duplicate detection and setting
the new value after one probe sequence. Five-run 1,024-series reader-open p50
medians improved from about 0.332 ms to 0.321 ms (3.2%).

## Retained: root and subtree summary counting

Count-only traversal now consumes a fully covered index entry before descending
into its child, so large ranges visit boundary paths rather than every covered
node. A range covering the complete series returns the authenticated root
summary directly. The same subtree skip activates for bounded-copy calls after
the caller buffer is full, preserving the exact required count without opening
or decoding covered pages.

The public 100,000-point full-range size query now sustains roughly 133–141
million calls/second for both codecs, about 25x above the immediately preceding
implementation and more than 100x above the original raw path. The asymptotic
subtree win becomes larger once an index exceeds one leaf node.

## Rejected: broad mapped-page view cache

A 64-entry, four-way cache of authenticated mapped page views improved random
exact-point rows, but charging its probe to every page regressed several wider
range cells by as much as 15% in the reverse bracket. A point-only specialization
was also rejected after system performance shifted enough to invalidate the
comparison. The branch retains the simple active-page cache; a future point
cache must be isolated without taxing range code.

## Retained: buffered text range output

Text export formerly called `writeAll` once per point. A fixed 64 KiB sink now
formats into bounded stack storage and flushes whole segments, preserving exact
bytes and allocation-free operation while reducing 100,000 output syscalls to
roughly the number of 64 KiB chunks. With the same formatter, median throughput
rose from 0.60–0.61 million to 12.67–12.87 million points/second, about 21x.

The new benchmark also exposed that the previous 128-byte line buffer rejected
valid subnormal `f64` values: exact decimal formatting can exceed one thousand
characters. The line bound is now 2 KiB and an exact-output regression test
covers the minimum positive subnormal value.

## Retained: exact-full-page direct append

An exact `records_per_block` batch used to miss the direct-page path because its
condition was strictly greater than one page. Changing it to greater-than-or-
equal removes two 32,704-byte staging copies and the delayed flush for an
already validated full page. The append matrix now includes this exact boundary.

## Retained: single-pass successful refresh and publication safety

Successful refresh previously read and authenticated the 64 KiB control region
twice. It now reuses the first decoded root-candidate set for snapshot loading,
removing one pread, header scan, and four root checks per adopted generation.

The audit also found a publication race: a reader opened after immutable tail
objects were appended but before the root-slot overwrite could record the final
physical size with the old generation, then incorrectly skip every same-size
refresh. The size fast path now applies only when observed and committed sizes
match. A deterministic old-control/new-control interleaving test preserves the
fix.

## Rejected: vectored raw-page serialization

The candidate built only the 128-byte raw header, streamed BLAKE3 over the
header and caller columns, and issued one three-vector `pwritev`, eliminating
both column copies while preserving byte-identical format-v7 golden files.
On macOS ARM64 the vectored path nevertheless regressed 12 of 13 raw append
cells by 2.1% to 9.9%; only the nearby 4,096 batch cell improved 2.3%.
The contiguous encoder and ordinary `pwrite` were restored.

## Retained: transactional writer right-spine cache

Every dirty checkpoint used to reread, BLAKE3-authenticate, decode, and validate
the committed index right spine even when the exclusive appender had created
that exact immutable spine during the previous checkpoint. Index append now
returns the newly written spine alongside its root. The appender adopts it only
inside a checkpoint that will either publish successfully or poison the writer;
reopened appenders authenticate once on their first modification.

Cache reuse is compiled only for production `std.fs.File`. Generic storage and
the deterministic simulator continue authenticating every access because their
bytes may deliberately mutate between reads. Readers and reopened writers still
authenticate persistent objects normally, so checksum and recovery boundaries
are unchanged.

Two consecutive five-run ReleaseFast candidates were stable within 2% for
unsynced work. Relative to the adjacent baseline, checkpoint throughput rose
about 109% compressed and 134% raw; median latency fell about 49% and p95 fell
about 69%. The retained mechanical reduction is one pread, checksum, and full
node decode per right-spine level per modified series and checkpoint.

## Retained: single-pass delta endpoint validation

Authenticated delta timestamp validation already reconstructs the complete
stream and verifies its final timestamp, but decode then replayed both the first
and final restart groups to compare header endpoints. The validation fold now
checks the first anchor against `timestamp_min` and remains responsible for the
already-computed maximum. The redundant endpoint decodes are removed. Trusted
`decodeKnown` is used only for bytes previously authenticated in an immutable
production mapping; generic storage continues using full authentication.

## Retained: known-size writer manifest encoding

The appender previously revalidated every series name, root kind, summary, and
ID ordering and recomputed the manifest byte size on every checkpoint, even
though those invariants are established when series enter writer state. It now
maintains the exact encoded size as series are created and calls a narrow
known-size encoder after assembling the candidate manifest. Public decode and
the general manifest encoder retain full validation.

At 1,024 series with one modified series, five-run p50 checkpoint latency moved
from 236.96 us to 235.79 us (0.5%). The timing is dominated by encoding,
checksum, and writing the mandatory full format-v7 manifest, but one complete
validation/size pass and its branches are mechanically removed.

## Retained: additive stateful C cursor

The ABI-v2 value cursor has seven bytes explicitly reserved as zero, so it
cannot carry native tree frames, page views, and decoder position without
breaking its layout contract. Each Go chunk therefore reconstructed a Zig
cursor from `{series,next_timestamp,end}` and restarted traversal. ABI v2 now
adds an opaque cursor-state create/next/destroy surface while preserving every
existing symbol and structure. Go uses the opaque path, releases it
automatically at completion, and exposes idempotent `Cursor.Close` for abandoned
iteration; the original C value cursor remains unchanged.

Three one-second public Go benchmark runs were stable. Median full-range latency
fell 34.8%, 15.6%, and 3.6% for raw capacities 16, 128, and 1,024. Compressed
latency fell 20.2%, 9.5%, and 2.1% at the same capacities. The smallest chunks
benefit most because they previously discarded the most traversal/decoder state.

## Retained: explicit dirty-series checkpoint set

Checkpoint used to scan every writer series once to discover non-empty page
buffers, then scan all series again to assemble the mandatory format-v7
manifest, and finally scan all series a third time to adopt candidate roots.
Append now records each series on a preallocated dirty list exactly once. Flush
and post-publication adoption visit only that list; the one unavoidable manifest
scan remains. Existing reopened-series capacity keeps ordinary append
allocation-free.

With one dirty series among 1,024, five-run p50 checkpoint latency fell 4.1%
(235.79 us to 226.08 us) and p95 fell 8.3%. The ordinary one-series checkpoint
matrix remained neutral to positive: throughput moved +0.6% raw and +1.4%
compressed, with p50 slightly lower for both.

## Retained: direct writer-to-manifest encoding

Checkpoint also copied every writer series into a temporary 120-byte
`manifest.Series` array before immediately reading that array to encode the
manifest. A compile-time iterator now presents resolved candidate/current roots
directly from writer state to the shared encoder. This removes the scratch
allocation, one full structure-copy pass, and 120 bytes of transient traffic per
series while keeping the general validated slice encoder unchanged.

At 1,024 series, p50 for the one-dirty-series checkpoint fell another 2.2%
(226.08 us to 221.08 us); p95 was within 0.4% noise. One-series raw and
compressed checkpoint throughput remained within 0.4% of the preceding build.

## Retained: direct index-entry encoding

Index construction formerly copied every entry group into a roughly 4 KiB
`Node`, then immediately walked that copy to summarize and serialize it. The
shared encoder now accepts the entry slice directly. Only the final group at
each level is copied once because it becomes the appender's retained right
spine; all other intermediate node copies disappear, with identical format-v7
bytes and the same validation.

Five-run unsynced checkpoint medians improved 1.2% raw and 3.8% compressed.
Median p50 latency fell 0.5% raw and 1.2% compressed. The improvement is modest,
but the removed memory traffic scales with the number of index nodes and the
new data flow is simpler.

## Retained: direct interleaved point materialization

Go `Range` formerly allocated timestamp and value columns, asked the C API to
fill both, allocated the final `[]Point`, then walked all results again to
interleave them. ABI v2 now adds `ct_range_points` and its prepared equivalent;
the shared compile-time range traversal writes directly into the caller's
interleaved point slice. Existing column APIs and their truncation behavior are
unchanged, and the C/Go/Zig layouts are asserted to be 16 bytes with timestamp
at offset zero and value at offset eight.

Across five public Go benchmark runs over 100,000-point full ranges, raw median
latency fell from 195.08 us to 86.84 us (55.5%) and compressed median latency
fell from 743.38 us to 558.54 us (24.9%). Per-operation allocation fell from
about 3.21 MB in five allocations to 1.61 MB in three allocations. Direct
raw/compressed truncation tests preserve the required-count contract.

## Rejected: use interleaved points in the Python client

Python's ctypes layer was tested on the same direct `ct_point` API. Unlike Go,
extracting fields from each ctypes structure is expensive: 100,000-point range
medians rose from about 10.1 ms to 23.1 ms raw and from 10.5 ms to 23.5 ms
compressed, roughly a 2.2x regression. Python therefore keeps separate primitive
ctypes columns and constructs tuples from those arrays; the interleaved native
API remains available to languages with zero-cost compatible structures.

## Retained: coalesced production page writes

Large append batches formerly encoded and wrote every full page independently,
paying one `pwrite` and one checksum-to-write transition per page. The production
file appender now encodes up to four adjacent pages into one reusable 256 KiB
scratch segment and writes the exact aligned byte sequence once. Scratch is
allocated by `prepareSeries` for prepared multi-page appends, preserving the
allocation-free data path. Generic storage and the simulator retain per-page
writes so fault injection granularity and invariants are unchanged.

Five-run 65,536-point batch medians improved 14.2% raw (31.67M to 36.16M
points/s) and 9.1% compressed (65.59M to 71.53M points/s). The twelve 500,000-
point compressed pattern rows improved 5.3% to 16.1%. Two consecutive candidate
runs were stable, and format-v7 golden hashes remain byte-identical.

## Retained: one ownership slab for new writer series

Creating a new series allocated its name, timestamp staging column, and value
staging column independently even though all three live until the appender is
destroyed. One aligned `u64` slab now owns the name prefix and both columns.
This reduces persistent writer-series allocator traffic from three calls and
three frees to one call and one free, removes separate buffer/name ownership
flags, and keeps both columns naturally aligned. Reopened writers continue to
borrow their already-contiguous catalog and column slabs. The control-plane
matrix stayed neutral, while the prepared append allocation test remains at
zero allocations after `prepareSeries`.

## Retained: exact-capacity in-place writer spine update

Index append originally returned its new right spine through an eight-node
temporary and the writer copied each roughly 8 KiB node into persistent cache
storage. A first in-place prototype reserved all eight nodes per touched series
and was rejected because it could retain about 64 MiB across 1,024 series. The
retained version computes the exact resulting depth from the authenticated old
spine and pending-entry count, grows only to that depth, and safely overwrites
the allocation after its old entries have been consumed.

Across two five-run candidates, unsynced checkpoint p50 fell about 2.0–2.7%
compressed and 3.2–3.7% raw. Overall throughput was within run noise. The first
checkpoint after reopen still uses the temporary while it authenticates the
spine; later checkpoints remove the full-node copy without excess retained
memory.

## Rejected: reader last-series name cache

Mirroring the writer's last-series shortcut avoided hashing repeated named
queries and improved the one-series lookup row about 8.1%. The extra branch and
name comparison regressed random 8-series lookups about 6.2% and 64-series
lookups about 18.0%; other rows were mixed. Since prepared handles already
remove name lookup for repeated data-plane work, the reader cache was removed
instead of shifting cost onto multi-series workloads.

## Retained: write the cached right spine directly in place

The exact-capacity spine path still assembled every new node in a second
`[height_max]Node` stack array and copied each roughly 8 KiB node into its
persistent cache slot. Once the final depth is known, each bottom-up level can
write directly into its final reversed-depth slot: the old leaf has already
been copied into entry scratch, and each old parent is consumed before its slot
can be reused. Uncached and generic-storage calls keep the independent output
path.

Against the preceding exact-capacity implementation over five runs, unsynced
checkpoint p50 fell from 30.42 us to 30.13 us raw (1.0%) and from 29.92 us to
29.46 us compressed (1.5%). Aggregate throughput was neutral (+0.3% compressed,
-0.04% raw). The retained form removes a full-node copy and the associated hot
stack traffic while also simplifying ownership of the final spine.

## Correctness hardening discovered during optimization

Prepared-but-unpublished series are now excluded from manifests until their
first append, while catalog-size accounting still bounds their eventual
publication. Dirty-list capacity is reserved against total prepared series,
so making every prepared series dirty before one checkpoint remains
allocation-free and cannot overrun capacity. A 128-series regression exercises
that invariant.

Stateful C cursors now bind to both their reader address and a monotonically
unique handle token. This prevents allocator address reuse after `ct_close`
from making a cursor accept a different reader and dereference views from an
unmapped snapshot. Cached index-spine validation also rejects oversized counts
and impossible levels before indexing fixed arrays.

## Rejected: split cached and uncached spine implementations

A compile-time mode plus a no-inline uncached helper reduced the generated
production checkpoint stack frame from 121,664 bytes to about 49,520 bytes.
That code-shape change prevented profitable whole-path optimization, however:
five-run unsynced throughput regressed 17.9% raw and 32.5% compressed, with p50
rising from 30.13 us to 33.75 us raw and from 29.46 us to 34.71 us compressed.
The split was removed. CPU work remains the primary metric; the large virtual
stack reservation costs only two stack-pointer instructions and does not touch
every reserved page.
