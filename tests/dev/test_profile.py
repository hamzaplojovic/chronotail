"""Synthetic format-1 evidence tests; no engine builds or benchmarks required."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "check-profile.py"
SPEC = importlib.util.spec_from_file_location("check_profile", SCRIPT)
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


def metadata(repetitions=1, points=100_000, **changes):
    row = dict(type="metadata", format=1, engine_format=7, zig="0.15.2",
               os="macos", arch="aarch64", points=points, repetitions=repetitions,
               quick=False)
    row.update(changes)
    return row


def result(group="query", name="range", **changes):
    row = dict(
        type="result", group=group, name=name, codec="raw", timestamp_pattern="none",
        value_pattern="none", series_count=0, batch_size=0, width=0,
        operations=1_000, points=100_000, elapsed_ns=2_000_000,
        operations_per_second=500_000.0, points_per_second=50_000_000.0,
        p50_ns=0, p95_ns=0, p99_ns=0, max_ns=0, file_size=0, bytes_per_point=0.0,
        raw_blocks=0, compressed_blocks=0, allocation_calls=0, resize_calls=0,
        remap_calls=0, free_calls=0, allocated_bytes=0, live_bytes=0,
        peak_live_bytes=0, detail_a=0, detail_b=0,
    )
    row.update(changes)
    return row


def allocation(name="prepared-query", **changes):
    # The allocator resets activity but retains dataset/reader setup memory.
    row = result("allocation", name, operations=10_000, points=1_000_000,
                 elapsed_ns=0, operations_per_second=0.0, points_per_second=0.0,
                 live_bytes=2_162_688, peak_live_bytes=2_162_688)
    row.update(changes)
    return row


def control_matrix():
    rows = [result("control-plane", name, codec=codec,
                   series_count=series_count, operations=50, elapsed_ns=0,
                   operations_per_second=0.0, points_per_second=0.0, points=0,
                   p50_ns=80_000, p95_ns=110_000, p99_ns=115_000, max_ns=120_000)
            for name, codec, series_count in (
                ("reader-open", "compressed", 0),
                ("reader-open-many-series", "raw", 1_024),
                ("appender-open-many-series", "raw", 1_024),
                ("checkpoint-one-of-many-series", "raw", 1_024),
            )]
    rows += [result("control-plane", name, codec="none", points=0)
             for name in ("refresh-unchanged", "refresh-changed")]
    rows += [result("control-plane", "verify", codec=codec)
             for codec in ("raw", "compressed")]
    rows += [result("control-plane", "recover-trailing-data", codec="none", points=0,
                    detail_a=size) for size in (65_536, 1_048_576, 16_777_216)]
    return rows


def query_matrix(points=100_000):
    rows = []
    for timestamp, value in (("dense", "smooth"), ("dense", "random"),
                             ("sparse", "spiky"), ("irregular", "smooth")):
        for codec in ("raw", "compressed"):
            identity = dict(codec=codec, timestamp_pattern=timestamp, value_pattern=value)
            rows.append(result("query-profile", "first-touch", **identity, width=100,
                               operations=0, points=0, elapsed_ns=0,
                               operations_per_second=0.0, points_per_second=0.0,
                               detail_a=10_500, detail_b=350))
            rows += [result(**identity, width=min(width, points))
                     for width in (1, 10, 100, 1_000, 10_000, 100_000)]
            rows.append(result(name="range-count-only", **identity, width=100))
            rows.append(result(name="full-scan-count", **identity, width=points))
    return rows


def full_matrix(points=100_000, quick=False):
    """Realistic current harness identities, generated independently of validator tables."""
    rows = []
    for codec in ("raw", "compressed"):
        rows += [result("append", "batch", codec=codec, timestamp_pattern="dense",
                        value_pattern="smooth", series_count=1, batch_size=size)
                 for size in (1, 16, 64, 256, 1_000, 4_088, 4_096, 65_536)]
    for timestamp in ("dense", "sparse", "irregular"):
        for value in ("constant", "smooth", "spiky", "random"):
            identity = dict(timestamp_pattern=timestamp, value_pattern=value)
            rows.append(result("append", "pattern", codec="compressed", **identity,
                               series_count=1, batch_size=points if quick else min(points, 500_000)))
            rows += [result("storage", "encoding", codec=codec, **identity,
                            operations=0, elapsed_ns=0, operations_per_second=0.0,
                            points_per_second=0.0, file_size=1_620_000,
                            bytes_per_point=16.2, raw_blocks=25)
                     for codec in ("raw", "compressed")]
    for count in (1, 4, 8, 64, 256):
        rows.append(result("append", "series-cardinality", series_count=count, batch_size=1))
        rows += [result(name=name, series_count=count, width=1)
                 for name in ("series-lookup-point", "prepared-series-point")]
    rows += query_matrix(points)
    for codec in ("raw", "compressed"):
        rows += [result(name="cursor-full-range", codec=codec, batch_size=size)
                 for size in (16, 128, 1_024, 4_096)]
        rows += [result(name=name, codec=codec)
                 for name in ("range-into-count-only", "text-full-range")]
        rows += [result("aggregate", "summary-tree", codec=codec, width=min(width, points))
                 for width in (100, 10_000, points)]
        rows.append(result("aggregate", "resolution-windows", codec=codec, width=points // 10))
        rows.append(result("checkpoint", "unsynced", codec=codec, batch_size=256 if quick else 4_096))
    rows.append(result(name="borrow-raw-page", points=0))
    rows.append(result("checkpoint", "fsync", batch_size=256 if quick else 4_096))
    rows += control_matrix()
    rows += [allocation(name) for name in (
        "append-after-create", "warm-query", "prepared-query", "persistent-cursor",
        "borrow-raw-page", "aggregate-summary", "aggregate-windows", "unchanged-refresh",
    )]
    rows += [result("concurrency", "parallel-readers", series_count=count, width=100)
             for count in (1, 2, 4, 8, 16, 32)]
    return rows


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "profile.jsonl"

    def write(self, rows):
        self.path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        return self.path

    def invalid(self, rows, message, **options):
        self.write(rows)
        with self.assertRaisesRegex(profile.ValidationError, message):
            profile.validate(self.path, **options)

    def test_complete_current_matrix_three_repetitions(self):
        rows = full_matrix(1_000_000)
        self.assertEqual(len(rows), 188)
        self.write([metadata(3, points=1_000_000), *rows, *rows, *rows])
        summary = profile.validate(self.path)
        self.assertEqual(summary, profile.Summary(564, 188, 24, True))

    def test_quick_complete_matrix(self):
        self.write([metadata(quick=True), *full_matrix(quick=True)])
        self.assertTrue(profile.validate(self.path).completeness_checked)

    def test_combined_quick_repetitions_from_profile_pair(self):
        rows = full_matrix(quick=True)
        self.write([metadata(3, quick=True), *rows, *rows, *rows])
        self.assertEqual(profile.validate(self.path), profile.Summary(564, 188, 24, True))
        self.invalid([metadata(3, quick=True), *rows, *rows], "incomplete matrix")

    def test_metadata_is_required_by_default_even_for_complete_results(self):
        self.invalid([allocation()], "missing harness metadata")
        self.invalid(full_matrix(), "missing harness metadata")

    def test_exploratory_partial_validation_requires_explicit_opt_in(self):
        rows = full_matrix()
        for records in ([allocation()], [metadata(), *rows[:-1]],
                        [metadata(3), *rows, *rows]):
            with self.subTest(results=len(records)):
                self.write(records)
                self.assertFalse(profile.validate(self.path, allow_partial=True).completeness_checked)
        self.invalid([allocation(free_calls=1)], "allocator activity", allow_partial=True)
        self.invalid([allocation(points_per_second=float("nan"))], "nonfinite", allow_partial=True)
        self.invalid([metadata(format=2), allocation()], "unsupported", allow_partial=True)
        self.invalid([allocation()], "cannot be combined", only="control", allow_partial=True)

    def test_allocation_allows_retained_setup_memory(self):
        self.write([allocation()])
        summary = profile.validate(self.path, allow_partial=True)
        self.assertEqual(summary.allocation_results, 1)
        self.assertFalse(summary.completeness_checked)

    def test_each_allocator_activity_field_is_a_regression(self):
        for field in ("allocation_calls", "resize_calls", "remap_calls", "free_calls", "allocated_bytes"):
            with self.subTest(field=field):
                self.invalid([allocation(**{field: 1})], field + "=1")

    def test_peak_growth_without_reported_calls_is_rejected(self):
        self.invalid([allocation(peak_live_bytes=2_162_689)], "allocator activity")
        self.invalid([allocation(peak_live_bytes=1)], "below live_bytes")

    def test_no_operations_is_not_allocation_evidence(self):
        self.invalid([allocation(operations=0)], "no operations")

    def test_missing_empty_and_metadata_only_files(self):
        with self.assertRaisesRegex(profile.ValidationError, "profile.jsonl"):
            profile.validate(self.path)
        self.invalid([], "no result records")
        self.invalid([metadata()], "no result records")
        self.path.write_text("\n", encoding="utf-8")
        with self.assertRaisesRegex(profile.ValidationError, ":1: empty JSONL"):
            profile.validate(self.path)

    def test_truncation_invalid_json_and_invalid_utf8(self):
        for contents in (b'{"type":"result"', json.dumps(allocation()).encode(), b'\xff\n', b'{oops}\n'):
            with self.subTest(contents=contents[:20]):
                self.path.write_bytes(contents)
                with self.assertRaises(profile.ValidationError):
                    profile.validate(self.path)

    def test_complete_json_row_truncation_and_missing_whole_phase(self):
        rows = full_matrix()
        self.invalid([metadata(), *rows[:-1]], "incomplete matrix")
        self.invalid([metadata(), *(row for row in rows if row["group"] != "allocation")],
                     "incomplete matrix")
        self.invalid([metadata(3), *rows, *rows], "incomplete matrix")

    def test_duplicate_workload_cannot_replace_a_missing_sample(self):
        rows = control_matrix()
        rows[-1] = rows[-2]
        self.invalid([metadata(only="control"), *rows], "repetitions")

    def test_required_scalar_append_cannot_be_replaced_by_unexpected_batch(self):
        rows = full_matrix()
        scalar = next(row for row in rows if row["group"] == "append"
                      and row["name"] == "batch" and row["codec"] == "raw"
                      and row["batch_size"] == 1)
        scalar["batch_size"] = 2
        self.assertEqual(len(rows), 188)
        self.invalid([metadata(), *rows], "incomplete matrix")

    def test_same_count_replacements_must_match_exact_workload_keys(self):
        cases = (
            ("append", "batch", "codec", "none"),
            ("append", "batch", "timestamp_pattern", "sparse"),
            ("append", "batch", "value_pattern", "constant"),
            ("append", "batch", "series_count", 2),
            ("append", "batch", "batch_size", 4_093),
            ("append", "pattern", "codec", "raw"),
            ("append", "pattern", "batch_size", 50_000),
            ("append", "series-cardinality", "series_count", 2),
            ("storage", "encoding", "codec", "none"),
            ("query", "series-lookup-point", "series_count", 2),
            ("query", "range", "timestamp_pattern", "none"),
            ("query", "range", "width", 2),
            ("query", "cursor-full-range", "batch_size", 32),
            ("aggregate", "resolution-windows", "width", 999),
            ("checkpoint", "fsync", "batch_size", 256),
            ("control-plane", "reader-open-many-series", "series_count", 2_048),
            ("control-plane", "recover-trailing-data", "detail_a", 262_144),
            ("allocation", "prepared-query", "codec", "compressed"),
            ("concurrency", "parallel-readers", "series_count", 3),
        )
        for group, name, field, replacement in cases:
            with self.subTest(group=group, name=name, field=field):
                rows = full_matrix()
                row = next(row for row in rows if (row["group"], row["name"]) == (group, name))
                row[field] = replacement
                self.assertEqual(len(rows), 188)
                self.invalid([metadata(), *rows], "incomplete matrix")

    def test_geometry_and_quick_checkpoint_identities_are_required(self):
        rows = full_matrix()
        page_batch = next(row for row in rows if row["group"] == "append"
                          and row["name"] == "batch" and row["codec"] == "raw"
                          and row["batch_size"] == 4_088)
        page_batch["batch_size"] = 4_093
        self.invalid([metadata(), *rows], "incomplete matrix")
        rows = full_matrix(quick=True)
        checkpoint = next(row for row in rows if row["group"] == "checkpoint")
        checkpoint["batch_size"] = 4_096
        self.invalid([metadata(quick=True), *rows], "incomplete matrix")

    def test_unknown_geometry_requires_exploratory_opt_in(self):
        self.invalid([metadata(engine_format=8), *full_matrix()], "known format-v7 geometry")
        self.assertFalse(profile.validate(self.path, allow_partial=True).completeness_checked)

    def test_recovery_tail_sizes_are_distinct_identities(self):
        rows = control_matrix()
        self.write([metadata(3, only="control"), *rows, *rows, *rows])
        self.assertEqual(profile.validate(self.path).workloads, 11)

    def test_small_points_width_collisions_are_legitimate_repetitions(self):
        self.write([metadata(2, points=10_000, only="query"),
                    *query_matrix(10_000), *query_matrix(10_000)])
        self.assertEqual(profile.validate(self.path).workloads, 64)
        self.write([metadata(points=10_000), *full_matrix(10_000)])
        self.assertEqual(profile.validate(self.path).results, 188)

    def test_colliding_width_samples_cannot_be_replaced_by_other_known_width(self):
        rows = query_matrix(10_000)
        row = next(row for row in rows if row["name"] == "range" and row["width"] == 10_000)
        row["width"] = 1_000
        self.invalid([metadata(points=10_000, only="query"), *rows], "incomplete matrix")

    def test_point_dependent_matrices_between_and_above_width_boundaries(self):
        for points in (10_001, 50_000, 500_000, 1_000_001):
            with self.subTest(points=points):
                rows = full_matrix(points)
                self.write([metadata(2, points=points), *rows, *rows])
                self.assertEqual(profile.validate(self.path).results, 376)

    def test_old_partial_metadata_requires_only(self):
        self.write([metadata(), *control_matrix()])
        self.assertEqual(profile.validate(self.path, only="control").results, 11)
        with self.assertRaisesRegex(profile.ValidationError, "incomplete matrix"):
            profile.validate(self.path)

    def test_all_partial_harness_phases_and_read_api_metadata_alias(self):
        rows = full_matrix()
        selectors = {
            "append": lambda row: row["group"] == "append",
            "checkpoint": lambda row: row["group"] == "checkpoint",
            "control": lambda row: row["group"] == "control-plane",
            "query": lambda row: row["name"] in
            ("first-touch", "range", "range-count-only", "full-scan-count"),
            "read-api": lambda row: row["group"] == "query" and row["name"] in
            ("cursor-full-range", "range-into-count-only", "text-full-range", "borrow-raw-page"),
            "lookup": lambda row: row["name"] in ("series-lookup-point", "prepared-series-point"),
        }
        for phase, select in selectors.items():
            with self.subTest(phase=phase):
                selected = [row for row in rows if select(row)]
                self.write([metadata(2, only=phase), *selected, *selected])
                self.assertEqual(profile.validate(self.path).results, 2 * len(selected))
                self.invalid([metadata(2, only=phase), *selected, *selected[:-1]], "incomplete")
        self.write([metadata(only="read_api"), *(row for row in rows if selectors["read-api"](row))])
        self.assertEqual(profile.validate(self.path, only="read-api").results, 13)

    def test_only_conflict_and_invalid_metadata(self):
        self.invalid([metadata(only="control"), *control_matrix()], "conflicts", only="query")
        for changes in (dict(repetitions=0), dict(repetitions=True), dict(points=1),
                        dict(format=2), dict(quick="true"), dict(quick=True, points=10_000),
                        dict(only=[]), dict(expected_results=False)):
            with self.subTest(changes=changes):
                self.invalid([metadata(**changes), allocation()], ":1:")

    def test_expected_metadata_totals(self):
        rows = control_matrix()
        self.write([metadata(2, only="control", expected_results=22, expected_workloads=11), *rows, *rows])
        self.assertEqual(profile.validate(self.path).results, 22)
        for changes in (dict(expected_results=21), dict(expected_workloads=10)):
            with self.subTest(changes=changes):
                self.invalid([metadata(only="control", **changes), *rows], "expected_")

    def test_missing_and_badly_typed_required_fields(self):
        for field in tuple(allocation()):
            with self.subTest(missing=field):
                row = allocation()
                del row[field]
                self.invalid([row], "record type|must be")
        for field in ("operations", "allocation_calls", "allocated_bytes", "points_per_second"):
            for value in (True, "0", None, -1):
                with self.subTest(field=field, value=value):
                    self.invalid([allocation(**{field: value})], "must be")
        self.invalid([allocation(free_calls=1 << 64)], "must be")
        self.invalid([allocation(points_per_second=10 ** 400)], "finite")

    def test_nonfinite_constants_exponents_and_extensions(self):
        for value in (float("nan"), float("inf"), float("-inf")):
            self.invalid([allocation(points_per_second=value)], "nonfinite")
            self.invalid([allocation(extra={"nested": [value]})], "nonfinite")
        self.path.write_text(json.dumps(allocation()).replace('"points_per_second": 0.0',
                                                              '"points_per_second": 1e999') + "\n")
        with self.assertRaisesRegex(profile.ValidationError, "nonfinite"):
            profile.validate(self.path)

    def test_duplicate_keys_non_objects_unknown_types_and_metadata_order(self):
        self.path.write_text(json.dumps(allocation())[:-1] + ', "free_calls": 0}\n')
        with self.assertRaisesRegex(profile.ValidationError, "duplicate JSON key"):
            profile.validate(self.path)
        for row in (None, [], 10, {"type": "complete"}):
            self.invalid([row], "record")
        self.invalid([metadata(), metadata(), allocation()], "once")
        self.invalid([allocation(), metadata()], "before results")

    def test_invalid_measurements_and_identifiers(self):
        self.invalid([result(p50_ns=10, p95_ns=5)], "percentiles")
        self.invalid([result(operations=0)], "no measured")
        self.invalid([result(elapsed_ns=0)], "no measured")
        self.invalid([result("storage", "encoding")], "no measured data")
        self.invalid([result("query-profile", "first-touch")], "no measurements")
        self.invalid([result(codec="unknown")], "unknown codec")
        self.invalid([allocation(name="typo")], "unknown workload")

    def test_no_performance_thresholds(self):
        self.write([result(elapsed_ns=1 << 60, operations_per_second=0.0, points_per_second=0.0)])
        self.assertEqual(profile.validate(self.path, allow_partial=True).results, 1)

    def test_cli_help_success_errors_and_multiple_paths(self):
        help_result = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--only", help_result.stdout)
        self.assertIn("--allow-partial", help_result.stdout)
        self.assertIn("No speed, latency, or storage thresholds", help_result.stdout)
        self.write([metadata(only="control"), *control_matrix()])
        original = self.path.read_bytes()
        success = subprocess.run([sys.executable, str(SCRIPT), str(self.path)], capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertIn("complete matrix", success.stdout)
        self.assertEqual(self.path.read_bytes(), original)
        failure = subprocess.run([sys.executable, str(SCRIPT), str(self.path),
                                  str(self.path.with_name("missing.jsonl"))], capture_output=True, text=True)
        self.assertEqual(failure.returncode, 1)
        self.assertIn("error:", failure.stderr)
        usage = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(usage.returncode, 2)
        self.write([allocation()])
        standalone = subprocess.run([sys.executable, str(SCRIPT), str(self.path)],
                                    capture_output=True, text=True)
        self.assertEqual(standalone.returncode, 1)
        self.assertIn("missing harness metadata", standalone.stderr)
        exploratory = subprocess.run([sys.executable, str(SCRIPT), "--allow-partial", str(self.path)],
                                     capture_output=True, text=True)
        self.assertEqual(exploratory.returncode, 0, exploratory.stderr)
        self.assertIn("completeness unverified: --allow-partial", exploratory.stdout)
        self.write([allocation(free_calls=1)])
        regression = subprocess.run([sys.executable, str(SCRIPT), "--allow-partial", str(self.path)],
                                    capture_output=True, text=True)
        self.assertEqual(regression.returncode, 1)
        self.assertIn("allocator activity", regression.stderr)


if __name__ == "__main__":
    unittest.main()
