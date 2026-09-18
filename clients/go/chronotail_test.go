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
