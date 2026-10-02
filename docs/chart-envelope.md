# Bounded chart envelope proposal

CT-006 proposal v2, frozen for manager review after the observed-adjacency
correction. This is a design for a future
additive Zig API, not an implemented capability. It changes no persistent format,
C ABI, timestamp units, existing query behavior, or supported-platform claim.
Implementation requires a separate authorized task after contract review.

An envelope keeps a bucket's original first, numeric minimum, numeric maximum,
and last samples. It retains their timestamps and binary64 bits. It does not
average, interpolate, synthesize boundary points, or preserve every event between
those selected samples. Raw history remains the exact source of truth.

## Proposed caller-owned API

Names and field syntax below are proposals for manager review:

```zig
pub const ChartBucketBounds = struct { start: i64, end: i64 };
pub const ChartSample = struct {
    point: Point,
    roles: ChartRoles, // first, minimum, maximum, last; flags may be combined
    break_before: ChartBreaks, // query_start, empty_bucket, excluded_interval,
                            // time_gap, nan; flags may be combined
};
pub const ChartBucket = struct {
    stored_count: u64,
    numeric_count: u64, // all non-NaN samples, including infinities
    sample_count: u8,  // 0 through 4
    samples: [4]ChartSample,
    has_nan: bool,
    has_internal_time_gap: bool,
};
pub const ChartProgress = struct {
    required_buckets: usize,
    written_buckets: usize,
    complete: bool,
};

reader.envelopeInto(name, bounds: []const ChartBucketBounds,
    max_gap: ?u64, output: []ChartBucket) !ChartProgress
reader.envelopePreparedInto(handle: SeriesHandle, bounds: []const ChartBucketBounds,
    max_gap: ?u64, output: []ChartBucket) !ChartProgress
```

The query allocates nothing after reader open. Bounds and output are caller-owned,
must not alias, and stay unchanged by other code during the call. Returned points
are copied and remain usable after reader refresh or close. A prepared handle
belongs to its snapshot; changed refresh invalidates it. Named/prepared calls
must agree. Unknown names and stale handles retain existing errors, including
empty requests and insufficient output capacity. Reader concurrency is unchanged.

## Bucket geometry and timestamp units

Each bucket is an inclusive interval `[start, end]` with `start <= end`. Bounds
are strictly ordered and disjoint: `bounds[i].end < bounds[i + 1].start`. Adjacent
integer intervals are allowed. Overlapping, reversed, or out-of-order intervals
are `InvalidArguments`; an empty bounds slice is a valid zero-bucket request.
Missing timestamps within a valid interval produce an empty data bucket.

Timestamps and distances use the caller's existing integer timestamp units and
epoch; no automatic milliseconds, floating conversion, or unit metadata is added.
Both `minInt(i64)` and `maxInt(i64)` are valid endpoints. Differences widen to
`i128` before subtraction. No i64 `end + 1`, `start - 1`, absolute value, or signed
subtraction is permitted at an extreme. The full-domain distance is
`maxInt(u64)` and inclusive tick length is `2**64`, represented in `u128`.

The caller can construct exactly B balanced buckets for an inclusive viewport
`[a, z]`. Let `N = u128(i128(z) - i128(a)) + 1` and require `1 <= B <= N`.
For `i = 0..B-1`, compute in widened checked arithmetic:

```
lo = i128(a) + floor(u128(i) * N / B)
hi = i128(a) + floor(u128(i + 1) * N / B) - 1
```

Cast the resulting endpoints to i64 only after deriving them. On current
64-bit caller index domains the products fit u128; implementations must use
checked multiplication rather than assume a platform width. The result covers
the viewport exactly, without overlap, including both extremes. More requested
buckets than integer ticks are rejected or explicitly clamped by the caller;
no repeated edges or fabricated samples are created. This convenience geometry
is not a new production helper in CT-006.

## Stored sample selection and exact values

For the samples whose timestamps lie inside one bucket:

1. First and last are the smallest and greatest stored timestamp.
2. Minimum and maximum consider every non-NaN value, including infinities.
   Equal numeric extrema choose the earliest stored timestamp. Positive and
   negative zero compare numerically equal; an earliest zero retains its own
   sign bit. Selection must never use aggregate sum or arithmetic on values.
3. Deduplicate selected roles by timestamp, combining their role flags on the
   same stored point. A series has strictly unique timestamps. Sort the remaining
   points by timestamp, irrespective of whether minimum occurs before maximum.
4. Copy the chosen timestamp and exact stored binary64 bits. Never replace a
   chosen zero/NaN with a canonical representation or reconstruct a point from
   an aggregate value without establishing its original sample identity.

A single numeric sample has all four roles. A constant bucket chooses its first
sample for both extrema and its last for the endpoint. A single NaN sample has
first/last roles and no extrema. An all-NaN bucket retains original first/last
samples with `stored_count > 0`, `numeric_count == 0`, and `has_nan == true`.
Unused sample slots are unspecified and must not be read; only `sample_count`
slots belong to the result.

NaNs are classified from stored bits without modifying those bits. Their sign,
payload, and signaling/quiet representation remain intact in selected samples.
They do not enter numeric comparisons. Infinities participate in extrema and
remain infinities; callers choose rendering/clipping policy. No finite substitute
or invented average is produced. Existing aggregate numerical behavior is not
changed by this selection contract.

An empty bucket has zero stored/numeric/sample counts, false value/time-gap
flags, and no point. It is distinct from a numeric zero sample and from an
all-NaN bucket. Every input bucket has one result slot, even when empty.

## Explicit discontinuities in reduced output

The first emitted point of a query carries `query_start`, plus `nan` if that
point is NaN. Leading empty buckets or excluded coverage do not describe a
connection to a nonexistent preceding point. For every later emitted point,
`break_before` is the union of the following events between it and the previous
emitted point, evaluated against the original samples in queried coverage:

- `empty_bucket`: at least one requested data bucket between them was empty.
- `excluded_interval`: the bounds leave an unqueried time interval between them.
  This means omitted coverage, not proof that the omitted history is empty.
- `time_gap`: with `max_gap != null`, at least one consecutive original sample
  pair in **continuous queried coverage** crosses more than `max_gap` integer
  units. Distance is widened and unsigned; equality is accepted, and zero marks
  every proven strictly increasing sample pair. Adjacency resets at every
  excluded interval; samples on opposite sides cannot establish a time gap.
- `nan`: an observed original sample in that connection, including either
  endpoint, has a NaN value. No claim is made about NaNs in omitted history.

Continuous queried coverage comprises adjacent integer bucket bounds:
`i128(next.start) == i128(previous.end) + 1`. Across contiguous bounds, including
any number of empty buckets, all intervening history was queried. Consecutive
observed samples are therefore consecutive original samples, and their true
pairwise gap is eligible for `time_gap`. Across noncontiguous bounds, set
`excluded_interval` and reset cross-interval adjacency even if the surrounding
observed timestamps are far apart. For example, samples at 0, 5, and 10 with
requested buckets `[0,0]` and `[10,10]` and `max_gap=6` emit an
`excluded_interval` break at 10, without `time_gap`: omitted sample 5 bridges
the two original gaps. The same flag rule holds if omitted coverage happens
to contain no samples; the API did not query it and cannot prove adjacency.

`max_gap == null` makes no sample-age claim and sets no `time_gap` event. Empty
buckets and excluded coverage still break connections. `has_internal_time_gap`
reports whether the threshold was exceeded between consecutive original points
within that one bucket. `has_nan` also reports NaNs omitted by sample reduction.
Metadata must describe all original samples, not only the four chosen points.
Time-gap and NaN events in a reduced connection include pairs/samples omitted
by reduction inside queried buckets. They never inspect unqueried history.

Flags mean a line must not be drawn across that reduced connection. They do not
invent a gap location, a missing boundary sample, or an interpolation model.
Multiple discontinuities may collapse into one flag. Internal runs containing no
selected extrema/endpoint are not otherwise reproduced; preserving every run is
a separate variable-output contract. Isolated zero-valued points stay present.

## Capacity, truncation, and failures

One caller result slot contains at most four points plus bounded metadata.
`required_buckets` is exactly `bounds.len`, known before examining history.
Resolve the series/handle and validate all bounds before capacity disposition.
If `output.len < bounds.len`, return `{required_buckets=bounds.len,
written_buckets=0, complete=false}` without reading native history or modifying
output. This is a capacity outcome; it asserts nothing about data presence.

With adequate output, success writes exactly `bounds.len` complete bucket slots
and returns `complete=true`. Slots beyond that prefix are unchanged. Empty bounds
write nothing and return complete. There is no silent point truncation, partial
bucket, or apparently complete prefix. The first API deliberately avoids a
continuation cursor: a full query has a caller-known fixed bound. Callers needing
a prefix can request that explicit bounds prefix, as a separate query whose
first emitted sample starts a new connection.

Invalid input/capacity checks precede writes. Authentication, structural, or I/O
errors during traversal propagate; all output from a failed call is unusable and
may contain an incomplete prefix. Do not render it as a completed response.
Native validation must precede reporting an empty bucket. Changing buffer size
must never suppress authentication of any bucket actually queried.

For a 1,200-bucket viewport, the caller supplies 1,200 bounds and 1,200 result
slots: at most 4,800 original points. Point payload is at most 76,800 bytes
(`Point` is 16 bytes), plus fixed per-bucket counts/flags, caller bounds, and
format-bounded traversal scratch. This is an output bound, not a measured peak
RSS or a promise that a billion-point history can be charted in bounded time.

## Existing format-v7 evidence and resource constraints

`index.Summary` and `page.Statistics` store timestamp min/max, point count, value
first/last, value min/max, and sum. They have no min/max sample timestamps,
numeric/NaN count, or maximum original inter-sample gap. Extrema values alone
cannot identify original samples or earliest-timestamp ties. Reconstructing an
extreme at a bucket edge would violate this contract.

Authenticated timestamp summaries can prune disjoint pages/subtrees and detect
which intervals a subtree intersects. Fully covered counts and endpoint fields
are useful hints; semantic parent/child/page checks still apply. They cannot
alone establish extrema sample identity or all gap/NaN flags. Later pruning
must prove equivalence to the independent raw reference, including ties and
discontinuities; format-v7 statistics are insufficient for a blanket summary-only
claim. No extrema pointers or new persistent summaries are added here.
The baseline's safe summary skip is timestamp-disjoint coverage: after the
applicable authenticated index/edge checks, no sample in that subtree/page can
enter a requested bucket, so its selection decode is unnecessary. For an
intersecting page, fully covered counts or extrema values alone do not remove
its scan under this complete identity/NaN/adjacency contract. This query is not
a replacement for full-database verification of pruned graph regions.

The baseline is one chronological traversal of requested intervals using
existing authenticated index/page decoders and restart cursors. Carry only four
candidates with role/discontinuity state, bucket counts, cross-bucket continuity,
a geometry-bounded index stack, and one page scratch buffer. Publish a bucket
only after its scan completes. Generic storage reauthenticates every byte read;
mapped pointer identity never substitutes for the current parent edge. CT-008's
shared cached-edge issue must be disposed before reusing that helper.

Work may be linear in all selected samples/pages, plus bounds and index traversal.
Implementation evidence must distinguish index nodes visited, page loads
(including revisits), bytes authenticated, records decoded for validation,
records decoded for selection, and original samples selected into output.
These are separate work counts, not a promised measurement surface in this API.
A page intersecting multiple buckets should keep one live decoder and advance
through it; the baseline must not restart a range query for each bucket.
Excluded coverage need not be decoded for selection or adjacency. Authenticating
an intersecting page can still inspect records outside requested bounds; that
validation work does not make omitted coverage part of the connection contract.
First-touch validation may read/decode a selected page's whole bounded geometry,
then selection may decode its queried records again. Warm immutable validation
can skip work already proven by identity; generic loads reauthenticate and may
decode again. The one-pass goal refers to chronological selection traversal,
not a guarantee that authentication and selection inspect each byte only once.
The existing generic `Reader.cursorNext` calls allocation-free `rangePreparedInto`
on each remaining range and can recount/rescan that range per small batch;
naively wrapping it is not evidence of a one-pass generic envelope. Reuse the
direct traversal pattern from aggregate windows with per-page byte cursors,
preserving alignment and immutable/generic verification distinctions.

Count/state bounds derive from format point counts, bucket slice length,
`index.height_max`, `format.page_size`, and restart geometry. Use checked/widened
arithmetic for counters combining bucket and sample events. No history-sized
containers, runtime dependencies, post-open allocation, codec dispatch expansion,
or borrowed cross-refresh data are permitted. Resource gates must cover both
named/prepared calls, raw/compressed pages, cold/warm reads, and generic storage.

## Reference and staged implementation

The independent Python reference under root `.context/CT-006-*` materializes
simple lists as a specification oracle; it is not a production memory model.
It selects roles by sorted-list predicates, combines duplicate timestamps, and
checks original-bit identity, every boundary, capacity, and discontinuity.
Proposal v2 reference evidence includes 13 pure Python cases and 3,906 exhaustive
small-history value combinations. The omitted-bridge case changes unqueried
history while requiring identical output/events; a wide reduced connection with
observed bridging samples must not invent a pair gap. This is specification
evidence, with no engine implementation or native resource validation implied.

Adversarial cases include opposite one-sample spikes within a bucket, repeated
extreme ties, minimum occurring after maximum, zero/all-NaN/empty distinctions,
NaN payloads and signed zeros, subnormals/infinities, gap thresholds at equality,
omitted intervals with hidden bridging samples, empty buckets between samples,
i64 endpoints and full-domain
geometry, and spikes/restarts/index boundaries under both codecs in later tests.

1. Manager reviews/fixes this proposal and freezes names, flags, and capacity
   disposition. CT-006 stops at contract/reference evidence.
2. A separately owned task implements the bounded scan and public Zig surface
   without ABI/format changes, after shared edge validation disposition. Match
   the independent oracle; fail-after-open allocator tests and structural forged
   cases are mandatory. Host-exclusive test modes/simulation need manager grants.
3. Freeze the 1,200-bucket end-to-end workload, including output roles/gap flags,
   consumed results, input hashes, timestamp/value distributions and codec mix.
   Measure inspected pages and resource use through public APIs with native
   correctness evidence before optimizing or comparing engines.
4. Evaluate summary-assisted skipping separately. Any persistent extrema/gap
   summary proposal needs its own version/migration/correctness design. No
   speedup, summary sufficiency, native platform, or release claim is made here.
