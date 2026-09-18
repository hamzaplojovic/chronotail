from __future__ import annotations

import math
import tempfile
import unittest
from array import array
from pathlib import Path

import chronotail


class ClientTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
