"""Archive corruption and process-fake checks; never pip/native/compiler/Go."""

import argparse
import base64
import contextlib
import csv
import hashlib
import importlib.metadata
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("old_abi_gate", ROOT / "scripts/check-old-abi.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def native_bytes(kind):
    # Synthetic header-only fixture, never loadable/executed native evidence.
    return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, kind, 1, 8, 0, 0) + b"\0" * 8


def wheel_bytes(version, native, *, bad_record=False, wrong_native=False, dependencies=False):
    info = f"chronotail-{version}.dist-info"
    files = {
        "chronotail/__init__.py": b"ABI_VERSION = 2\n# synthetic installed package; no native import\n",
        "chronotail/_native/libchronotail.dylib": native + (b"wrong" if wrong_native else b""),
        info + "/METADATA": (f"Metadata-Version: 2.1\nName: chronotail\nVersion: {version}\n"
                             + ("Requires-Dist: external-package\n" if dependencies else "")).encode(),
        info + "/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: false\nTag: py3-none-macosx_11_0_arm64\n",
    }
    rows = [[name, "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode(), str(len(data))]
            for name, data in files.items()]
    if bad_record:
        rows[0][1] = "sha256=invalid"
    rows.append([info + "/RECORD", "", ""])
    record = io.StringIO()
    csv.writer(record, lineterminator="\n").writerows(rows)
    files[info + "/RECORD"] = record.getvalue().encode()
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return result.getvalue()


def bundle_files(version, **wheel_options):
    native = native_bytes(6) + version.encode()
    files = {
        "bin/chronotail": native_bytes(2), "lib/libchronotail.a": b"!<arch>\n",
        "lib/libchronotail.dylib": native, "include/chronotail.h": b"uint32_t ct_abi_version(void);\n",
        f"python/chronotail-{version}-py3-none-macosx_11_0_arm64.whl": wheel_bytes(version, native, **wheel_options),
        "RELEASE_NOTES.md": f"# Chronotail {version}\n".encode(),
        "go.mod": b"module example.test/chronotail\n\ngo 1.24\n",
        "clients/go/native.go": b"package chronotail\n// synthetic packaged source, not built\n",
        "clients/go/cmd/smoke/main.go": b"package main\n// synthetic source, not built\n",
    }
    files["SHA256SUMS"] = "".join(f"{digest(files[name])}  {name}\n" for name in sorted(files) if name.startswith(("bin/", "lib/", "include/", "python/"))).encode()
    return files


def write_bundle(root, version, files=None, extra=()):
    files = bundle_files(version) if files is None else files
    archive = root / f"chronotail-{version}-macos-aarch64.tar.gz"
    with tarfile.open(archive, "w:gz") as target:
        for name, data in files.items():
            entry = tarfile.TarInfo("chronotail/" + name)
            entry.size = len(data)
            target.addfile(entry, io.BytesIO(data))
        for entry in extra:
            target.addfile(entry, io.BytesIO(b"x" * entry.size) if entry.isfile() else None)
    return archive, GATE.sha256(archive)


def provenance(old):
    return {
        "schema_version": 1, "record_type": "chronotail.released-old-native.static-verification", "finalized": True,
        "release": {"repository": "hamzaplojovic/chronotail", "tag": "v2.0.0", "url": GATE.RELEASE_URL,
                    "source_commit_sha": GATE.OLD_SOURCE, "annotated_tag_object_sha": "a2c5dd49634a80ee10ac656f84039dd30140e723",
                    "published_at": "2026-09-17T19:36:13Z"},
        "bundle": {"id": 570951630, "name": Path(old["archive"]).name,
                   "size": Path(old["archive"]).stat().st_size, "sha256": old["archive_sha256"],
                   "digest": "sha256:" + old["archive_sha256"],
                   "browser_download_url": GATE.RELEASE_URL.replace("/tag/", "/download/") + "/" + Path(old["archive"]).name},
        "critical_members_sha256": old["checked_internal_sha256"],
        "native": {"sha256": old["native_sha256"], "ct_exports": GATE.OLD_SYMBOLS, "ct_export_count": 18,
                   "architecture": "ARM64", "thin_macho": True, "filetype": 6, "ABI_version_source_and_instruction_inspection": 2},
        "header": {"sha256": old["header_sha256"], "matches_tagged_source": True},
        "wheel": {"version": "2.0.0", "tag": old["wheel_info"]["tag"], "native_sha256": old["native_sha256"],
                  "python_source_sha256": old["wheel_info"]["python_sha256"], "RECORD_verified": True},
        "checks": {"GitHub_asset_digests_and_outer_SHA256SUMS": True},
    }


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)


class ArchiveTests(FixtureCase):
    def verify(self, files=None, extra=(), pin=None):
        archive, sha = write_bundle(self.root, "2.0.0", files, extra)
        return GATE.verify_bundle(archive, sha if pin is None else pin, "2.0.0", self.root / "extracted")

    def test_valid_internal_and_wheel_identity(self):
        old = self.verify()
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps(provenance(old)))
        observed = GATE.verify_old_provenance(receipt, old)
        self.assertEqual(observed["source_commit"], GATE.OLD_SOURCE)
        self.assertEqual(old["wheel_info"]["native_sha256"], old["native_sha256"])

    def test_outer_hash_mismatch_precedes_extraction(self):
        with self.assertRaisesRegex(GATE.GateError, "outer bundle SHA256 mismatch"):
            self.verify(pin="0" * 64)
        self.assertFalse((self.root / "extracted").exists())

    def test_changed_member_with_re_pinned_outer_fails_internal_checksum(self):
        files = bundle_files("2.0.0")
        files["lib/libchronotail.dylib"] += b"corruption"
        with self.assertRaisesRegex(GATE.GateError, "internal checksum mismatch"):
            self.verify(files)

    def test_missing_critical_checksum_is_not_self_validating(self):
        files = bundle_files("2.0.0")
        files["SHA256SUMS"] = b""
        with self.assertRaisesRegex(GATE.GateError, "missing critical"):
            self.verify(files)

    def test_bad_record_rejected_despite_outer_and_internal_validity(self):
        with self.assertRaisesRegex(GATE.GateError, "wheel RECORD mismatch"):
            self.verify(bundle_files("2.0.0", bad_record=True))

    def test_different_wheel_native_rejected_with_valid_record(self):
        with self.assertRaisesRegex(GATE.GateError, "wheel native differs"):
            self.verify(bundle_files("2.0.0", wrong_native=True))

    def test_runtime_dependency_rejected(self):
        with self.assertRaisesRegex(GATE.GateError, "dependencies"):
            self.verify(bundle_files("2.0.0", dependencies=True))

    def test_link_traversal_and_duplicate_archive_entries_rejected(self):
        for name, kind in [("chronotail/../../escape", tarfile.REGTYPE),
                           ("chronotail/link", tarfile.SYMTYPE),
                           ("chronotail/lib/libchronotail.dylib", tarfile.REGTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                entry = tarfile.TarInfo(name)
                entry.type, entry.linkname = kind, "../../escape"
                archive, sha = write_bundle(Path(directory), "2.0.0", extra=[entry])
                with self.assertRaises(GATE.GateError):
                    GATE.verify_bundle(archive, sha, "2.0.0", Path(directory) / "extracted")

    def test_architecture_and_kind_checked_before_execution(self):
        path = self.root / "native"
        for cpu, kind in [(0x01000007, 6), (0x0100000C, 2)]:
            path.write_bytes(struct.pack("<8I", 0xFEEDFACF, cpu, 0, kind, 1, 8, 0, 0) + b"\0" * 8)
            with self.assertRaisesRegex(GATE.GateError, "thin ARM64"):
                GATE.macho(path, 6)

    def test_declared_oversized_member_rejected_before_reading_body(self):
        archive = self.root / "chronotail-2.0.0-macos-aarch64.tar.gz"
        with tarfile.open(archive, "w:gz") as target:
            entry = tarfile.TarInfo("chronotail/huge")
            entry.size = GATE.MAX_FILE + 1
            target.addfile(entry)  # Deliberately no body: rejection must precede decoding.
        with self.assertRaisesRegex(GATE.GateError, "member too large"):
            GATE.verify_bundle(archive, GATE.sha256(archive), "2.0.0", self.root / "extracted")

    def test_old_receipt_cannot_redirect_hash_source_or_capability(self):
        old = self.verify()
        for field, key, value in [("bundle", "sha256", "0" * 64), ("release", "source_commit_sha", "0" * 40),
                                  ("native", "ct_exports", GATE.OLD_SYMBOLS + ["ct_lookup"])]:
            with self.subTest(key=key):
                data = provenance(old)
                data[field][key] = value
                receipt = self.root / "receipt.json"
                receipt.write_text(json.dumps(data))
                with self.assertRaises(GATE.GateError):
                    GATE.verify_old_provenance(receipt, old)


class FakeProcesses:
    def __init__(self, failing=None):
        self.calls = []
        self.failing = failing

    def __call__(self, argv, *, cwd, env):
        self.calls.append((argv, Path(cwd), dict(env)))
        stage = "install" if "pip" in argv else "probe" if any(str(part).endswith("probe.py") for part in argv) else "link"
        if stage == "install":
            site = Path(argv[argv.index("--target") + 1])
            with zipfile.ZipFile(argv[-1]) as wheel:
                for entry in wheel.infolist():
                    path = site / entry.filename
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(wheel.read(entry))
            return subprocess.CompletedProcess(argv, 0, "fake offline install\n", "")
        if stage == "probe":
            site, native, native_sha, python_sha, version, kind = argv[3:9]
            if self.failing == "old-probe" and kind == "old":
                return subprocess.CompletedProcess(argv, 1, "", "import failure\n")
            data = {"kind": kind, "abi": 2, "installed_module": str(Path(site) / "chronotail/__init__.py"),
                    "native_path": native, "native_sha256": native_sha, "python_sha256": python_sha,
                    "version": version, "existing_operations": "passed", "capability_checks": "passed",
                    "unsupported": {name: "requires native symbols" for name in ["lookup", "lookup_prepared", "iter_range"]} if kind == "old" else {},
                    "fallback_calls": 0}
            if self.failing == "wrong-path" and kind == "old":
                data["native_path"] = "/wrong/new-native.dylib"
            return subprocess.CompletedProcess(argv, 0, json.dumps(data), "")
        old = any(str(part).endswith("c-old") for part in argv) or Path(cwd).name == "go-old"
        if old and self.failing != "negative-success":
            diagnostic = "Undefined symbols for architecture arm64: _ct_lookup _ct_lookup_prepared\n"
            if self.failing == "unrelated-link":
                diagnostic = "unknown compiler option\n"
            return subprocess.CompletedProcess(argv, 1, "", diagnostic)
        return subprocess.CompletedProcess(argv, 0, "fake link\n", "")


class OrchestrationTests(FixtureCase):
    def arguments(self):
        new_path, new_sha = write_bundle(self.root, "2.2.0")
        old_path, old_sha = write_bundle(self.root, "2.0.0")
        old = GATE.verify_bundle(old_path, old_sha, "2.0.0", self.root / "receipt-extraction")
        receipt = self.root / "old-provenance.json"
        receipt.write_text(json.dumps(provenance(old)))
        return argparse.Namespace(new_bundle=new_path, new_sha256=new_sha, new_version="2.2.0",
                                  old_bundle=old_path, old_sha256=old_sha, old_release_receipt=receipt,
                                  output=self.root / "result.json", require_links=False)

    def run_fake(self, failing=None, tools=True, require_links=False):
        args = self.arguments()
        args.require_links = require_links
        processes = FakeProcesses(failing)
        finder = lambda name, **kwargs: "/fake/" + name if tools and (tools != "c" or name == "clang") else None
        with patch.object(GATE.shutil, "which", side_effect=finder), patch.object(GATE.sys, "version_info", (3, 11, 0)):
            result = GATE.run_gate(args, runner=processes, host=("Darwin", "arm64"))
        self.assertEqual(result, json.loads(args.output.read_text()))
        return result, processes.calls

    def test_platform_rejection_has_receipt_and_zero_processes(self):
        args = self.arguments()
        processes = FakeProcesses()
        result = GATE.run_gate(args, runner=processes, host=("Linux", "aarch64"))
        self.assertEqual(result["status"], "failed")
        self.assertIn("native macOS ARM64", result["error"])
        self.assertEqual(processes.calls, [])

    def test_success_uses_isolated_new_install_and_exact_old_override(self):
        with patch.dict(GATE.os.environ, {"CHRONOTAIL_LIBRARY": "/wrong.dylib", "PYTHONPATH": "/checkout",
                                          "DYLD_LIBRARY_PATH": "/wrong", "PIP_INDEX_URL": "https://invalid",
                                          "CGO_LDFLAGS": "-L/wrong"}):
            result, calls = self.run_fake()
        self.assertEqual(result["status"], "passed", result.get("error"))
        self.assertEqual(len(calls), 7)
        install, _, env = calls[0]
        self.assertEqual(install[1:7], ["-I", "-m", "pip", "--isolated", "install", "--no-index"])
        self.assertIn("--no-deps", install)
        self.assertNotIn("PYTHONPATH", env)
        self.assertNotIn("CHRONOTAIL_LIBRARY", calls[1][2])
        old_argv, _, old_env = calls[2]
        self.assertEqual(old_env["CHRONOTAIL_LIBRARY"], old_argv[4])
        self.assertIn("/old/chronotail/lib/", old_argv[4])
        for _, _, child_env in calls:
            self.assertNotIn("DYLD_LIBRARY_PATH", child_env)
            self.assertNotIn("PYTHONPATH", child_env)
            self.assertEqual(child_env["GOPROXY"], "off")
            self.assertEqual(child_env["GOTOOLCHAIN"], "local")
        self.assertEqual([record["exit_code"] for record in result["commands"]], [0, 0, 0, 0, 1, 0, 1])
        self.assertTrue(all(Path(record["stderr"]).is_file() for record in result["commands"]))

    def test_old_import_failure_preserves_exit_logs_and_stops(self):
        result, calls = self.run_fake("old-probe")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(len(calls), 3)
        last = result["commands"][-1]
        self.assertEqual(last["exit_code"], 1)
        self.assertEqual(Path(last["stderr"]).read_text(), "import failure\n")

    def test_wrong_library_path_is_not_accepted_as_success(self):
        result, _ = self.run_fake("wrong-path")
        self.assertEqual(result["status"], "failed")
        self.assertIn("invalid old Python probe receipt", result["error"])

    def test_old_negative_success_and_unrelated_failure_are_gate_failures(self):
        for failure, message in [("negative-success", "unexpectedly linked"), ("unrelated-link", "missing-symbol evidence")]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                original = self.root
                self.root = Path(directory)
                try:
                    result, _ = self.run_fake(failure)
                finally:
                    self.root = original
                self.assertEqual(result["status"], "failed")
                self.assertIn(message, result["error"])

    def test_missing_optional_compilers_are_explicit_skips(self):
        result, calls = self.run_fake(tools=False)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(calls), 3)
        self.assertEqual(result["link_checks"]["c"]["status"], "skipped")
        self.assertEqual(result["link_checks"]["go"]["status"], "skipped")
        self.assertFalse(result["release_compatibility_complete"])

    def test_required_release_links_complete_only_after_both_language_checks(self):
        result, calls = self.run_fake(require_links=True)
        self.assertEqual(result["status"], "passed", result.get("error"))
        self.assertTrue(result["link_checks_required"])
        self.assertTrue(result["release_compatibility_complete"])
        self.assertEqual([record["stage"] for record in result["commands"][-4:]],
                         ["c-link-new", "c-link-old", "go-link-new", "go-link-old"])

    def test_required_release_rejects_missing_c_or_go_with_retained_skip_reason(self):
        for tools in (False, "c"):
            with self.subTest(tools=tools), tempfile.TemporaryDirectory() as directory:
                original = self.root
                self.root = Path(directory)
                try:
                    result, _ = self.run_fake(tools=tools, require_links=True)
                finally:
                    self.root = original
                self.assertEqual(result["status"], "failed")
                self.assertFalse(result["release_compatibility_complete"])
                self.assertIn("availability skips", result["error"])
                self.assertEqual(result["link_checks"]["go"]["status"], "skipped")

    def test_process_timeout_preserves_partial_output(self):
        records = []
        def timeout(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 900, output=b"partial\n", stderr=b"diagnostic\n")
        commands = GATE.Commands(self.root, records, timeout)
        with self.assertRaisesRegex(GATE.GateError, "process failed"):
            commands.run("timeout", ["fake"], self.root, {})
        self.assertIsNone(records[0]["exit_code"])
        self.assertEqual(Path(records[0]["stdout"]).read_text(), "partial\n")

    def test_existing_receipt_is_never_overwritten(self):
        args = self.arguments()
        args.output.write_text("previous evidence\n")
        with self.assertRaisesRegex(GATE.GateError, "output already exists"):
            GATE.run_gate(args, runner=FakeProcesses(), host=("Darwin", "arm64"))
        self.assertEqual(args.output.read_text(), "previous evidence\n")


class ProbeTests(FixtureCase):
    def execute_old_probe(self, behavior="unsupported"):
        # A Python stand-in challenges the actual embedded acceptance script.
        # sys.modules intercepts import; no real client/native library is loaded.
        site = self.root / "site"
        module_path = site / "chronotail/__init__.py"
        module_path.parent.mkdir(parents=True)
        module_path.write_bytes(b"# pure fake module\n")
        native = self.root / "old.dylib"
        native.write_bytes(b"not native code\n")
        module = types.ModuleType("chronotail")
        module.__file__ = str(module_path)
        module._lib = types.SimpleNamespace(_name=str(native))
        for name in GATE.OLD_SYMBOLS:
            setattr(module._lib, name, lambda *args: 2)
        module._has_lookup = module._has_stateful_cursor = False
        module.LookupMode = types.SimpleNamespace(EXACT=0)
        stored, committed = [], []

        class Writer:
            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def prepare(self, *args):
                pass

            def append_many(self, name, timestamps, values):
                stored.extend(zip(timestamps, values))

            def append(self, name, timestamp, value):
                stored.append((timestamp, value))

            def checkpoint(self):
                committed[:] = stored

        class Reader:
            def __init__(self, *args):
                self.snapshot = list(committed)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def range(self, name, start, end):
                return [(t, v) for t, v in self.snapshot if start <= t <= end]

            def aggregate(self, name, start, end):
                values = [v for t, v in self.snapshot if start <= t <= end]
                return types.SimpleNamespace(count=len(values), sum=sum(values), minimum=min(values), maximum=max(values))

            def prepare(self, name):
                return object()

            def refresh(self):
                changed = self.snapshot != committed
                self.snapshot = list(committed)
                return changed

            def lookup(self, *args):
                if behavior == "fallback":
                    module._lib.ct_range()
                raise NotImplementedError("lookup requires native symbols")

            def lookup_prepared(self, *args):
                raise NotImplementedError("prepared lookup requires native symbols")

            def iter_range(self, *args, **kwargs):
                if behavior == "delayed":
                    return iter(())
                raise NotImplementedError("stream requires native symbols")

        module.Writer, module.Reader = Writer, Reader
        argv = ["probe.py", str(site), str(native), GATE.sha256(native), GATE.sha256(module_path),
                "2.2.0", "old", json.dumps(GATE.OLD_SYMBOLS)]
        with patch.dict(sys.modules, {"chronotail": module}), patch.object(sys, "argv", argv), \
                patch("importlib.metadata.version", return_value="2.2.0"), \
                patch.object(GATE.platform, "system", return_value="Darwin"), \
                patch.object(GATE.platform, "machine", return_value="arm64"), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            previous_path = list(sys.path)
            try:
                exec(compile(GATE.PROBE, "probe.py", "exec"), {})
            finally:
                sys.path[:] = previous_path
        return json.loads(output.getvalue())

    def test_valid_old_unsupported_calls_are_immediate_and_zero_fallback(self):
        result = self.execute_old_probe()
        self.assertEqual(set(result["unsupported"]), {"lookup", "lookup_prepared", "iter_range"})
        self.assertEqual(result["fallback_calls"], 0)

    def test_rescanning_fallback_is_rejected_by_actual_probe(self):
        with self.assertRaisesRegex(RuntimeError, "attempted native/query fallback"):
            self.execute_old_probe("fallback")

    def test_delayed_unsupported_generator_is_rejected_by_actual_probe(self):
        with self.assertRaisesRegex(RuntimeError, "did not fail at call time"):
            self.execute_old_probe("delayed")


if __name__ == "__main__":
    unittest.main()
