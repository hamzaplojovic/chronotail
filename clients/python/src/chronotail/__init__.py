from __future__ import annotations

import ctypes
import os
import sys
from enum import IntEnum
from pathlib import Path
from typing import Generator, Iterable, NamedTuple

ABI_VERSION = 2
CT_OK = 0
CT_BUFFER_TOO_SMALL = 1


def _load_library() -> ctypes.CDLL:
    override = os.environ.get("CHRONOTAIL_LIBRARY")
    if override:
        return ctypes.CDLL(override)
    package = Path(__file__).resolve().parent
    names = {
        "darwin": ["libchronotail.dylib"],
        "win32": ["chronotail.dll", "libchronotail.dll"],
    }.get(sys.platform, ["libchronotail.so"])
    search_roots = (package / "_native", package, package.parents[2] / "zig-out" / "lib")
    for root in search_roots:
        for name in names:
            candidate = root / name
            if candidate.exists():
                return ctypes.CDLL(str(candidate))
    raise ImportError("Chronotail native library not found; set CHRONOTAIL_LIBRARY")


_lib = _load_library()
_handle = ctypes.c_void_p
_i64_p = ctypes.POINTER(ctypes.c_int64)
_f64_p = ctypes.POINTER(ctypes.c_double)


class Aggregate(NamedTuple):
    count: int
    minimum: float
    maximum: float
    sum: float
    first: float
    last: float


class _CAggregate(ctypes.Structure):
    _fields_ = [
        ("count", ctypes.c_uint64),
        ("minimum", ctypes.c_double),
        ("maximum", ctypes.c_double),
        ("sum", ctypes.c_double),
        ("first", ctypes.c_double),
        ("last", ctypes.c_double),
    ]


class LookupMode(IntEnum):
    EXACT = 0
    PREDECESSOR = 1
    SUCCESSOR = 2
    NEAREST = 3


class _CPoint(ctypes.Structure):
    _fields_ = [("timestamp", ctypes.c_int64), ("value", ctypes.c_double)]


class _CSeriesHandle(ctypes.Structure):
    _fields_ = [
        ("index", ctypes.c_uint32), ("reserved", ctypes.c_uint32),
        ("generation", ctypes.c_uint64),
    ]


_lib.ct_abi_version.restype = ctypes.c_uint32
_lib.ct_error_string.argtypes = [ctypes.c_int]
_lib.ct_error_string.restype = ctypes.c_char_p
_lib.ct_open_writer.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint8, ctypes.POINTER(_handle)]
_lib.ct_open_writer.restype = ctypes.c_int
_lib.ct_append.argtypes = [_handle, ctypes.c_char_p, ctypes.c_size_t, _i64_p, _f64_p, ctypes.c_size_t]
_lib.ct_append.restype = ctypes.c_int
_lib.ct_prepare_append.argtypes = [
    _handle,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_size_t,
]
_lib.ct_prepare_append.restype = ctypes.c_int
_lib.ct_checkpoint.argtypes = [_handle, ctypes.c_uint8]
_lib.ct_checkpoint.restype = ctypes.c_int
_lib.ct_open_reader.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(_handle)]
_lib.ct_open_reader.restype = ctypes.c_int
_lib.ct_refresh.argtypes = [_handle, ctypes.POINTER(ctypes.c_uint8)]
_lib.ct_refresh.restype = ctypes.c_int
_lib.ct_range.argtypes = [
    _handle,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_int64,
    ctypes.c_int64,
    _i64_p,
    _f64_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]
_lib.ct_range.restype = ctypes.c_int
_lib.ct_prepare_series.argtypes = [
    _handle, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(_CSeriesHandle),
]
_lib.ct_prepare_series.restype = ctypes.c_int
# Lookup is an optional complete pair, independent of stateful streaming.
try:
    _lib.ct_lookup
    _lib.ct_lookup_prepared
except AttributeError:
    _has_lookup = False
else:
    _has_lookup = True
    _lookup_tail = [
        ctypes.c_int64, ctypes.c_uint8, ctypes.c_uint8, ctypes.c_uint64,
        ctypes.POINTER(_CPoint), ctypes.POINTER(ctypes.c_uint8),
    ]
    _lib.ct_lookup.argtypes = [_handle, ctypes.c_char_p, ctypes.c_size_t] + _lookup_tail
    _lib.ct_lookup.restype = ctypes.c_int
    _lib.ct_lookup_prepared.argtypes = [_handle, _CSeriesHandle] + _lookup_tail
    _lib.ct_lookup_prepared.restype = ctypes.c_int
# Earlier ABI-v2 libraries do not export the opaque stateful cursor capability.
try:
    _lib.ct_cursor_state_create
    _lib.ct_cursor_state_next
    _lib.ct_cursor_state_destroy
except AttributeError:
    _has_stateful_cursor = False
else:
    _has_stateful_cursor = True
    _lib.ct_cursor_state_create.argtypes = [
        _handle,
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.c_int64,
        ctypes.c_int64,
        ctypes.POINTER(_handle),
    ]
    _lib.ct_cursor_state_create.restype = ctypes.c_int
    _lib.ct_cursor_state_next.argtypes = [
        _handle,
        _handle,
        _i64_p,
        _f64_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.POINTER(ctypes.c_uint8),
    ]
    _lib.ct_cursor_state_next.restype = ctypes.c_int
    _lib.ct_cursor_state_destroy.argtypes = [_handle]
    _lib.ct_cursor_state_destroy.restype = None
_lib.ct_aggregate.argtypes = [
    _handle,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_int64,
    ctypes.c_int64,
    ctypes.POINTER(_CAggregate),
]
_lib.ct_aggregate.restype = ctypes.c_int
_lib.ct_close.argtypes = [_handle]
_lib.ct_close.restype = ctypes.c_int

if _lib.ct_abi_version() != ABI_VERSION:
    raise ImportError(f"incompatible Chronotail ABI: expected {ABI_VERSION}, got {_lib.ct_abi_version()}")


class ChronotailError(RuntimeError):
    pass


def _check(code: int) -> None:
    if code != CT_OK:
        message = _lib.ct_error_string(code).decode("utf-8", "replace")
        raise ChronotailError(f"{message} ({code})")


def _encoded(value: str | os.PathLike[str]) -> bytes:
    return os.fsencode(value)


class Writer:
    def __init__(
        self,
        path: str | os.PathLike[str],
        batch_size: int = 1000,
        codec: str = "compressed",
    ):
        if batch_size < 1:
            raise ValueError("batch_size must be positive")
        codec_value = {"raw": 0, "compressed": 1}.get(codec)
        if codec_value is None:
            raise ValueError("codec must be 'raw' or 'compressed'")
        path_bytes = _encoded(path)
        self._handle = _handle()
        _check(_lib.ct_open_writer(path_bytes, len(path_bytes), codec_value, ctypes.byref(self._handle)))
        self._batch_size = batch_size
        self._buffers: dict[str, tuple[list[int], list[float]]] = {}

    def append(self, series: str, timestamps, values) -> None:
        if not isinstance(timestamps, int):
            self.append_many(series, timestamps, values)
            return
        pending_timestamps, pending_values = self._buffers.setdefault(series, ([], []))
        pending_timestamps.append(timestamps)
        pending_values.append(values)
        if len(pending_timestamps) >= self._batch_size:
            self._flush_series(series, pending_timestamps, pending_values)

    def append_many(self, series: str, timestamps: Iterable[int], values: Iterable[float]) -> None:
        pending_timestamps, pending_values = self._buffers.setdefault(series, ([], []))
        if not pending_timestamps and self._append_buffer_batches(series, timestamps, values):
            return
        timestamp_list = list(timestamps)
        value_list = list(values)
        if len(timestamp_list) != len(value_list):
            raise ValueError("timestamps and values must have equal lengths")
        offset = 0
        if pending_timestamps:
            needed = min(self._batch_size - len(pending_timestamps), len(timestamp_list))
            pending_timestamps.extend(timestamp_list[:needed])
            pending_values.extend(value_list[:needed])
            offset = needed
            if len(pending_timestamps) == self._batch_size:
                self._flush_series(series, pending_timestamps, pending_values)
        while len(timestamp_list) - offset >= self._batch_size:
            end = offset + self._batch_size
            self._append_native(series, timestamp_list[offset:end], value_list[offset:end])
            offset = end
        pending_timestamps.extend(timestamp_list[offset:])
        pending_values.extend(value_list[offset:])

    def checkpoint(self, fsync: bool = False) -> None:
        self._flush()
        _check(_lib.ct_checkpoint(self._handle, int(fsync)))

    def prepare(self, series: str, maximum_points_before_checkpoint: int) -> None:
        if maximum_points_before_checkpoint < 1:
            raise ValueError("maximum_points_before_checkpoint must be positive")
        series_bytes = series.encode("utf-8")
        _check(
            _lib.ct_prepare_append(
                self._handle,
                series_bytes,
                len(series_bytes),
                maximum_points_before_checkpoint,
            )
        )

    def close(self) -> None:
        if not self._handle:
            return
        try:
            self._flush()
        finally:
            handle, self._handle = self._handle, _handle()
            _check(_lib.ct_close(handle))

    def __enter__(self) -> "Writer":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()

    def _flush(self) -> None:
        for series, (timestamps, values) in self._buffers.items():
            if timestamps:
                self._flush_series(series, timestamps, values)

    def _flush_series(self, series: str, timestamps: list[int], values: list[float]) -> None:
        self._append_native(series, timestamps, values)
        timestamps.clear()
        values.clear()

    def _append_native(self, series: str, timestamps: list[int], values: list[float]) -> None:
        count = len(timestamps)
        timestamp_array = (ctypes.c_int64 * count)(*timestamps)
        value_array = (ctypes.c_double * count)(*values)
        self._call_append(series, timestamp_array, value_array, count)

    def _append_buffer_batches(
        self,
        series: str,
        timestamps: Iterable[int],
        values: Iterable[float],
    ) -> bool:
        try:
            timestamp_view = memoryview(timestamps)
            value_view = memoryview(values)
        except TypeError:
            return False
        if (
            timestamp_view.ndim != 1
            or value_view.ndim != 1
            or timestamp_view.itemsize != 8
            or value_view.itemsize != 8
            or timestamp_view.format not in ("q", "l")
            or value_view.format != "d"
            or len(timestamp_view) != len(value_view)
            or not timestamp_view.c_contiguous
            or not value_view.c_contiguous
            or timestamp_view.readonly
            or value_view.readonly
        ):
            return False
        offset = 0
        count = len(timestamp_view)
        while offset < count:
            batch_count = min(self._batch_size, count - offset)
            timestamp_array = (ctypes.c_int64 * batch_count).from_buffer(
                timestamps, offset * timestamp_view.itemsize
            )
            value_array = (ctypes.c_double * batch_count).from_buffer(
                values, offset * value_view.itemsize
            )
            self._call_append(series, timestamp_array, value_array, batch_count)
            offset += batch_count
        return True

    def _call_append(self, series: str, timestamps, values, count: int) -> None:
        series_bytes = series.encode("utf-8")
        _check(
            _lib.ct_append(
                self._handle,
                series_bytes,
                len(series_bytes),
                timestamps,
                values,
                count,
            )
        )


class SeriesHandle:
    """Opaque prepared series belonging to one reader snapshot; use Reader.prepare."""

    __slots__ = ("_reader", "_epoch", "_native")

    def __init__(self):
        raise TypeError("SeriesHandle is created by Reader.prepare")


def _lookup_arguments(timestamp: int, mode: LookupMode, max_distance: int | None) -> None:
    if not isinstance(mode, LookupMode):
        raise ValueError("mode must be a LookupMode member")
    if (not isinstance(timestamp, int) or isinstance(timestamp, bool)
            or not -(1 << 63) <= timestamp < (1 << 63)):
        raise ValueError("timestamp must be a signed 64-bit integer")
    if max_distance is not None and (
        not isinstance(max_distance, int) or isinstance(max_distance, bool)
        or not 0 <= max_distance < (1 << 64)
    ):
        raise ValueError("max_distance must be None or an unsigned 64-bit integer")


def _lookup_capability() -> None:
    if not _has_lookup:
        raise NotImplementedError(
            "Reader.lookup/lookup_prepared require native ct_lookup and ct_lookup_prepared symbols"
        )


class Reader:
    def __init__(self, path: str | os.PathLike[str]):
        path_bytes = _encoded(path)
        self._handle = _handle()
        _check(_lib.ct_open_reader(path_bytes, len(path_bytes), ctypes.byref(self._handle)))
        self._iteration_epoch = 0

    def refresh(self) -> bool:
        changed = ctypes.c_uint8()
        _check(_lib.ct_refresh(self._handle, ctypes.byref(changed)))
        if changed.value:
            self._iteration_epoch += 1
        return bool(changed.value)

    def prepare(self, series: str) -> SeriesHandle:
        """Prepare a series without requiring the optional lookup capability."""
        if not isinstance(series, str):
            raise ValueError("series must be a string")
        self._lookup_ready()
        series_bytes = series.encode("utf-8")
        native = _CSeriesHandle()
        _check(_lib.ct_prepare_series(
            self._handle, series_bytes, len(series_bytes), ctypes.byref(native),
        ))
        prepared = object.__new__(SeriesHandle)
        prepared._reader, prepared._epoch, prepared._native = self, self._iteration_epoch, native
        return prepared

    def lookup(
        self, series: str, timestamp: int, mode: LookupMode,
        *, max_distance: int | None = None,
    ) -> tuple[int, float] | None:
        """Select an original point; directions/limit are inclusive, ties go earlier.

        None is missing. A zero distance accepts only equality; None distance is
        unlimited. Timestamp units are caller-defined; value bits are preserved.
        """
        _lookup_arguments(timestamp, mode, max_distance)
        if not isinstance(series, str):
            raise ValueError("series must be a string")
        self._lookup_ready()
        _lookup_capability()
        series_bytes = series.encode("utf-8")
        point, found = _CPoint(), ctypes.c_uint8()
        _check(_lib.ct_lookup(
            self._handle, series_bytes, len(series_bytes), timestamp, mode.value,
            int(max_distance is not None), 0 if max_distance is None else max_distance,
            ctypes.byref(point), ctypes.byref(found),
        ))
        return (point.timestamp, point.value) if found.value else None

    def lookup_prepared(
        self, series: SeriesHandle, timestamp: int, mode: LookupMode,
        *, max_distance: int | None = None,
    ) -> tuple[int, float] | None:
        """Lookup through this reader's prepared series; changed refresh stales it."""
        _lookup_arguments(timestamp, mode, max_distance)
        if not isinstance(series, SeriesHandle):
            raise ValueError("series must be a SeriesHandle from Reader.prepare")
        self._lookup_ready()
        series._reader._lookup_ready()
        if series._reader is not self:
            raise ChronotailError("prepared series belongs to a different reader")
        if series._epoch != self._iteration_epoch:
            raise ChronotailError("prepared series is stale after refresh")
        _lookup_capability()
        point, found = _CPoint(), ctypes.c_uint8()
        _check(_lib.ct_lookup_prepared(
            self._handle, series._native, timestamp, mode.value,
            int(max_distance is not None), 0 if max_distance is None else max_distance,
            ctypes.byref(point), ctypes.byref(found),
        ))
        return (point.timestamp, point.value) if found.value else None

    def _lookup_ready(self) -> None:
        if not self._handle:
            raise ChronotailError("reader is closed")

    def range(self, series: str, start: int, end: int) -> list[tuple[int, float]]:
        capacity = 1024
        series_bytes = series.encode("utf-8")
        while True:
            timestamps = (ctypes.c_int64 * capacity)()
            values = (ctypes.c_double * capacity)()
            count = ctypes.c_size_t()
            code = _lib.ct_range(
                self._handle,
                series_bytes,
                len(series_bytes),
                start,
                end,
                timestamps,
                values,
                capacity,
                ctypes.byref(count),
            )
            if code == CT_BUFFER_TOO_SMALL:
                capacity = count.value
                continue
            _check(code)
            return [(timestamps[i], values[i]) for i in range(count.value)]

    def iter_range(
        self, series: str, start: int, end: int, *, batch_size: int = 1024
    ) -> Generator[tuple[int, float], None, None]:
        """Yield inclusive-range points from this snapshot using bounded buffers.

        Close the generator when stopping early. A changed refresh or reader
        close invalidates it, including points already buffered for yielding.
        Missing native stateful cursor symbols raise NotImplementedError here.
        """
        if (
            not isinstance(batch_size, int)
            or isinstance(batch_size, bool)
            or batch_size < 1
            or batch_size > sys.maxsize // ctypes.sizeof(ctypes.c_int64)
        ):
            raise ValueError("batch_size must be a positive integer fitting native buffers")
        for name, bound in (("start", start), ("end", end)):
            if (
                not isinstance(bound, int)
                or isinstance(bound, bool)
                or not -(1 << 63) <= bound < (1 << 63)
            ):
                raise ValueError(f"{name} must be a signed 64-bit integer")
        if not _has_stateful_cursor:
            raise NotImplementedError(
                "Reader.iter_range requires native ct_cursor_state_create, "
                "ct_cursor_state_next, and ct_cursor_state_destroy symbols"
            )
        epoch = self._iteration_epoch
        self._check_iteration(epoch)
        series_bytes = series.encode("utf-8")

        def iterate() -> Generator[tuple[int, float], None, None]:
            self._check_iteration(epoch)
            timestamps = (ctypes.c_int64 * batch_size)()
            values = (ctypes.c_double * batch_size)()
            cursor = _handle()
            try:
                _check(
                    _lib.ct_cursor_state_create(
                        self._handle,
                        series_bytes,
                        len(series_bytes),
                        start,
                        end,
                        ctypes.byref(cursor),
                    )
                )
                while True:
                    self._check_iteration(epoch)
                    count = ctypes.c_size_t()
                    complete = ctypes.c_uint8()
                    _check(
                        _lib.ct_cursor_state_next(
                            self._handle,
                            cursor,
                            timestamps,
                            values,
                            batch_size,
                            ctypes.byref(count),
                            ctypes.byref(complete),
                        )
                    )
                    for i in range(count.value):
                        self._check_iteration(epoch)
                        yield timestamps[i], values[i]
                    if complete.value:
                        return
            finally:
                if cursor:
                    _lib.ct_cursor_state_destroy(cursor)

        return iterate()

    def _check_iteration(self, epoch: int) -> None:
        if not self._handle:
            raise ChronotailError("reader is closed")
        if epoch != self._iteration_epoch:
            raise ChronotailError("range iterator is stale after refresh")

    def aggregate(self, series: str, start: int, end: int) -> Aggregate:
        series_bytes = series.encode("utf-8")
        result = _CAggregate()
        _check(
            _lib.ct_aggregate(
                self._handle,
                series_bytes,
                len(series_bytes),
                start,
                end,
                ctypes.byref(result),
            )
        )
        return Aggregate(
            result.count,
            result.minimum,
            result.maximum,
            result.sum,
            result.first,
            result.last,
        )

    def close(self) -> None:
        if self._handle:
            handle, self._handle = self._handle, _handle()
            _check(_lib.ct_close(handle))

    def __enter__(self) -> "Reader":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()


def open(
    path: str | os.PathLike[str],
    *,
    batch_size: int = 1000,
    codec: str = "compressed",
) -> Writer:
    return Writer(path, batch_size, codec)


def read(path: str | os.PathLike[str]) -> Reader:
    return Reader(path)
