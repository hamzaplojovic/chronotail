from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path
from typing import Iterable

ABI_VERSION = 1
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

_lib.ct_abi_version.restype = ctypes.c_uint32
_lib.ct_error_string.argtypes = [ctypes.c_int]
_lib.ct_error_string.restype = ctypes.c_char_p
_lib.ct_open_writer.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint8, ctypes.POINTER(_handle)]
_lib.ct_open_writer.restype = ctypes.c_int
_lib.ct_append.argtypes = [_handle, ctypes.c_char_p, ctypes.c_size_t, _i64_p, _f64_p, ctypes.c_size_t]
_lib.ct_append.restype = ctypes.c_int
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


class Reader:
    def __init__(self, path: str | os.PathLike[str]):
        path_bytes = _encoded(path)
        self._handle = _handle()
        _check(_lib.ct_open_reader(path_bytes, len(path_bytes), ctypes.byref(self._handle)))

    def refresh(self) -> bool:
        changed = ctypes.c_uint8()
        _check(_lib.ct_refresh(self._handle, ctypes.byref(changed)))
        return bool(changed.value)

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
