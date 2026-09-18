// Package chronotail provides an idiomatic Go binding to the embedded
// Chronotail time-series engine through C ABI v2.
//
// Handles do not start goroutines and are not safe for concurrent method calls.
// Independent readers may be used concurrently with one writer. Call Close
// explicitly; the package does not rely on finalizers.
package chronotail

import "fmt"

// Codec selects the persistent representation for newly written pages.
type Codec uint8

const (
	CodecRaw        Codec = 0
	CodecCompressed Codec = 1
)

// Durability selects checkpoint publication semantics.
type Durability uint8

const (
	DurabilityMemory Durability = 0
	DurabilityDisk   Durability = 1
)

// Point is one timestamp/value pair returned by Range.
type Point struct {
	Timestamp int64
	Value     float64
}

// Aggregate summarizes an inclusive timestamp range.
type Aggregate struct {
	Count   uint64
	Minimum float64
	Maximum float64
	Sum     float64
	First   float64
	Last    float64
}

// Writer appends strictly ordered points to one database.
type Writer struct {
	handle nativeHandle
}

// OpenWriter opens an existing format-v7 database or creates a new one.
func OpenWriter(path string, codec Codec) (*Writer, error) {
	if path == "" {
		return nil, ErrEmptyPath
	}
	if codec != CodecRaw && codec != CodecCompressed {
		return nil, ErrInvalidCodec
	}
	if err := checkABI(); err != nil {
		return nil, err
	}
	handle, err := openWriterNative(path, codec)
	if err != nil {
		return nil, err
	}
	return &Writer{handle: handle}, nil
}

// Prepare reserves the maximum number of points the series will receive before
// the next checkpoint, keeping prepared appends allocation-free in the engine.
func (w *Writer) Prepare(series string, maximumPointsBeforeCheckpoint int) error {
	if err := w.ready(); err != nil {
		return err
	}
	if series == "" {
		return ErrEmptySeries
	}
	if maximumPointsBeforeCheckpoint <= 0 {
		return ErrInvalidCapacity
	}
	return prepareAppendNative(w.handle, series, maximumPointsBeforeCheckpoint)
}

// Append validates and submits one complete batch. Timestamps and values must
// have equal, nonzero lengths, and timestamps must be strictly increasing.
func (w *Writer) Append(series string, timestamps []int64, values []float64) error {
	if err := w.ready(); err != nil {
		return err
	}
	if series == "" {
		return ErrEmptySeries
	}
	if len(timestamps) != len(values) {
		return ErrMismatchedLengths
	}
	if len(timestamps) == 0 {
		return ErrEmptyBatch
	}
	return appendNative(w.handle, series, timestamps, values)
}

// Checkpoint publishes all pending points with the requested durability.
func (w *Writer) Checkpoint(durability Durability) error {
	if err := w.ready(); err != nil {
		return err
	}
	if durability != DurabilityMemory && durability != DurabilityDisk {
		return ErrInvalidDurability
	}
	return checkpointNative(w.handle, durability)
}

// Close publishes healthy pending state and consumes the native handle. It is
// safe to call Close more than once.
func (w *Writer) Close() error {
	if w == nil || w.handle == nil {
		return nil
	}
	handle := w.handle
	w.handle = nil
	return closeNative(handle)
}

func (w *Writer) ready() error {
	if w == nil || w.handle == nil {
		return ErrClosed
	}
	return nil
}

// Reader owns one immutable committed snapshot.
type Reader struct {
	handle nativeHandle
	epoch  uint64
}

// OpenReader opens and validates the latest complete format-v7 snapshot.
func OpenReader(path string) (*Reader, error) {
	if path == "" {
		return nil, ErrEmptyPath
	}
	if err := checkABI(); err != nil {
		return nil, err
	}
	handle, err := openReaderNative(path)
	if err != nil {
		return nil, err
	}
	return &Reader{handle: handle}, nil
}

// Refresh adopts a newer complete generation when one exists. A successful
// change invalidates prepared series, cursors, and borrowed raw pages.
func (r *Reader) Refresh() (bool, error) {
	if err := r.ready(); err != nil {
		return false, err
	}
	changed, err := refreshNative(r.handle)
	if err == nil && changed {
		r.epoch++
	}
	return changed, err
}

// Range returns all points in the inclusive timestamp range. It allocates the
// exact result size; use RangeInto or Cursor for bounded memory.
func (r *Reader) Range(series string, start, end int64) ([]Point, error) {
	required, err := r.RangeInto(series, start, end, nil, nil)
	if err != nil || required == 0 {
		return nil, err
	}
	points := make([]Point, required)
	actual, err := rangePointsNative(r.handle, series, start, end, points)
	if err != nil {
		return nil, err
	}
	if actual > required {
		return nil, fmt.Errorf("chronotail: snapshot range grew unexpectedly")
	}
	return points[:actual], nil
}

// RangeInto copies the available prefix into equal-length caller buffers and
// returns the total required count. A result larger than len(timestamps) means
// the copied result was truncated.
func (r *Reader) RangeInto(series string, start, end int64, timestamps []int64, values []float64) (int, error) {
	if err := r.ready(); err != nil {
		return 0, err
	}
	if series == "" {
		return 0, ErrEmptySeries
	}
	if len(timestamps) != len(values) {
		return 0, ErrMismatchedLengths
	}
	return rangeNative(r.handle, series, start, end, timestamps, values)
}

// Aggregate returns count, minimum, maximum, sum, first, and last over an
// inclusive range without materializing its points.
func (r *Reader) Aggregate(series string, start, end int64) (Aggregate, error) {
	if err := r.ready(); err != nil {
		return Aggregate{}, err
	}
	if series == "" {
		return Aggregate{}, ErrEmptySeries
	}
	return aggregateNative(r.handle, series, start, end)
}

// PrepareSeries resolves a name once for repeated range, aggregate, and raw
// page operations. The result is invalid after Refresh adopts a generation.
func (r *Reader) PrepareSeries(series string) (*Series, error) {
	if err := r.ready(); err != nil {
		return nil, err
	}
	if series == "" {
		return nil, ErrEmptySeries
	}
	handle, err := prepareSeriesNative(r.handle, series)
	if err != nil {
		return nil, err
	}
	return &Series{reader: r, epoch: r.epoch, handle: handle}, nil
}

// Cursor initializes bounded iteration over an inclusive range.
func (r *Reader) Cursor(series string, start, end int64) (*Cursor, error) {
	if err := r.ready(); err != nil {
		return nil, err
	}
	if series == "" {
		return nil, ErrEmptySeries
	}
	native, err := cursorStateCreateNative(r.handle, series, start, end)
	if err != nil {
		return nil, err
	}
	if end < start {
		cursorStateDestroyNative(native)
		return &Cursor{reader: r, epoch: r.epoch, complete: true}, nil
	}
	return &Cursor{reader: r, epoch: r.epoch, native: native}, nil
}

// Close releases the snapshot and invalidates its prepared values. It is safe
// to call Close more than once.
func (r *Reader) Close() error {
	if r == nil || r.handle == nil {
		return nil
	}
	handle := r.handle
	r.handle = nil
	r.epoch++
	return closeNative(handle)
}

func (r *Reader) ready() error {
	if r == nil || r.handle == nil {
		return ErrClosed
	}
	return nil
}

// Series is a generation-bound prepared series.
type Series struct {
	reader *Reader
	epoch  uint64
	handle nativeSeries
}

// Range returns all points in the inclusive range through the prepared handle.
func (s *Series) Range(start, end int64) ([]Point, error) {
	required, err := s.RangeInto(start, end, nil, nil)
	if err != nil || required == 0 {
		return nil, err
	}
	points := make([]Point, required)
	actual, err := rangePreparedPointsNative(s.reader.handle, s.handle, start, end, points)
	if err != nil {
		return nil, err
	}
	if actual > required {
		return nil, fmt.Errorf("chronotail: snapshot range grew unexpectedly")
	}
	return points[:actual], nil
}

// RangeInto is the caller-buffer form of Series.Range.
func (s *Series) RangeInto(start, end int64, timestamps []int64, values []float64) (int, error) {
	if err := s.ready(); err != nil {
		return 0, err
	}
	if len(timestamps) != len(values) {
		return 0, ErrMismatchedLengths
	}
	return rangePreparedNative(s.reader.handle, s.handle, start, end, timestamps, values)
}

// Aggregate summarizes an inclusive range through the prepared handle.
func (s *Series) Aggregate(start, end int64) (Aggregate, error) {
	if err := s.ready(); err != nil {
		return Aggregate{}, err
	}
	return aggregatePreparedNative(s.reader.handle, s.handle, start, end)
}

// BorrowRawPage returns zero-copy slices owned by the reader snapshot. Treat
// them as read-only and discard them before Reader.Refresh or Reader.Close.
func (s *Series) BorrowRawPage(timestamp int64) (RawPage, error) {
	if err := s.ready(); err != nil {
		return RawPage{}, err
	}
	return borrowRawPageNative(s.reader.handle, s.handle, timestamp)
}

func (s *Series) ready() error {
	if s == nil || s.reader == nil {
		return ErrClosed
	}
	if err := s.reader.ready(); err != nil {
		return err
	}
	if s.epoch != s.reader.epoch {
		return ErrStaleSeries
	}
	return nil
}

// Cursor advances through a range using caller-owned fixed-size buffers.
type Cursor struct {
	reader   *Reader
	epoch    uint64
	native   nativeCursorState
	complete bool
}

// NextInto copies the next chunk and returns its size and whether iteration is
// complete. Buffers must have equal, positive lengths.
func (c *Cursor) NextInto(timestamps []int64, values []float64) (count int, complete bool, err error) {
	if err := c.ready(); err != nil {
		c.release()
		return 0, false, err
	}
	if c.complete {
		return 0, true, nil
	}
	if len(timestamps) != len(values) {
		return 0, false, ErrMismatchedLengths
	}
	if len(timestamps) == 0 {
		return 0, false, ErrInvalidCapacity
	}
	count, complete, err = cursorStateNextNative(
		c.reader.handle,
		&c.native,
		timestamps,
		values,
	)
	if err == nil {
		c.complete = complete
	}
	return count, complete, err
}

// Complete reports whether the cursor has exhausted its range.
func (c *Cursor) Complete() bool {
	return c == nil || c.complete
}

// Close releases native traversal state when iteration is abandoned. Reaching
// the end through NextInto releases it automatically. Close is idempotent.
func (c *Cursor) Close() {
	if c == nil {
		return
	}
	c.release()
	c.complete = true
}

func (c *Cursor) release() {
	if c == nil || c.native == nil {
		return
	}
	cursorStateDestroyNative(c.native)
	c.native = nil
}

func (c *Cursor) ready() error {
	if c == nil || c.reader == nil {
		return ErrClosed
	}
	if err := c.reader.ready(); err != nil {
		return err
	}
	if c.epoch != c.reader.epoch {
		return ErrStaleSeries
	}
	if c.native == nil && !c.complete {
		return ErrClosed
	}
	return nil
}

// RawPage aliases immutable memory mapped by a Reader. Its slices are valid
// only until that reader refreshes or closes.
type RawPage struct {
	Timestamps   []int64
	Values       []float64
	TimestampMin int64
	TimestampMax int64
}
