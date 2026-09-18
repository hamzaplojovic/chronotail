package chronotail

/*
#cgo CFLAGS: -I${SRCDIR}/../../include
#cgo LDFLAGS: -lchronotail
#include <chronotail.h>
*/
import "C"

import (
	"fmt"
	"runtime"
	"unsafe"
)

const expectedABIVersion = 2

type nativeHandle = unsafe.Pointer
type nativeSeries = C.ct_series_handle
type nativeCursorState = *C.ct_cursor_state

// ABIVersion returns the version exported by the loaded native library.
func ABIVersion() uint32 { return uint32(C.ct_abi_version()) }

func checkABI() error {
	actual := ABIVersion()
	if actual != expectedABIVersion {
		return fmt.Errorf("%w: expected %d, got %d", ErrIncompatibleABI, expectedABIVersion, actual)
	}
	return nil
}

func status(code C.int) error {
	if code == C.CT_OK {
		return nil
	}
	return &StatusError{Code: int(code), Message: C.GoString(C.ct_error_string(code))}
}

func stringPointer(value string) *C.char {
	if len(value) == 0 {
		return nil
	}
	return (*C.char)(unsafe.Pointer(unsafe.StringData(value)))
}

func timestampPointer(values []int64) *C.int64_t {
	if len(values) == 0 {
		return nil
	}
	return (*C.int64_t)(unsafe.Pointer(&values[0]))
}

func valuePointer(values []float64) *C.double {
	if len(values) == 0 {
		return nil
	}
	return (*C.double)(unsafe.Pointer(&values[0]))
}

func pointPointer(points []Point) *C.ct_point {
	if len(points) == 0 {
		return nil
	}
	return (*C.ct_point)(unsafe.Pointer(&points[0]))
}

func openWriterNative(path string, codec Codec) (nativeHandle, error) {
	var handle unsafe.Pointer
	code := C.ct_open_writer(
		stringPointer(path),
		C.size_t(len(path)),
		C.uint8_t(codec),
		&handle,
	)
	runtime.KeepAlive(path)
	return handle, status(code)
}

func openReaderNative(path string) (nativeHandle, error) {
	var handle unsafe.Pointer
	code := C.ct_open_reader(stringPointer(path), C.size_t(len(path)), &handle)
	runtime.KeepAlive(path)
	return handle, status(code)
}

func appendNative(handle nativeHandle, series string, timestamps []int64, values []float64) error {
	code := C.ct_append(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		timestampPointer(timestamps),
		valuePointer(values),
		C.size_t(len(timestamps)),
	)
	runtime.KeepAlive(series)
	runtime.KeepAlive(timestamps)
	runtime.KeepAlive(values)
	return status(code)
}

func prepareAppendNative(handle nativeHandle, series string, maximum int) error {
	code := C.ct_prepare_append(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		C.size_t(maximum),
	)
	runtime.KeepAlive(series)
	return status(code)
}

func checkpointNative(handle nativeHandle, durability Durability) error {
	return status(C.ct_checkpoint_with_durability(
		handle,
		C.uint8_t(durability),
	))
}

func refreshNative(handle nativeHandle) (bool, error) {
	var changed C.uint8_t
	if err := status(C.ct_refresh(handle, &changed)); err != nil {
		return false, err
	}
	return changed != 0, nil
}

func rangeNative(handle nativeHandle, series string, start, end int64, timestamps []int64, values []float64) (int, error) {
	var count C.size_t
	code := C.ct_range(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		C.int64_t(start),
		C.int64_t(end),
		timestampPointer(timestamps),
		valuePointer(values),
		C.size_t(len(timestamps)),
		&count,
	)
	runtime.KeepAlive(series)
	runtime.KeepAlive(timestamps)
	runtime.KeepAlive(values)
	if code == C.CT_BUFFER_TOO_SMALL {
		return int(count), nil
	}
	return int(count), status(code)
}

func rangePointsNative(handle nativeHandle, series string, start, end int64, points []Point) (int, error) {
	var count C.size_t
	code := C.ct_range_points(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		C.int64_t(start),
		C.int64_t(end),
		pointPointer(points),
		C.size_t(len(points)),
		&count,
	)
	runtime.KeepAlive(series)
	runtime.KeepAlive(points)
	if code == C.CT_BUFFER_TOO_SMALL {
		return int(count), nil
	}
	return int(count), status(code)
}

func prepareSeriesNative(handle nativeHandle, series string) (nativeSeries, error) {
	var prepared nativeSeries
	code := C.ct_prepare_series(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		&prepared,
	)
	runtime.KeepAlive(series)
	return prepared, status(code)
}

func rangePreparedNative(handle nativeHandle, prepared nativeSeries, start, end int64, timestamps []int64, values []float64) (int, error) {
	var count C.size_t
	code := C.ct_range_prepared(
		handle,
		prepared,
		C.int64_t(start),
		C.int64_t(end),
		timestampPointer(timestamps),
		valuePointer(values),
		C.size_t(len(timestamps)),
		&count,
	)
	runtime.KeepAlive(timestamps)
	runtime.KeepAlive(values)
	if code == C.CT_BUFFER_TOO_SMALL {
		return int(count), nil
	}
	return int(count), status(code)
}

func rangePreparedPointsNative(handle nativeHandle, prepared nativeSeries, start, end int64, points []Point) (int, error) {
	var count C.size_t
	code := C.ct_range_points_prepared(
		handle,
		prepared,
		C.int64_t(start),
		C.int64_t(end),
		pointPointer(points),
		C.size_t(len(points)),
		&count,
	)
	runtime.KeepAlive(points)
	if code == C.CT_BUFFER_TOO_SMALL {
		return int(count), nil
	}
	return int(count), status(code)
}

func aggregateNative(handle nativeHandle, series string, start, end int64) (Aggregate, error) {
	var result C.ct_aggregate_result
	code := C.ct_aggregate(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		C.int64_t(start),
		C.int64_t(end),
		&result,
	)
	runtime.KeepAlive(series)
	return aggregateFromNative(result), status(code)
}

func aggregatePreparedNative(handle nativeHandle, prepared nativeSeries, start, end int64) (Aggregate, error) {
	var result C.ct_aggregate_result
	code := C.ct_aggregate_prepared(
		handle,
		prepared,
		C.int64_t(start),
		C.int64_t(end),
		&result,
	)
	return aggregateFromNative(result), status(code)
}

func aggregateFromNative(result C.ct_aggregate_result) Aggregate {
	return Aggregate{
		Count:   uint64(result.count),
		Minimum: float64(result.minimum),
		Maximum: float64(result.maximum),
		Sum:     float64(result.sum),
		First:   float64(result.first),
		Last:    float64(result.last),
	}
}

func cursorStateCreateNative(
	handle nativeHandle,
	series string,
	start int64,
	end int64,
) (nativeCursorState, error) {
	var cursor nativeCursorState
	code := C.ct_cursor_state_create(
		handle,
		stringPointer(series),
		C.size_t(len(series)),
		C.int64_t(start),
		C.int64_t(end),
		&cursor,
	)
	runtime.KeepAlive(series)
	return cursor, status(code)
}

func cursorStateNextNative(
	handle nativeHandle,
	cursor *nativeCursorState,
	timestamps []int64,
	values []float64,
) (count int, complete bool, err error) {
	var nativeCount C.size_t
	var nativeComplete C.uint8_t
	code := C.ct_cursor_state_next(
		handle,
		*cursor,
		timestampPointer(timestamps),
		valuePointer(values),
		C.size_t(len(timestamps)),
		&nativeCount,
		&nativeComplete,
	)
	runtime.KeepAlive(timestamps)
	runtime.KeepAlive(values)
	complete = nativeComplete != 0
	if complete {
		C.ct_cursor_state_destroy(*cursor)
		*cursor = nil
	}
	return int(nativeCount), complete, status(code)
}

func cursorStateDestroyNative(cursor nativeCursorState) {
	if cursor != nil {
		C.ct_cursor_state_destroy(cursor)
	}
}

func borrowRawPageNative(handle nativeHandle, prepared nativeSeries, timestamp int64) (RawPage, error) {
	var view C.ct_raw_page_view
	code := C.ct_borrow_raw_page(
		handle,
		prepared,
		C.int64_t(timestamp),
		&view,
	)
	if err := status(code); err != nil {
		return RawPage{}, err
	}
	count := int(view.count)
	return RawPage{
		Timestamps:   unsafe.Slice((*int64)(unsafe.Pointer(view.timestamps)), count),
		Values:       unsafe.Slice((*float64)(unsafe.Pointer(view.values)), count),
		TimestampMin: int64(view.timestamp_min),
		TimestampMax: int64(view.timestamp_max),
	}, nil
}

func closeNative(handle nativeHandle) error {
	return status(C.ct_close(handle))
}
