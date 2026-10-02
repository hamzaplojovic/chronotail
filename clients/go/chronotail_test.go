package chronotail

import (
	"errors"
	"fmt"
	"math"
	"path/filepath"
	"reflect"
	"testing"
	"unsafe"
)

func BenchmarkCursorChunks(b *testing.B) {
	for _, codec := range []Codec{CodecRaw, CodecCompressed} {
		b.Run(fmt.Sprintf("codec-%d", codec), func(b *testing.B) {
			path := filepath.Join(b.TempDir(), "cursor.ctdb")
			const pointCount = 100_000
			timestamps := make([]int64, pointCount)
			values := make([]float64, pointCount)
			for index := range timestamps {
				timestamps[index] = int64(index*7 + index%5)
				values[index] = float64(index%1000) * 0.125
			}
			writer, err := OpenWriter(path, codec)
			if err != nil {
				b.Fatal(err)
			}
			if err := writer.Append("telemetry", timestamps, values); err != nil {
				b.Fatal(err)
			}
			if err := writer.Close(); err != nil {
				b.Fatal(err)
			}
			reader, err := OpenReader(path)
			if err != nil {
				b.Fatal(err)
			}
			defer reader.Close()

			for _, capacity := range []int{16, 128, 1024} {
				b.Run(fmt.Sprintf("capacity-%d", capacity), func(b *testing.B) {
					outputTimestamps := make([]int64, capacity)
					outputValues := make([]float64, capacity)
					b.SetBytes(pointCount * 16)
					b.ResetTimer()
					for iteration := 0; iteration < b.N; iteration++ {
						cursor, err := reader.Cursor(
							"telemetry",
							timestamps[0],
							timestamps[len(timestamps)-1],
						)
						if err != nil {
							b.Fatal(err)
						}
						count := 0
						for !cursor.Complete() {
							found, _, err := cursor.NextInto(outputTimestamps, outputValues)
							if err != nil {
								b.Fatal(err)
							}
							count += found
						}
						if count != pointCount {
							b.Fatalf("cursor returned %d points, want %d", count, pointCount)
						}
					}
				})
			}
		})
	}
}

func BenchmarkRangeMaterialization(b *testing.B) {
	for _, codec := range []Codec{CodecRaw, CodecCompressed} {
		b.Run(fmt.Sprintf("codec-%d", codec), func(b *testing.B) {
			path := filepath.Join(b.TempDir(), "range.ctdb")
			const pointCount = 100_000
			timestamps := make([]int64, pointCount)
			values := make([]float64, pointCount)
			for index := range timestamps {
				timestamps[index] = int64(index*7 + index%5)
				values[index] = float64(index%1000) * 0.125
			}
			writer, err := OpenWriter(path, codec)
			if err != nil {
				b.Fatal(err)
			}
			if err := writer.Append("telemetry", timestamps, values); err != nil {
				b.Fatal(err)
			}
			if err := writer.Close(); err != nil {
				b.Fatal(err)
			}
			reader, err := OpenReader(path)
			if err != nil {
				b.Fatal(err)
			}
			defer reader.Close()

			b.SetBytes(pointCount * 16)
			b.ReportAllocs()
			b.ResetTimer()
			for iteration := 0; iteration < b.N; iteration++ {
				points, err := reader.Range(
					"telemetry",
					timestamps[0],
					timestamps[len(timestamps)-1],
				)
				if err != nil {
					b.Fatal(err)
				}
				if len(points) != pointCount {
					b.Fatalf("Range returned %d points, want %d", len(points), pointCount)
				}
			}
		})
	}
}

func lookupDistance(a, b int64) uint64 {
	x, y := uint64(a)^(uint64(1)<<63), uint64(b)^(uint64(1)<<63)
	if x > y {
		return x - y
	}
	return y - x
}

// Independent sorted-list model; all arithmetic stays in unsigned rank space.
func referenceLookup(points []Point, target int64, mode LookupMode, limit *uint64) (Point, bool) {
	var result Point
	found := false
	best := uint64(math.MaxUint64)
	for _, point := range points {
		if mode == LookupExact && point.Timestamp != target ||
			mode == LookupPredecessor && point.Timestamp > target ||
			mode == LookupSuccessor && point.Timestamp < target {
			continue
		}
		distance := lookupDistance(point.Timestamp, target)
		if !found || distance < best {
			result, found, best = point, true, distance
		}
	}
	if limit != nil && best > *limit {
		return Point{}, false
	}
	return result, found
}

func checkLookupTarget(t *testing.T, r *Reader, series *Series, name string, points []Point, target int64) {
	t.Helper()
	for mode := LookupExact; mode <= LookupNearest; mode++ {
		limits := []*uint64{nil}
		for _, limit := range []uint64{0, 1, math.MaxUint64, math.MaxUint64 - 1, uint64(1) << 63} {
			value := limit
			limits = append(limits, &value)
		}
		selected, found := referenceLookup(points, target, mode, nil)
		if found {
			distance := lookupDistance(selected.Timestamp, target)
			limits = append(limits, &distance)
			if distance > 0 {
				value := distance - 1
				limits = append(limits, &value)
			}
			if distance < math.MaxUint64 {
				value := distance + 1
				limits = append(limits, &value)
			}
		}
		for _, limit := range limits {
			expected, wantFound := referenceLookup(points, target, mode, limit)
			for form := 0; form < 3; form++ {
				var got Point
				var found bool
				var err error
				switch form {
				case 0:
					got, found, err = r.Lookup(name, target, mode, limit)
				case 1:
					got, found, err = r.LookupPrepared(series, target, mode, limit)
				case 2:
					got, found, err = series.Lookup(target, mode, limit)
				}
				if err != nil || found != wantFound || got.Timestamp != expected.Timestamp ||
					math.Float64bits(got.Value) != math.Float64bits(expected.Value) {
					t.Fatalf("lookup target=%d mode=%d form=%d: got %#v %v %v, want %#v %v", target, mode, form, got, found, err, expected, wantFound)
				}
			}
		}
	}
}

func TestTemporalLookupParity(t *testing.T) {
	for _, codec := range []Codec{CodecRaw, CodecCompressed} {
		t.Run(fmt.Sprintf("codec-%d", codec), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "lookup.ctdb")
			writer, err := OpenWriter(path, codec)
			if err != nil {
				t.Fatal(err)
			}
			defer writer.Close()
			times := []int64{math.MinInt64, math.MinInt64 + 1, -31, -10, 0, 10, 47, math.MaxInt64 - 1, math.MaxInt64}
			bits := []uint64{0, 0x8000000000000000, 1, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000123, 0xfff8000000000456, 0x3ff0000000000000, 0x7fefffffffffffff}
			values := make([]float64, len(bits))
			points := make([]Point, len(bits))
			for i, bits := range bits {
				values[i] = math.Float64frombits(bits)
				points[i] = Point{times[i], values[i]}
			}
			if err := writer.Append("signal", times, values); err != nil {
				t.Fatal(err)
			}
			if err := writer.Append("single", times[:1], values[:1]); err != nil {
				t.Fatal(err)
			}
			many := make([]Point, 132)
			for i := 0; i < len(many); i += 3 {
				for j := 0; j < 3; j++ {
					many[i+j] = Point{int64(i+j)*11 - 500, float64(i + j)}
				}
				if err := writer.Append("pages", []int64{many[i].Timestamp, many[i+1].Timestamp, many[i+2].Timestamp}, []float64{many[i].Value, many[i+1].Value, many[i+2].Value}); err != nil {
					t.Fatal(err)
				}
				if err := writer.Checkpoint(DurabilityMemory); err != nil {
					t.Fatal(err)
				}
			}
			reader, err := OpenReader(path)
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			series, err := reader.PrepareSeries("signal")
			if err != nil {
				t.Fatal(err)
			}
			for _, target := range []int64{math.MinInt64, math.MinInt64 + 2, -32, -31, -20, -11, -10, -5, 0, 5, 11, 46, 48, math.MaxInt64} {
				checkLookupTarget(t, reader, series, "signal", points, target)
			}
			single, err := reader.PrepareSeries("single")
			if err != nil {
				t.Fatal(err)
			}
			checkLookupTarget(t, reader, single, "single", points[:1], math.MaxInt64)
			pages, err := reader.PrepareSeries("pages")
			if err != nil {
				t.Fatal(err)
			}
			for i := 0; i < len(many); i += 3 {
				checkLookupTarget(t, reader, pages, "pages", many, many[i].Timestamp-1)
				checkLookupTarget(t, reader, pages, "pages", many, many[i].Timestamp)
			}
			if changed, err := reader.Refresh(); changed || err != nil {
				t.Fatalf("unchanged refresh: %v %v", changed, err)
			}
			copied, found, err := series.Lookup(math.MinInt64, LookupExact, nil)
			if err != nil || !found {
				t.Fatalf("copy before close: %v %v", found, err)
			}
			other, err := OpenReader(path)
			if err != nil {
				t.Fatal(err)
			}
			defer other.Close()
			if _, found, err := other.LookupPrepared(series, 0, LookupNearest, nil); found || !errors.Is(err, ErrWrongHandle) {
				t.Fatalf("foreign: %v %v", found, err)
			}
			zero := uint64(0)
			if _, found, err := reader.Lookup("unknown", 0, LookupExact, &zero); found || !errors.Is(err, ErrInvalidArgument) {
				t.Fatalf("unknown: %v %v", found, err)
			}
			for _, mode := range []LookupMode{4, 255} {
				if _, found, err := reader.Lookup("signal", 0, mode, nil); found || !errors.Is(err, ErrInvalidArgument) {
					t.Fatalf("mode: %v %v", found, err)
				}
			}
			if _, _, err := reader.Lookup("", 0, LookupExact, nil); !errors.Is(err, ErrEmptySeries) {
				t.Fatal(err)
			}
			if err := writer.Append("pages", []int64{many[len(many)-1].Timestamp + 11}, []float64{0}); err != nil {
				t.Fatal(err)
			}
			if err := writer.Checkpoint(DurabilityMemory); err != nil {
				t.Fatal(err)
			}
			if changed, err := reader.Refresh(); !changed || err != nil {
				t.Fatalf("changed refresh: %v %v", changed, err)
			}
			if _, found, err := reader.LookupPrepared(pages, math.MinInt64, LookupExact, &zero); found || !errors.Is(err, ErrStaleSeries) {
				t.Fatalf("stale: %v %v", found, err)
			}
			if err := reader.Close(); err != nil {
				t.Fatal(err)
			}
			if copied.Timestamp != math.MinInt64 || math.Float64bits(copied.Value) != 0 {
				t.Fatal("copied point changed")
			}
			if _, found, err := series.Lookup(0, LookupNearest, nil); found || !errors.Is(err, ErrClosed) {
				t.Fatalf("closed series: %v %v", found, err)
			}
		})
	}
}

func TestTemporalLookupNilHandles(t *testing.T) {
	var reader *Reader
	var series *Series
	if _, found, err := reader.Lookup("s", 0, LookupExact, nil); found || !errors.Is(err, ErrClosed) {
		t.Fatal(found, err)
	}
	if _, found, err := reader.LookupPrepared(series, 0, LookupExact, nil); found || !errors.Is(err, ErrClosed) {
		t.Fatal(found, err)
	}
	if _, found, err := series.Lookup(0, LookupExact, nil); found || !errors.Is(err, ErrClosed) {
		t.Fatal(found, err)
	}
}

func TestABIVersion(t *testing.T) {
	if got := ABIVersion(); got != expectedABIVersion {
		t.Fatalf("ABIVersion() = %d, want %d", got, expectedABIVersion)
	}
}

func TestPointNativeLayout(t *testing.T) {
	if unsafe.Sizeof(Point{}) != 16 || unsafe.Alignof(Point{}) != 8 ||
		unsafe.Offsetof(Point{}.Timestamp) != 0 || unsafe.Offsetof(Point{}.Value) != 8 {
		t.Fatalf("Point layout is size=%d align=%d timestamp=%d value=%d",
			unsafe.Sizeof(Point{}),
			unsafe.Alignof(Point{}),
			unsafe.Offsetof(Point{}.Timestamp),
			unsafe.Offsetof(Point{}.Value),
		)
	}
}

func TestWriterReaderCompleteSurface(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metrics.ctdb")
	timestamps := []int64{1000, 1001, 1002, 1003, 1004}
	values := []float64{42.5, 43.5, 41.0, 47.0, 44.0}

	writer, err := OpenWriter(path, CodecRaw)
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Prepare("cpu", len(timestamps)+1); err != nil {
		t.Fatal(err)
	}
	if err := writer.Append("cpu", timestamps, values); err != nil {
		t.Fatal(err)
	}
	if err := writer.Checkpoint(DurabilityDisk); err != nil {
		t.Fatal(err)
	}

	second, err := OpenWriter(path, CodecRaw)
	if !errors.Is(err, ErrWriterBusy) {
		if second != nil {
			_ = second.Close()
		}
		t.Fatalf("second writer error = %v, want ErrWriterBusy", err)
	}

	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}

	prefixTimestamps := make([]int64, 2)
	prefixValues := make([]float64, 2)
	required, err := reader.RangeInto("cpu", 1000, 1004, prefixTimestamps, prefixValues)
	if err != nil {
		t.Fatal(err)
	}
	if required != len(timestamps) {
		t.Fatalf("RangeInto required = %d, want %d", required, len(timestamps))
	}
	if !reflect.DeepEqual(prefixTimestamps, timestamps[:2]) || !reflect.DeepEqual(prefixValues, values[:2]) {
		t.Fatalf("RangeInto prefix = %v %v", prefixTimestamps, prefixValues)
	}

	points, err := reader.Range("cpu", 1001, 1003)
	if err != nil {
		t.Fatal(err)
	}
	wantPoints := []Point{{1001, 43.5}, {1002, 41.0}, {1003, 47.0}}
	if !reflect.DeepEqual(points, wantPoints) {
		t.Fatalf("Range() = %#v, want %#v", points, wantPoints)
	}

	aggregate, err := reader.Aggregate("cpu", 1000, 1004)
	if err != nil {
		t.Fatal(err)
	}
	wantAggregate := Aggregate{Count: 5, Minimum: 41, Maximum: 47, Sum: 218, First: 42.5, Last: 44}
	if aggregate != wantAggregate {
		t.Fatalf("Aggregate() = %#v, want %#v", aggregate, wantAggregate)
	}

	empty, err := reader.Aggregate("cpu", 2000, 3000)
	if err != nil {
		t.Fatal(err)
	}
	if empty.Count != 0 || empty.Sum != 0 || !math.IsNaN(empty.Minimum) || !math.IsNaN(empty.Last) {
		t.Fatalf("empty Aggregate() = %#v", empty)
	}

	series, err := reader.PrepareSeries("cpu")
	if err != nil {
		t.Fatal(err)
	}
	preparedPoints, err := series.Range(1000, 1001)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(preparedPoints, []Point{{1000, 42.5}, {1001, 43.5}}) {
		t.Fatalf("prepared Range() = %#v", preparedPoints)
	}
	preparedAggregate, err := series.Aggregate(1002, 1004)
	if err != nil {
		t.Fatal(err)
	}
	if preparedAggregate.Count != 3 || preparedAggregate.Sum != 132 {
		t.Fatalf("prepared Aggregate() = %#v", preparedAggregate)
	}

	page, err := series.BorrowRawPage(1002)
	if err != nil {
		t.Fatal(err)
	}
	if page.TimestampMin != 1000 || page.TimestampMax != 1004 || !reflect.DeepEqual(page.Timestamps, timestamps) || !reflect.DeepEqual(page.Values, values) {
		t.Fatalf("BorrowRawPage() = %#v", page)
	}

	cursor, err := reader.Cursor("cpu", 1001, 1004)
	if err != nil {
		t.Fatal(err)
	}
	var cursorTimestamps []int64
	var cursorValues []float64
	for !cursor.Complete() {
		timestampBuffer := make([]int64, 2)
		valueBuffer := make([]float64, 2)
		count, complete, err := cursor.NextInto(timestampBuffer, valueBuffer)
		if err != nil {
			t.Fatal(err)
		}
		cursorTimestamps = append(cursorTimestamps, timestampBuffer[:count]...)
		cursorValues = append(cursorValues, valueBuffer[:count]...)
		if complete != cursor.Complete() {
			t.Fatal("NextInto completion result disagrees with Complete")
		}
	}
	if !reflect.DeepEqual(cursorTimestamps, timestamps[1:]) || !reflect.DeepEqual(cursorValues, values[1:]) {
		t.Fatalf("cursor = %v %v", cursorTimestamps, cursorValues)
	}
	emptyCursor, err := reader.Cursor("cpu", 2, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !emptyCursor.Complete() {
		t.Fatal("empty cursor must be complete immediately")
	}
	if count, complete, err := emptyCursor.NextInto(make([]int64, 1), make([]float64, 1)); err != nil || count != 0 || !complete {
		t.Fatalf("empty cursor NextInto = %d, %v, %v", count, complete, err)
	}

	otherReader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	state, err := cursorStateCreateNative(reader.handle, "cpu", 1000, 1001)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := cursorStateNextNative(
		otherReader.handle,
		&state,
		make([]int64, 1),
		make([]float64, 1),
	); !errors.Is(err, ErrWrongHandle) {
		t.Fatalf("foreign reader cursor error = %v, want ErrWrongHandle", err)
	}
	cursorStateDestroyNative(state)
	if err := otherReader.Close(); err != nil {
		t.Fatal(err)
	}

	if err := writer.Append("cpu", []int64{1005}, []float64{45}); err != nil {
		t.Fatal(err)
	}
	if err := writer.Checkpoint(DurabilityMemory); err != nil {
		t.Fatal(err)
	}
	changed, err := reader.Refresh()
	if err != nil || !changed {
		t.Fatalf("Refresh() = %v, %v; want true, nil", changed, err)
	}
	if _, err := series.Range(1000, 1005); !errors.Is(err, ErrStaleSeries) {
		t.Fatalf("stale series error = %v", err)
	}
	if _, _, err := cursor.NextInto(make([]int64, 1), make([]float64, 1)); !errors.Is(err, ErrStaleSeries) {
		t.Fatalf("stale cursor error = %v", err)
	}

	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatalf("second reader Close() = %v", err)
	}
	if _, err := reader.Range("cpu", 0, math.MaxInt64); !errors.Is(err, ErrClosed) {
		t.Fatalf("closed reader error = %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("second writer Close() = %v", err)
	}
}

func TestValidationAndNativeErrors(t *testing.T) {
	if _, err := OpenWriter("", CodecRaw); !errors.Is(err, ErrEmptyPath) {
		t.Fatalf("empty path error = %v", err)
	}
	if _, err := OpenWriter("ignored", Codec(99)); !errors.Is(err, ErrInvalidCodec) {
		t.Fatalf("invalid codec error = %v", err)
	}
	if _, err := OpenReader(filepath.Join(t.TempDir(), "missing.ctdb")); !errors.Is(err, ErrIO) {
		t.Fatalf("missing reader error = %v", err)
	}

	path := filepath.Join(t.TempDir(), "validation.ctdb")
	writer, err := OpenWriter(path, CodecCompressed)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = writer.Close() }()

	if err := writer.Prepare("", 1); !errors.Is(err, ErrEmptySeries) {
		t.Fatalf("empty series error = %v", err)
	}
	if err := writer.Prepare("cpu", 0); !errors.Is(err, ErrInvalidCapacity) {
		t.Fatalf("invalid prepare error = %v", err)
	}
	if err := writer.Append("cpu", nil, nil); !errors.Is(err, ErrEmptyBatch) {
		t.Fatalf("empty batch error = %v", err)
	}
	if err := writer.Append("cpu", []int64{1}, nil); !errors.Is(err, ErrMismatchedLengths) {
		t.Fatalf("mismatched batch error = %v", err)
	}
	if err := writer.Append("cpu", []int64{2, 1}, []float64{2, 1}); !errors.Is(err, ErrTimestampOrder) {
		t.Fatalf("timestamp order error = %v", err)
	} else {
		var native *StatusError
		if !errors.As(err, &native) || native.Code != StatusTimestampOrder {
			t.Fatalf("timestamp order status = %#v", native)
		}
	}
	if err := writer.Checkpoint(Durability(99)); !errors.Is(err, ErrInvalidDurability) {
		t.Fatalf("invalid durability error = %v", err)
	}
	const pointCount = 10_000
	timestamps := make([]int64, pointCount)
	values := make([]float64, pointCount)
	for index := range timestamps {
		timestamps[index] = int64(index + 1)
		values[index] = 1
	}
	if err := writer.Prepare("cpu", pointCount); err != nil {
		t.Fatal(err)
	}
	if err := writer.Append("cpu", timestamps, values); err != nil {
		t.Fatalf("writer unusable after validation error: %v", err)
	}
	if err := writer.Checkpoint(DurabilityMemory); err != nil {
		t.Fatal(err)
	}

	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reader.Close() }()
	if _, err := reader.RangeInto("cpu", 0, 2, make([]int64, 1), nil); !errors.Is(err, ErrMismatchedLengths) {
		t.Fatalf("mismatched range error = %v", err)
	}
	cursor, err := reader.Cursor("cpu", 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := cursor.NextInto(nil, nil); !errors.Is(err, ErrInvalidCapacity) {
		t.Fatalf("zero cursor capacity error = %v", err)
	}
	cursor.Close()
	cursor.Close()
	if !cursor.Complete() {
		t.Fatal("closed cursor must report complete")
	}
	series, err := reader.PrepareSeries("cpu")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := series.BorrowRawPage(pointCount / 2); !errors.Is(err, ErrPageNotRaw) {
		t.Fatalf("compressed borrow error = %v", err)
	}
}
