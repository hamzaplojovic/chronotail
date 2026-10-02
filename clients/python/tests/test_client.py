from __future__ import annotations

import ctypes
import importlib.util
import math
import struct
import sys
import tempfile
import unittest
from array import array
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import chronotail


class NativeCompatibilityTest(unittest.TestCase):
    # Exact declarations in v2.0.0 include/chronotail.h (C ABI version 2).
    OLD_ABI_V2_SYMBOLS = (
        "ct_abi_version", "ct_error_string", "ct_open_writer", "ct_append",
        "ct_prepare_append", "ct_checkpoint", "ct_checkpoint_with_durability",
        "ct_open_reader", "ct_refresh", "ct_range", "ct_prepare_series",
        "ct_range_prepared", "ct_aggregate", "ct_aggregate_prepared",
        "ct_cursor_init", "ct_cursor_next", "ct_borrow_raw_page", "ct_close",
    )
    STATEFUL_SYMBOLS = (
        "ct_cursor_state_create", "ct_cursor_state_next", "ct_cursor_state_destroy",
    )

    def _old_library(self):
        library = SimpleNamespace(**{
            name: mock.Mock(return_value=0) for name in self.OLD_ABI_V2_SYMBOLS
        })
        library.ct_abi_version.return_value = 2
        library.ct_error_string.return_value = b"stub failure"

        def open_handle(*args):
            args[-1]._obj.value = 123
            return 0

        def read_range(handle, series, length, start, end, timestamps, values, capacity, count):
            points = [(timestamp, value) for timestamp, value in ((10, 1.5), (20, 2.5))
                      if start <= timestamp <= end]
            count._obj.value = len(points)
            for i, (timestamp, value) in enumerate(points[:capacity]):
                timestamps[i], values[i] = timestamp, value
            return 1 if len(points) > capacity else 0

        def aggregate(handle, series, length, start, end, output):
            result = output._obj
            result.count, result.minimum, result.maximum = 2, 1.5, 2.5
            result.sum, result.first, result.last = 4.0, 1.5, 2.5
            return 0

        library.ct_open_reader.side_effect = open_handle
        library.ct_open_writer.side_effect = open_handle
        library.ct_range.side_effect = read_range
        library.ct_aggregate.side_effect = aggregate
        return library

    def _import_with_library(self, library):
        spec = importlib.util.spec_from_file_location("chronotail_compat", chronotail.__file__)
        module = importlib.util.module_from_spec(spec)
        with mock.patch.object(ctypes, "CDLL", return_value=library), mock.patch.dict(
            "os.environ", {"CHRONOTAIL_LIBRARY": "/stub-abi-v2"}
        ):
            spec.loader.exec_module(module)
        return module

    def test_old_abi_v2_preserves_existing_api_without_stateful_cursors(self) -> None:
        library = self._old_library()
        self.assertEqual(set(vars(library)), set(self.OLD_ABI_V2_SYMBOLS))
        module = self._import_with_library(library)
        self.assertEqual(module.ABI_VERSION, 2)
        with module.Writer("stub.ctdb", batch_size=2) as writer:
            writer.prepare("cpu", 2)
            writer.append_many("cpu", [10, 20], [1.5, 2.5])
            writer.checkpoint()
        library.ct_prepare_append.assert_called_once()
        library.ct_append.assert_called_once()
        with module.Reader("stub.ctdb") as reader:
            self.assertEqual(reader.range("cpu", 10, 20), [(10, 1.5), (20, 2.5)])
            self.assertEqual(reader.aggregate("cpu", 10, 20),
                             module.Aggregate(2, 1.5, 2.5, 4.0, 1.5, 2.5))
            self.assertFalse(reader.refresh())
            with mock.patch.object(
                library, "ct_range", side_effect=AssertionError("no rescanning fallback")
            ) as materialize:
                with self.assertRaisesRegex(NotImplementedError, "iter_range.*ct_cursor_state"):
                    reader.iter_range("cpu", 10, 20)
                materialize.assert_not_called()
            library.ct_cursor_init.assert_not_called()
            library.ct_cursor_next.assert_not_called()
            self.assertEqual(set(vars(library)), set(self.OLD_ABI_V2_SYMBOLS))
        self.assertEqual(library.ct_close.call_count, 2)

    def test_incomplete_stateful_capability_fails_before_cursor_allocation(self) -> None:
        # Some symbols alone are insufficient: creation must have a destroy path.
        for missing in self.STATEFUL_SYMBOLS:
            with self.subTest(missing=missing):
                library = self._old_library()
                available = {name: mock.Mock(return_value=0) for name in self.STATEFUL_SYMBOLS
                             if name != missing}
                for name, function in available.items():
                    setattr(library, name, function)
                module = self._import_with_library(library)
                with module.Reader("stub.ctdb") as reader:
                    self.assertEqual(reader.range("cpu", 20, 20), [(20, 2.5)])
                    with self.assertRaisesRegex(NotImplementedError, "iter_range.*ct_cursor_state"):
                        reader.iter_range("cpu", 10, 20)
                for function in available.values():
                    function.assert_not_called()
                library.ct_cursor_init.assert_not_called()
                library.ct_cursor_next.assert_not_called()


class ClientTest(unittest.TestCase):
    def test_iter_range_across_pages_with_bounded_buffers(self) -> None:
        timestamps = array("q", (3 * i - 10_000 for i in range(9_000)))
        values = array("d", ((i % 17 - 8) / 8 for i in range(9_000)))
        start, end = timestamps[9], timestamps[-14]
        expected = list(zip(timestamps[9:-13], values[9:-13]))
        for codec in ("raw", "compressed"):
            with self.subTest(codec=codec), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "stream.ctdb"
                with chronotail.Writer(path, batch_size=9_000, codec=codec) as writer:
                    writer.append_many("cpu", timestamps, values)
                    writer.checkpoint()
                with chronotail.Reader(path) as reader:
                    self.assertEqual(reader.range("cpu", start, end), expected)
                    for batch_size in (1, 1379):
                        with self.subTest(batch_size=batch_size), mock.patch.object(
                            chronotail._lib, "ct_cursor_state_create",
                            wraps=chronotail._lib.ct_cursor_state_create,
                        ) as create, mock.patch.object(
                            chronotail._lib, "ct_cursor_state_next",
                            wraps=chronotail._lib.ct_cursor_state_next,
                        ) as advance, mock.patch.object(
                            chronotail._lib, "ct_cursor_state_destroy",
                            wraps=chronotail._lib.ct_cursor_state_destroy,
                        ) as destroy, mock.patch.object(
                            chronotail._lib, "ct_range",
                            side_effect=AssertionError("streaming must not materialize a range"),
                        ):
                            self.assertEqual(
                                list(reader.iter_range("cpu", start, end, batch_size=batch_size)),
                                expected,
                            )
                            create.assert_called_once()
                            destroy.assert_called_once()
                            self.assertGreater(advance.call_count, 1)
                            self.assertEqual(
                                {call.args[4] for call in advance.call_args_list}, {batch_size}
                            )
                            for buffer_index in (2, 3):
                                buffers = [
                                    call.args[buffer_index] for call in advance.call_args_list
                                ]
                                self.assertEqual({len(buffer) for buffer in buffers}, {batch_size})
                                self.assertEqual(
                                    len({ctypes.addressof(buffer) for buffer in buffers}), 1
                                )
                    self.assertEqual(list(reader.iter_range("cpu", start, end)), expected)

    def test_iter_range_empty_reversed_and_missing_series(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "empty-stream.ctdb"
            with chronotail.Writer(path) as writer:
                writer.append_many("cpu", [10, 20], [1.0, 2.0])
                writer.checkpoint()
            with chronotail.Reader(path) as reader:
                for start, end in ((11, 19), (21, 30), (20, 10)):
                    with self.subTest(start=start, end=end):
                        self.assertEqual(list(reader.iter_range("cpu", start, end)), [])
                        self.assertEqual(reader.range("cpu", start, end), [])
                self.assertEqual(list(reader.iter_range("cpu", 20, 20)), [(20, 2.0)])
                for start, end in ((10, 20), (20, 10)):
                    with self.subTest(missing=(start, end)), mock.patch.object(
                        chronotail._lib, "ct_cursor_state_destroy",
                        wraps=chronotail._lib.ct_cursor_state_destroy,
                    ) as destroy:
                        with self.assertRaises(chronotail.ChronotailError):
                            list(reader.iter_range("missing", start, end))
                        destroy.assert_not_called()
                        with self.assertRaises(chronotail.ChronotailError):
                            reader.range("missing", start, end)

    def test_iter_range_exact_i64_timestamps_and_float_bits(self) -> None:
        timestamps = [
            -(1 << 63), -(1 << 63) + 1, -1, 0, (1 << 53) + 1,
            (1 << 63) - 2, (1 << 63) - 1,
        ]
        values = [
            -0.0, math.ldexp(1.0, -1074), -1.75, math.inf, -math.inf,
            float.fromhex("0x1.fffffffffffffp+1023"),
            struct.unpack("=d", struct.pack("=Q", 0x7FF8000000000042))[0],
        ]
        expected_bits = [struct.pack("=d", value) for value in values]
        for codec in ("raw", "compressed"):
            with self.subTest(codec=codec), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "exact.ctdb"
                with chronotail.Writer(path, codec=codec) as writer:
                    writer.append_many("cpu", timestamps, values)
                    writer.checkpoint()
                with chronotail.Reader(path) as reader:
                    for batch_size in (1, 3):
                        points = list(reader.iter_range(
                            "cpu", timestamps[0], timestamps[-1], batch_size=batch_size
                        ))
                        self.assertEqual([point[0] for point in points], timestamps)
                        self.assertEqual(
                            [struct.pack("=d", point[1]) for point in points], expected_bits
                        )
                    points = reader.range("cpu", timestamps[0], timestamps[-1])
                    self.assertEqual([point[0] for point in points], timestamps)
                    self.assertEqual(
                        [struct.pack("=d", point[1]) for point in points], expected_bits
                    )
                    for timestamp in (timestamps[0], timestamps[-1]):
                        points = list(reader.iter_range("cpu", timestamp, timestamp, batch_size=1))
                        self.assertEqual([point[0] for point in points], [timestamp])

    def test_iter_range_early_close_releases_cursor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "close-stream.ctdb"
            with chronotail.Writer(path) as writer:
                writer.append_many("cpu", range(10), range(10))
                writer.checkpoint()
            with chronotail.Reader(path) as reader, mock.patch.object(
                chronotail._lib, "ct_cursor_state_create",
                wraps=chronotail._lib.ct_cursor_state_create,
            ) as create, mock.patch.object(
                chronotail._lib, "ct_cursor_state_next",
                wraps=chronotail._lib.ct_cursor_state_next,
            ) as advance, mock.patch.object(
                chronotail._lib, "ct_cursor_state_destroy",
                wraps=chronotail._lib.ct_cursor_state_destroy,
            ) as destroy:
                unopened = reader.iter_range("cpu", 0, 9)
                unopened.close()
                create.assert_not_called()
                destroy.assert_not_called()
                points = reader.iter_range("cpu", 0, 9, batch_size=4)
                create.assert_not_called()
                self.assertEqual(next(points), (0, 0.0))
                points.close()
                points.close()
                create.assert_called_once()
                advance.assert_called_once()
                destroy.assert_called_once()
                with self.assertRaises(StopIteration):
                    next(points)
                self.assertEqual(reader.range("cpu", 9, 9), [(9, 9.0)])

    def test_iter_range_reader_lifetime_rejects_buffered_and_unread_points(self) -> None:
        for action in ("close", "refresh"):
            for batch_size in (1, 4):
                with self.subTest(action=action, batch_size=batch_size), \
                        tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "lifetime.ctdb"
                    with chronotail.Writer(path) as writer:
                        writer.append_many("cpu", range(6), range(6))
                        writer.checkpoint()
                        with chronotail.Reader(path) as reader, mock.patch.object(
                            chronotail._lib, "ct_cursor_state_destroy",
                            wraps=chronotail._lib.ct_cursor_state_destroy,
                        ) as destroy:
                            points = reader.iter_range("cpu", 0, 9, batch_size=batch_size)
                            unstarted = reader.iter_range("cpu", 0, 9)
                            self.assertEqual(next(points), (0, 0.0))
                            if action == "close":
                                reader.close()
                            else:
                                writer.append("cpu", 6, 6.0)
                                writer.checkpoint()
                                self.assertTrue(reader.refresh())
                            with mock.patch.object(
                                chronotail._lib, "ct_cursor_state_next"
                            ) as advance, mock.patch.object(
                                chronotail._lib, "ct_cursor_state_create"
                            ) as create:
                                with self.assertRaisesRegex(
                                    chronotail.ChronotailError,
                                    "closed" if action == "close" else "stale",
                                ):
                                    next(points)
                                with self.assertRaises(chronotail.ChronotailError):
                                    next(unstarted)
                                advance.assert_not_called()
                                create.assert_not_called()
                            destroy.assert_called_once()
                            points.close()
                            destroy.assert_called_once()
                            if action == "close":
                                with self.assertRaises(chronotail.ChronotailError):
                                    reader.iter_range("cpu", 0, 9)
                            else:
                                self.assertEqual(
                                    list(reader.iter_range("cpu", 0, 9)),
                                    [(i, float(i)) for i in range(7)],
                                )

    def test_iter_range_keeps_snapshot_without_changed_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.ctdb"
            with chronotail.Writer(path) as writer:
                writer.append_many("cpu", range(6), range(6))
                writer.checkpoint()
                with chronotail.Reader(path) as reader:
                    points = reader.iter_range("cpu", 0, 9, batch_size=4)
                    self.assertEqual(next(points), (0, 0.0))
                    self.assertFalse(reader.refresh())
                    with mock.patch.object(chronotail._lib, "ct_refresh", return_value=-6):
                        with self.assertRaises(chronotail.ChronotailError):
                            reader.refresh()
                    writer.append("cpu", 6, 6.0)
                    writer.checkpoint()
                    self.assertEqual(list(points), [(i, float(i)) for i in range(1, 6)])
                    self.assertTrue(reader.refresh())
                    self.assertEqual(
                        list(reader.iter_range("cpu", 0, 9)),
                        [(i, float(i)) for i in range(7)],
                    )

    def test_iter_range_native_failure_releases_cursor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "failed-stream.ctdb"
            with chronotail.Writer(path) as writer:
                writer.append_many("cpu", range(6), range(6))
                writer.checkpoint()
            with chronotail.Reader(path) as reader:
                for started in (False, True):
                    with self.subTest(started=started), mock.patch.object(
                        chronotail._lib, "ct_cursor_state_destroy",
                        wraps=chronotail._lib.ct_cursor_state_destroy,
                    ) as destroy:
                        points = reader.iter_range("cpu", 0, 5, batch_size=1)
                        if started:
                            self.assertEqual(next(points), (0, 0.0))
                        with mock.patch.object(
                            chronotail._lib, "ct_cursor_state_next", return_value=-6
                        ):
                            with self.assertRaisesRegex(chronotail.ChronotailError, r"\(-6\)"):
                                next(points)
                        destroy.assert_called_once()
                        points.close()
                        destroy.assert_called_once()
                with mock.patch.object(
                    chronotail._lib, "ct_cursor_state_create", return_value=-6
                ), mock.patch.object(
                    chronotail._lib, "ct_cursor_state_destroy",
                    wraps=chronotail._lib.ct_cursor_state_destroy,
                ) as destroy:
                    with self.assertRaises(chronotail.ChronotailError):
                        next(reader.iter_range("cpu", 0, 5))
                    destroy.assert_not_called()

    def test_iter_range_argument_validation_before_native_calls(self) -> None:
        # No native reader is needed to reject invalid arguments.
        reader = object.__new__(chronotail.Reader)
        with mock.patch.object(chronotail._lib, "ct_cursor_state_create") as create:
            for batch_size in (
                0, -1, 1.5, "1", True, False, None, sys.maxsize // 8 + 1, 1 << 128
            ):
                with self.subTest(batch_size=batch_size), self.assertRaises(ValueError):
                    reader.iter_range("cpu", 0, 1, batch_size=batch_size)
            for bound in (-(1 << 63) - 1, 1 << 63, 1.0, "1", True, None):
                for argument in ("start", "end"):
                    bounds = {"start": 0, "end": 1, argument: bound}
                    with self.subTest(argument=argument, bound=bound), \
                            self.assertRaises(ValueError):
                        reader.iter_range("cpu", **bounds)
            create.assert_not_called()

    def test_writer_reader_and_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.ctdb"
            writer = chronotail.Writer(path, batch_size=2, codec="compressed")
            writer.prepare("cpu", 4)
            writer.append(
                "cpu",
                array("q", [1_000, 1_001, 1_002]),
                array("d", [42.5, 43.5, 44.5]),
            )
            writer.checkpoint(fsync=True)

            reader = chronotail.Reader(path)
            self.assertEqual(
                reader.range("cpu", 1_000, 1_002),
                [(1_000, 42.5), (1_001, 43.5), (1_002, 44.5)],
            )
            summary = reader.aggregate("cpu", 1_000, 1_002)
            self.assertEqual(summary.count, 3)
            self.assertEqual(summary.sum, 130.5)

            writer.append("cpu", 1_003, 45.5)
            writer.checkpoint()
            self.assertTrue(reader.refresh())
            self.assertEqual(reader.range("cpu", 1_003, 1_003), [(1_003, 45.5)])
            self.assertFalse(reader.refresh())

            reader.close()
            reader.close()
            writer.close()
            writer.close()

    def test_validation_and_empty_aggregate(self) -> None:
        with self.assertRaises(ValueError):
            chronotail.Writer("ignored.ctdb", batch_size=0)
        with self.assertRaises(ValueError):
            chronotail.Writer("ignored.ctdb", codec="unknown")

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "empty-range.ctdb"
            with chronotail.Writer(path, codec="raw") as writer:
                with self.assertRaises(ValueError):
                    writer.append_many("cpu", [1, 2], [1.0])
                writer.append("cpu", 1, 1.0)
                writer.checkpoint()
            with chronotail.Reader(path) as reader:
                summary = reader.aggregate("cpu", 2, 3)
                self.assertEqual(summary.count, 0)
                self.assertEqual(summary.sum, 0)
                self.assertTrue(math.isnan(summary.minimum))
                self.assertTrue(math.isnan(summary.last))

    def test_strided_buffers_use_the_iterable_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "strided.ctdb"
            timestamps = memoryview(array("q", [1, 99, 2, 99, 3]))[::2]
            values = memoryview(array("d", [1.5, 99.0, 2.5, 99.0, 3.5]))[::2]
            with chronotail.Writer(path, codec="compressed") as writer:
                writer.append_many("cpu", timestamps, values)
                writer.checkpoint()
            with chronotail.Reader(path) as reader:
                self.assertEqual(
                    reader.range("cpu", 1, 3),
                    [(1, 1.5), (2, 2.5), (3, 3.5)],
                )


class LookupCompatibilityTest(unittest.TestCase):
    _old_library = NativeCompatibilityTest._old_library
    _import_with_library = NativeCompatibilityTest._import_with_library
    OLD_ABI_V2_SYMBOLS = NativeCompatibilityTest.OLD_ABI_V2_SYMBOLS

    def test_lookup_pair_is_optional_independent_of_streaming(self) -> None:
        pair = ("ct_lookup", "ct_lookup_prepared")
        cursors = NativeCompatibilityTest.STATEFUL_SYMBOLS
        for lookup_mask in range(4):
            for cursor_mask in range(8):
                with self.subTest(lookup_mask=lookup_mask, cursor_mask=cursor_mask):
                    library = self._old_library()
                    for mask, names in ((lookup_mask, pair), (cursor_mask, cursors)):
                        for i, name in enumerate(names):
                            if mask & (1 << i):
                                setattr(library, name, mock.Mock(return_value=0))
                    module = self._import_with_library(library)
                    self.assertEqual(module._has_lookup, lookup_mask == 3)
                    self.assertEqual(module._has_stateful_cursor, cursor_mask == 7)
                    with module.Reader("stub") as reader:
                        self.assertEqual(reader.range("cpu", 10, 20), [(10, 1.5), (20, 2.5)])
                        self.assertEqual(reader.aggregate("cpu", 10, 20).count, 2)
                        handle = reader.prepare("cpu")
                        library.ct_prepare_series.assert_called_once()
                        library.ct_range.reset_mock()
                        for call in (lambda: reader.lookup("cpu", 15, module.LookupMode.NEAREST),
                                     lambda: reader.lookup_prepared(handle, 15, module.LookupMode.NEAREST)):
                            if lookup_mask == 3:
                                self.assertIsNone(call())
                            else:
                                with self.assertRaisesRegex(NotImplementedError, "ct_lookup.*ct_lookup_prepared"):
                                    call()
                        library.ct_range.assert_not_called()
                        library.ct_cursor_init.assert_not_called()
                        library.ct_cursor_next.assert_not_called()
                        for name in cursors:
                            if hasattr(library, name):
                                getattr(library, name).assert_not_called()
                        if lookup_mask != 3:
                            for name in pair:
                                if hasattr(library, name):
                                    getattr(library, name).assert_not_called()

    def test_domains_lifetimes_and_missing_capability_order(self) -> None:
        library = self._old_library()
        module = self._import_with_library(library)
        with module.Reader("stub") as reader, module.Reader("stub") as foreign:
            handle = reader.prepare("cpu")
            with self.assertRaisesRegex(TypeError, "Reader.prepare"):
                module.SeriesHandle()
            for invalid in (0, 1, True, 4, "nearest", None):
                with self.subTest(mode=invalid), self.assertRaises(ValueError):
                    reader.lookup("cpu", 0, invalid)
            for invalid in (-(1 << 63) - 1, 1 << 63, True, False, 1.0, "1", None):
                with self.subTest(timestamp=invalid), self.assertRaises(ValueError):
                    reader.lookup("cpu", invalid, module.LookupMode.EXACT)
            for invalid in (-1, 1 << 64, True, False, 1.0, "1"):
                with self.subTest(limit=invalid), self.assertRaises(ValueError):
                    reader.lookup_prepared(handle, 0, module.LookupMode.EXACT, max_distance=invalid)
            with self.assertRaises(ValueError):
                reader.lookup_prepared("cpu", 0, module.LookupMode.EXACT)
            with self.assertRaisesRegex(module.ChronotailError, "different reader"):
                foreign.lookup_prepared(handle, 0, module.LookupMode.EXACT, max_distance=0)
            self.assertFalse(reader.refresh())
            with self.assertRaises(NotImplementedError):
                reader.lookup_prepared(handle, 0, module.LookupMode.EXACT)
            library.ct_refresh.return_value = -6
            with self.assertRaises(module.ChronotailError):
                reader.refresh()
            with self.assertRaises(NotImplementedError):
                reader.lookup_prepared(handle, 0, module.LookupMode.EXACT)
            def changed(native, out):
                out._obj.value = 1
                return 0
            library.ct_refresh.side_effect = changed
            self.assertTrue(reader.refresh())
            with self.assertRaisesRegex(module.ChronotailError, "stale"):
                reader.lookup_prepared(handle, 0, module.LookupMode.EXACT, max_distance=0)
            reader.close()
            with self.assertRaisesRegex(module.ChronotailError, "closed"):
                reader.lookup("cpu", 0, module.LookupMode.EXACT)
            with self.assertRaisesRegex(module.ChronotailError, "closed"):
                reader.lookup_prepared(handle, 0, module.LookupMode.EXACT)

    def test_full_domain_arguments_and_found_bits(self) -> None:
        library = self._old_library()
        library.ct_lookup = mock.Mock(return_value=0)
        library.ct_lookup_prepared = mock.Mock(return_value=0)
        module = self._import_with_library(library)
        self.assertEqual(ctypes.sizeof(module._CPoint), 16)
        self.assertEqual(ctypes.alignment(module._CPoint), 8)
        self.assertEqual((module._CPoint.timestamp.offset, module._CPoint.value.offset), (0, 8))
        self.assertEqual(ctypes.sizeof(module._CSeriesHandle), 16)
        self.assertEqual((module._CSeriesHandle.index.offset, module._CSeriesHandle.reserved.offset,
                          module._CSeriesHandle.generation.offset), (0, 4, 8))
        with module.Reader("stub") as reader:
            handle = reader.prepare("cpu")
            for target in (-(1 << 63), (1 << 63) - 1):
                for limit in (None, 0, (1 << 63), (1 << 64) - 1):
                    for bits in (0, 0x8000000000000000, 1, 0x7ff8000000000123):
                        def lookup(*args):
                            timestamp, mode, has_limit, distance, out, found = args[-6:]
                            self.assertEqual(timestamp, target)
                            self.assertEqual(mode, module.LookupMode.NEAREST.value)
                            self.assertEqual(has_limit, int(limit is not None))
                            self.assertEqual(distance, 0 if limit is None else limit)
                            out._obj.timestamp = target
                            out._obj.value = struct.unpack("=d", struct.pack("=Q", bits))[0]
                            found._obj.value = 1
                            return 0
                        library.ct_lookup.side_effect = lookup
                        library.ct_lookup_prepared.side_effect = lookup
                        for point in (reader.lookup("cpu", target, module.LookupMode.NEAREST, max_distance=limit),
                                      reader.lookup_prepared(handle, target, module.LookupMode.NEAREST, max_distance=limit)):
                            self.assertEqual(point[0], target)
                            self.assertEqual(struct.unpack("=Q", struct.pack("=d", point[1]))[0], bits)

    def test_missing_and_error_do_not_read_point(self) -> None:
        library = self._old_library()
        library.ct_lookup = mock.Mock(return_value=0)
        library.ct_lookup_prepared = mock.Mock(return_value=0)
        module = self._import_with_library(library)
        class UnreadablePoint(module._CPoint):
            def __getattribute__(self, name):
                if name in ("timestamp", "value"):
                    raise AssertionError("missing/error point was inspected")
                return super().__getattribute__(name)
        with module.Reader("stub") as reader:
            handle = reader.prepare("cpu")
            with mock.patch.object(module, "_CPoint", UnreadablePoint):
                for code in (0, -6):
                    library.ct_lookup.return_value = code
                    library.ct_lookup_prepared.return_value = code
                    def fail(*args):
                        args[-1]._obj.value = 1  # Status must take precedence over found.
                        return -6
                    library.ct_lookup.side_effect = fail if code < 0 else None
                    library.ct_lookup_prepared.side_effect = fail if code < 0 else None
                    for call in (lambda: reader.lookup("cpu", 0, module.LookupMode.EXACT),
                                 lambda: reader.lookup_prepared(handle, 0, module.LookupMode.EXACT)):
                        if code == 0:
                            self.assertIsNone(call())
                        else:
                            with self.assertRaises(module.ChronotailError):
                                call()


def _reference_lookup(points, target, mode, limit):
    candidates = [(timestamp, bits) for timestamp, bits in points
                  if (mode != chronotail.LookupMode.EXACT or timestamp == target)
                  and (mode != chronotail.LookupMode.PREDECESSOR or timestamp <= target)
                  and (mode != chronotail.LookupMode.SUCCESSOR or timestamp >= target)]
    if not candidates:
        return None
    point = min(candidates, key=lambda p: (abs(p[0] - target), p[0]))
    return None if limit is not None and abs(point[0] - target) > limit else point


class TemporalLookupTest(unittest.TestCase):
    def assertPoint(self, actual, expected):
        if expected is None:
            self.assertIsNone(actual)
        else:
            self.assertIsNotNone(actual)
            self.assertEqual(actual[0], expected[0])
            self.assertEqual(struct.unpack("=Q", struct.pack("=d", actual[1]))[0], expected[1])

    def test_sorted_reference_modes_bits_limits_and_index_boundaries(self) -> None:
        times = [-(1 << 63), -(1 << 63) + 1, -31, -10, 0, 10, 47, (1 << 63) - 2, (1 << 63) - 1]
        bits = [0, 0x8000000000000000, 1, 0x7ff0000000000000, 0xfff0000000000000,
                0x7ff8000000000123, 0xfff8000000000456, 0x3ff0000000000000, 0x7fefffffffffffff]
        values = [struct.unpack("=d", struct.pack("=Q", b))[0] for b in bits]
        signal = list(zip(times, bits))
        many_times = [i * 11 - 500 for i in range(132)]
        many = [(t, struct.unpack("=Q", struct.pack("=d", float(i)))[0]) for i, t in enumerate(many_times)]
        for codec in ("raw", "compressed"):
            with self.subTest(codec=codec), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "lookup.ctdb"
                with chronotail.Writer(path, codec=codec, batch_size=200) as writer:
                    writer.append_many("signal", times, values)
                    writer.append_many("single", times[:1], values[:1])
                    # 44 committed pages force a non-leaf root for both encodings.
                    for offset in range(0, 132, 3):
                        writer.append_many("pages", many_times[offset:offset+3], [float(i) for i in range(offset, offset+3)])
                        writer.checkpoint()
                    with chronotail.Reader(path) as reader:
                        targets = [-(1 << 63), -(1 << 63) + 2, -32, -31, -20, -11, -10, -5, 0, 5, 11, 46, 48, (1 << 63) - 1]
                        for name, points, queries in (("signal", signal, targets),
                                ("single", signal[:1], [(1 << 63) - 1]),
                                ("pages", many, [t + d for t in many_times[::3] for d in (-1, 0)])):
                            prepared = reader.prepare(name)
                            for target in queries:
                                for mode in chronotail.LookupMode:
                                    selected = _reference_lookup(points, target, mode, None)
                                    limits = {None, 0, 1, (1 << 64) - 1, (1 << 64) - 2, 1 << 63}
                                    if selected is not None:
                                        distance = abs(selected[0] - target)
                                        limits.update(x for x in (distance-1, distance, distance+1) if 0 <= x < (1 << 64))
                                    for limit in limits:
                                        expected = _reference_lookup(points, target, mode, limit)
                                        self.assertPoint(reader.lookup(name, target, mode, max_distance=limit), expected)
                                        self.assertPoint(reader.lookup_prepared(prepared, target, mode, max_distance=limit), expected)
                        prepared = reader.prepare("signal")
                        self.assertFalse(reader.refresh())
                        copied = reader.lookup_prepared(prepared, times[0], chronotail.LookupMode.EXACT)
                        with chronotail.Reader(path) as foreign:
                            with self.assertRaisesRegex(chronotail.ChronotailError, "different reader"):
                                foreign.lookup_prepared(prepared, 0, chronotail.LookupMode.EXACT)
                        with self.assertRaises(chronotail.ChronotailError):
                            reader.lookup("unknown", 0, chronotail.LookupMode.EXACT, max_distance=0)
                        writer.append("pages", many_times[-1] + 11, 0.0)
                        writer.checkpoint()
                        self.assertTrue(reader.refresh())
                        with self.assertRaisesRegex(chronotail.ChronotailError, "stale"):
                            reader.lookup_prepared(prepared, 0, chronotail.LookupMode.EXACT, max_distance=0)
                        self.assertEqual(reader.lookup("pages", many_times[-1] + 11, chronotail.LookupMode.EXACT, max_distance=0), (many_times[-1] + 11, 0.0))
                    self.assertPoint(copied, signal[0])
                    with self.assertRaisesRegex(chronotail.ChronotailError, "closed"):
                        reader.lookup("signal", 0, chronotail.LookupMode.NEAREST)


if __name__ == "__main__":
    unittest.main()
