#!/usr/bin/env python3
"""Offline installed-wheel compatibility gate for released ABI-v2 macOS ARM64.

Run only in a coordinator-authorized native slot. Archive validation uses the
stdlib; execution additionally needs Python's pip, and optionally clang/Go.
Public provenance is caller-provided, pinned evidence, not signed attestation.
"""

from __future__ import annotations

import argparse
import ast
import base64
import csv
from datetime import datetime, timezone
from email.parser import BytesParser
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile


OLD_VERSION = "2.0.0"
OLD_SOURCE = "ddb8109bc97db3d9932b0beca67aac8f6c016646"
RELEASE_URL = "https://github.com/hamzaplojovic/chronotail/releases/tag/v2.0.0"
OLD_SYMBOLS = sorted((
    "ct_abi_version", "ct_error_string", "ct_open_writer", "ct_prepare_append",
    "ct_append", "ct_checkpoint", "ct_checkpoint_with_durability", "ct_close",
    "ct_open_reader", "ct_refresh", "ct_prepare_series", "ct_range",
    "ct_range_prepared", "ct_aggregate", "ct_aggregate_prepared",
    "ct_cursor_init", "ct_cursor_next", "ct_borrow_raw_page",
))
OPTIONAL_SYMBOLS = (
    "ct_lookup", "ct_lookup_prepared", "ct_cursor_state_create",
    "ct_cursor_state_next", "ct_cursor_state_destroy",
)
MAX_FILE = 256 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
MAX_MEMBERS = 4096


class GateError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest() if hasattr(
            hashlib, "file_digest"
        ) else _stream_digest(source)


def _stream_digest(source) -> str:
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def safe_name(name: str) -> str:
    path = PurePosixPath(name)
    require(bool(name) and not path.is_absolute() and "\\" not in name
            and ".." not in path.parts and "." not in name.split("/")
            and "//" not in name, f"unsafe archive path: {name!r}")
    return str(path)


def macho(path: Path, filetype: int) -> dict:
    with path.open("rb") as source:
        header = source.read(32)
    require(len(header) == 32, f"truncated Mach-O: {path.name}")
    magic, cpu, _, kind, ncmds, commands, _, _ = struct.unpack("<8I", header)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and kind == filetype,
            f"expected thin ARM64 Mach-O kind {filetype}: {path.name}")
    require(ncmds > 0 and commands >= ncmds * 8 and commands <= path.stat().st_size - 32,
            f"invalid Mach-O load-command bounds: {path.name}")
    return {"architecture": "ARM64", "filetype": kind, "load_commands": ncmds}


def verify_wheel(wheel: Path, version: str, native: Path) -> dict:
    info = f"chronotail-{version}.dist-info"
    expected = {"chronotail/__init__.py", "chronotail/_native/libchronotail.dylib",
                f"{info}/METADATA", f"{info}/WHEEL", f"{info}/RECORD"}
    with zipfile.ZipFile(wheel) as archive:
        entries = archive.infolist()
        require(len(entries) == len(expected) and {entry.filename for entry in entries} == expected,
                "wheel must contain the dependency-free five-file package")
        for entry in entries:
            safe_name(entry.filename)
            require(entry.file_size <= MAX_FILE and not entry.flag_bits & 1
                    and (entry.external_attr >> 16) & 0o170000 != 0o120000,
                    f"invalid wheel member: {entry.filename}")
        require(sum(entry.file_size for entry in entries) <= MAX_TOTAL, "wheel too large")
        data = {entry.filename: archive.read(entry) for entry in entries}
    record = list(csv.reader(io.StringIO(data[f"{info}/RECORD"].decode("utf-8"))))
    require(len(record) == len(expected) and all(len(row) == 3 for row in record)
            and {row[0] for row in record} == expected, "wheel RECORD incomplete/duplicate")
    for name, digest, size in record:
        if name == f"{info}/RECORD":
            require(digest == size == "", "wheel RECORD self entry must be unhashed")
        else:
            actual = base64.urlsafe_b64encode(hashlib.sha256(data[name]).digest()).rstrip(b"=").decode()
            require(digest == "sha256=" + actual and size == str(len(data[name])),
                    f"wheel RECORD mismatch: {name}")
    metadata = BytesParser().parsebytes(data[f"{info}/METADATA"])
    tags = BytesParser().parsebytes(data[f"{info}/WHEEL"])
    require(metadata.get_all("Name") == ["chronotail"]
            and metadata.get_all("Version") == [version]
            and not metadata.get_all("Requires-Dist"), "wrong wheel version/name/dependencies")
    require(tags.get_all("Tag") == ["py3-none-macosx_11_0_arm64"]
            and tags.get("Root-Is-Purelib") == "false", "wrong wheel platform")
    require(hashlib.sha256(data["chronotail/_native/libchronotail.dylib"]).hexdigest() == sha256(native),
            "wheel native differs from bundled dylib")
    python = ast.parse(data["chronotail/__init__.py"])
    require(any(isinstance(node, ast.Assign) and any(isinstance(target, ast.Name)
                and target.id == "ABI_VERSION" for target in node.targets)
                and isinstance(node.value, ast.Constant) and type(node.value.value) is int
                and node.value.value == 2 for node in python.body), "wheel Python must require ABI2")
    return {"version": version, "tag": "py3-none-macosx_11_0_arm64",
            "python_sha256": hashlib.sha256(data["chronotail/__init__.py"]).hexdigest(),
            "native_sha256": sha256(native), "sha256": sha256(wheel)}


def verify_bundle(archive: Path, pinned_sha: str, version: str, destination: Path) -> dict:
    require(re.fullmatch(r"[0-9a-f]{64}", pinned_sha) is not None, "invalid pinned SHA256")
    require(archive.name == f"chronotail-{version}-macos-aarch64.tar.gz", "wrong bundle name/version/platform")
    require(sha256(archive) == pinned_sha, "outer bundle SHA256 mismatch")
    destination.mkdir()
    seen = set()
    total = 0
    with tarfile.open(archive, "r:gz") as source:
        for entry in source:
            name = safe_name(entry.name)
            require(name == "chronotail" or name.startswith("chronotail/"), "wrong archive root")
            require(name not in seen, f"duplicate archive path: {name}")
            seen.add(name)
            require(len(seen) <= MAX_MEMBERS and (entry.isdir() or entry.isfile())
                    and not entry.issparse(), "unsupported archive member/count")
            require(0 <= entry.size <= MAX_FILE, "archive member too large")
            total += entry.size
            require(total <= MAX_TOTAL, "archive too large")
            target = destination / name
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(entry) as content, target.open("xb") as output:
                    shutil.copyfileobj(content, output, 1024 * 1024)
    root = destination / "chronotail"
    wheel_name = f"python/chronotail-{version}-py3-none-macosx_11_0_arm64.whl"
    critical = {"bin/chronotail", "lib/libchronotail.a", "lib/libchronotail.dylib",
                "include/chronotail.h", wheel_name}
    declared = {}
    for line in (root / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        require(match is not None, "malformed internal checksum manifest")
        digest, name = match.groups()
        safe_name(name)
        require(name not in declared, "duplicate internal checksum entry")
        declared[name] = digest
    require(critical <= declared.keys(), "missing critical internal checksums")
    for name, digest in declared.items():
        require(sha256(root / name) == digest, f"internal checksum mismatch: {name}")
    require(re.search(r"\buint32_t\s+ct_abi_version\s*\(\s*void\s*\)\s*;",
                      (root / "include/chronotail.h").read_text()) is not None,
            "header does not declare ABI-version export")
    with (root / "lib/libchronotail.a").open("rb") as static:
        require(static.read(8) == b"!<arch>\n", "invalid static archive")
    native = root / "lib/libchronotail.dylib"
    native_info = macho(native, 6)
    macho(root / "bin/chronotail", 2)
    wheel = root / wheel_name
    wheel_info = verify_wheel(wheel, version, native)
    require((root / "RELEASE_NOTES.md").read_text().startswith(f"# Chronotail {version}\n"),
            "release notes version mismatch")
    return {"root": str(root), "archive": str(archive), "archive_sha256": pinned_sha,
            "version": version, "native": str(native), "native_sha256": sha256(native),
            "header_sha256": sha256(root / "include/chronotail.h"),
            "internal_manifest_sha256": sha256(root / "SHA256SUMS"),
            "checked_internal_sha256": declared, "macho": native_info,
            "wheel": str(wheel), "wheel_info": wheel_info}


def verify_old_provenance(receipt: Path, old: dict) -> dict:
    data = json.loads(receipt.read_text())
    require(isinstance(data, dict) and data.get("schema_version") == 1
            and data.get("record_type") == "chronotail.released-old-native.static-verification"
            and data.get("finalized") is True, "old provenance requires finalized compact schema1 receipt")
    for field in ("release", "bundle", "native", "header", "wheel", "critical_members_sha256", "checks"):
        require(isinstance(data.get(field), dict), "old provenance missing " + field)
    release, bundle, native, header, wheel = (data[field] for field in ("release", "bundle", "native", "header", "wheel"))
    require(release.get("url") == RELEASE_URL and release.get("repository") == "hamzaplojovic/chronotail"
            and release.get("tag") == "v2.0.0" and release.get("source_commit_sha") == OLD_SOURCE
            and release.get("annotated_tag_object_sha") == "a2c5dd49634a80ee10ac656f84039dd30140e723",
            "old public release/tag/source provenance mismatch")
    require(bundle.get("sha256") == old["archive_sha256"]
            and native.get("sha256") == old["native_sha256"]
            and header.get("sha256") == old["header_sha256"], "old provenance hashes mismatch")
    require(data["critical_members_sha256"] == old["checked_internal_sha256"], "old critical member provenance mismatch")
    require(native.get("ct_exports") == OLD_SYMBOLS and native.get("ct_export_count") == 18
            and native.get("ABI_version_source_and_instruction_inspection") == 2
            and native.get("architecture") == "ARM64" and native.get("thin_macho") is True
            and native.get("filetype") == 6, "old provenance must attest ARM64 ABI2 exact18 exports")
    require(wheel.get("version") == OLD_VERSION and wheel.get("tag") == old["wheel_info"]["tag"]
            and wheel.get("native_sha256") == old["native_sha256"]
            and wheel.get("python_source_sha256") == old["wheel_info"]["python_sha256"]
            and wheel.get("RECORD_verified") is True and header.get("matches_tagged_source") is True,
            "old wheel/header source provenance mismatch")
    expected_url = RELEASE_URL.replace("/tag/", "/download/") + "/" + Path(old["archive"]).name
    require(bundle.get("name") == Path(old["archive"]).name
            and bundle.get("size") == Path(old["archive"]).stat().st_size
            and bundle.get("digest") == "sha256:" + old["archive_sha256"]
            and bundle.get("browser_download_url") == expected_url and release.get("published_at")
            and data["checks"].get("GitHub_asset_digests_and_outer_SHA256SUMS") is True,
            "old published asset provenance mismatch")
    return {"receipt": str(receipt), "receipt_sha256": sha256(receipt),
            "release_url": RELEASE_URL, "source_commit": OLD_SOURCE,
            "asset_id": bundle.get("id"), "published_at": release["published_at"],
            "limits": "Offline retained public receipt + caller SHA pin; not a signed attestation or fresh network verification."}


PROBE = r'''
import hashlib, importlib.metadata, json, os, platform, struct, sys
from pathlib import Path

def check(ok, message):
    if not ok:
        raise RuntimeError(message)

site, native, expected_native, expected_python, version, kind, symbols = sys.argv[1:]
site, native = Path(site).resolve(), Path(native).resolve()
check(platform.system() == "Darwin" and platform.machine() == "arm64", "probe requires native macOS ARM64")
sys.path.insert(0, str(site))
import chronotail as ct
module = Path(ct.__file__).resolve()
check(module == site / "chronotail/__init__.py", "import escaped installed new wheel")
check(hashlib.sha256(module.read_bytes()).hexdigest() == expected_python, "installed Python hash mismatch")
check(importlib.metadata.version("chronotail") == version, "installed distribution version mismatch")
check(Path(ct._lib._name).resolve() == native, "loaded wrong native library")
check(hashlib.sha256(native.read_bytes()).hexdigest() == expected_native, "loaded native hash mismatch")
check(ct._lib.ct_abi_version() == 2, "native ABI mismatch")
for name in json.loads(symbols):
    check(hasattr(ct._lib, name), "missing existing ABI2 symbol " + name)
optional = ("ct_lookup", "ct_lookup_prepared", "ct_cursor_state_create", "ct_cursor_state_next", "ct_cursor_state_destroy")
for name in optional:
    check(hasattr(ct._lib, name) == (kind == "new"), "unexpected native capability " + name)
check(ct._has_lookup == (kind == "new") and ct._has_stateful_cursor == (kind == "new"), "capability binding mismatch")

bits = lambda value: struct.pack(">d", value).hex()
path = Path.cwd() / (kind + ".ctdb")
with ct.Writer(path, batch_size=2, codec="compressed") as writer:
    writer.prepare("cpu", 3)
    writer.append_many("cpu", [10, 20], [0.0, -0.0])
    writer.checkpoint()
    with ct.Reader(path) as reader:
        points = reader.range("cpu", 10, 20)
        check([(t, bits(v)) for t, v in points] == [(10, "0000000000000000"), (20, "8000000000000000")], "old range/endpoint bits failed")
        summary = reader.aggregate("cpu", 10, 20)
        check(summary.count == 2 and summary.sum == 0 and summary.minimum == summary.maximum == 0, "old aggregate failed")
        check(reader.range("cpu", 11, 19) == [], "empty old range failed")
        prepared = reader.prepare("cpu")
        check(prepared is not None and reader.refresh() is False, "old prepare/unchanged refresh failed")
        writer.prepare("cpu", 1)
        writer.append("cpu", 30, 4.0)
        writer.checkpoint()
        check(len(reader.range("cpu", 0, 40)) == 2, "snapshot changed without refresh")
        check(reader.refresh() is True, "changed refresh failed")
        check(reader.range("cpu", 30, 30) == [(30, 4.0)] and reader.aggregate("cpu", 0, 40).count == 3, "refreshed range/aggregate failed")
        prepared = reader.prepare("cpu")
        if kind == "new":
            check(reader.lookup("cpu", 30, ct.LookupMode.EXACT) == (30, 4.0), "new lookup prerequisite failed")
            check(reader.lookup_prepared(prepared, 30, ct.LookupMode.EXACT) == (30, 4.0), "new prepared prerequisite failed")
            stream = reader.iter_range("cpu", 10, 30, batch_size=1)
            try:
                check(len(list(stream)) == 3, "new stream prerequisite failed")
            finally:
                stream.close()
        else:
            fallback_calls = []
            def forbidden(*args, **kwargs):
                fallback_calls.append(True)
                raise RuntimeError("unsupported call attempted native/query fallback")
            guarded = ("ct_range", "ct_range_prepared", "ct_aggregate", "ct_aggregate_prepared",
                       "ct_cursor_init", "ct_cursor_next", "ct_prepare_series", "ct_borrow_raw_page")
            saved = {name: getattr(ct._lib, name) for name in guarded}
            for name in guarded:
                setattr(ct._lib, name, forbidden)
            errors = {}
            try:
                for name, call in (
                    ("lookup", lambda: reader.lookup("cpu", 20, ct.LookupMode.EXACT)),
                    ("lookup_prepared", lambda: reader.lookup_prepared(prepared, 20, ct.LookupMode.EXACT)),
                    ("iter_range", lambda: reader.iter_range("cpu", 10, 30, batch_size=1)),
                ):
                    try:
                        result = call()  # Do not advance a returned generator: failure must be call-time.
                    except NotImplementedError as error:
                        check("native" in str(error), "unsupported error lacks native capability explanation")
                        errors[name] = str(error)
                    else:
                        if hasattr(result, "close"):
                            result.close()
                        raise RuntimeError("unsupported " + name + " did not fail at call time")
                check(not fallback_calls, "unsupported call used fallback")
            finally:
                for name, function in saved.items():
                    setattr(ct._lib, name, function)

print(json.dumps({"kind": kind, "installed_module": str(module), "native_path": str(native),
                  "native_sha256": expected_native, "python_sha256": expected_python,
                  "version": version, "abi": 2, "existing_operations": "passed",
                  "capability_checks": "passed", "unsupported": errors if kind == "old" else {},
                  "fallback_calls": len(fallback_calls) if kind == "old" else 0}))
'''

C_CONSUMER = r'''
#include <chronotail.h>
int main(void) {
    ct_point point;
    uint8_t found;
    ct_series_handle series = {0};
    return ct_lookup(0, "cpu", 3, 0, CT_LOOKUP_EXACT, 0, 0, &point, &found)
         + ct_lookup_prepared(0, series, 0, CT_LOOKUP_EXACT, 0, 0, &point, &found);
}
'''


def clean_env() -> dict:
    # Child processes get no inherited checkout imports, loader paths, pip
    # configuration, compiler flags, or automatic Go toolchain/module fetching.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("PYTHON", "PIP_", "DYLD_", "LD_", "CGO_", "GO", "CHRONOTAIL_"))
           and key not in {"CC", "CXX", "CFLAGS", "CPPFLAGS", "LDFLAGS", "LIBRARY_PATH", "CPATH",
                           "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"}}
    env.update({"PIP_CONFIG_FILE": os.devnull, "GOPROXY": "off", "GOSUMDB": "off",
                "GOTOOLCHAIN": "local", "GOWORK": "off", "GOENV": "off"})
    return env


def run_process(argv, *, cwd, env):
    return subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True, timeout=900)


class Commands:
    def __init__(self, logs: Path, records: list, runner):
        self.logs, self.records, self.runner = logs, records, runner

    def run(self, stage: str, argv: list[str], cwd: Path, env: dict, expected: int = 0):
        record = {"stage": stage, "argv": argv, "cwd": str(cwd), "exit_code": None,
                  "stdout": str(self.logs / (stage + ".stdout.log")),
                  "stderr": str(self.logs / (stage + ".stderr.log")),
                  "environment": {key: env[key] for key in (
                      "CHRONOTAIL_LIBRARY", "CGO_LDFLAGS", "CGO_ENABLED", "CC", "GOOS", "GOARCH",
                      "GOPROXY", "GOSUMDB", "GOTOOLCHAIN", "GOWORK", "GOENV", "GOCACHE", "GOPATH",
                      "PIP_CONFIG_FILE",
                  ) if key in env}}
        self.records.append(record)
        try:
            result = self.runner(argv, cwd=cwd, env=env)
        except (OSError, subprocess.TimeoutExpired) as error:
            record["error"] = str(error)
            for stream in ("stdout", "stderr"):
                content = getattr(error, stream, None) or ""
                if isinstance(content, bytes):
                    content = content.decode("utf-8", errors="replace")
                Path(record[stream]).write_text(content)
            raise GateError(f"{stage}: process failed: {error}") from error
        record["exit_code"] = result.returncode
        Path(record["stdout"]).write_text(result.stdout)
        Path(record["stderr"]).write_text(result.stderr)
        for stream in ("stdout", "stderr"):
            record[stream + "_sha256"] = sha256(Path(record[stream]))
        if expected == 0:
            require(result.returncode == 0, f"{stage}: expected exit0, got {result.returncode}; see retained logs")
        else:
            require(result.returncode != 0, f"{stage}: old native unexpectedly linked")
            diagnostics = result.stdout + result.stderr
            require("Undefined symbols" in diagnostics
                    and all(re.search(r"(?<![A-Za-z0-9_])_?" + name + r"(?![A-Za-z0-9_])", diagnostics)
                            for name in ("ct_lookup", "ct_lookup_prepared")),
                    f"{stage}: failure is not lookup missing-symbol evidence; see retained logs")
        return result


def link_checks(new: dict, old: dict, work: Path, commands: Commands, env: dict) -> dict:
    root = Path(new["root"])
    compiler = shutil.which("clang", path=env.get("PATH"))
    go = shutil.which("go", path=env.get("PATH"))
    checks = {}
    if compiler is None:
        return {"c": {"status": "skipped", "reason": "clang unavailable"},
                "go": {"status": "skipped", "reason": "C compiler unavailable"}}
    source = work / "lookup.c"
    source.write_text(C_CONSUMER)
    for kind, bundle in (("new", new), ("old", old)):
        commands.run("c-link-" + kind, [compiler, "-std=c11", "-arch", "arm64", str(source),
                     "-I" + str(root / "include"), bundle["native"], "-o", str(work / ("c-" + kind))],
                     work, env, expected=0 if kind == "new" else 1)
    checks["c"] = {"status": "passed", "scope": "compile/link only; new succeeds, old fails for lookup symbols"}
    needed = [root / "go.mod", root / "clients/go/native.go", root / "clients/go/cmd/smoke/main.go"]
    if go is None or not all(path.is_file() for path in needed):
        checks["go"] = {"status": "skipped", "reason": "Go tool or packaged Go source inputs unavailable"}
        return checks
    for kind, bundle in (("new", new), ("old", old)):
        stage = work / ("go-" + kind)
        stage.mkdir()
        shutil.copytree(root / "clients/go", stage / "clients/go")
        shutil.copytree(root / "include", stage / "include")
        shutil.copyfile(root / "go.mod", stage / "go.mod")
        (stage / "lib").mkdir()
        library = stage / "lib/libchronotail.dylib"
        shutil.copyfile(bundle["native"], library)
        require(sha256(library) == bundle["native_sha256"], "staged Go library hash mismatch")
        go_env = {**env, "CGO_ENABLED": "1", "CC": compiler, "GOOS": "darwin", "GOARCH": "arm64",
                  "CGO_LDFLAGS": shlex.quote("-L" + str(stage / "lib")),
                  "GOCACHE": str(stage / "cache"), "GOPATH": str(stage / "gopath")}
        # Only the exact selected dylib is in the first library directory;
        # the unchanged packaged native.go supplies -lchronotail.
        commands.run("go-link-" + kind, [go, "build", "-a", "-o", str(stage / "consumer"),
                     "./clients/go/cmd/smoke"], stage, go_env, expected=0 if kind == "new" else 1)
    checks["go"] = {"status": "passed", "scope": "packaged source compile/link only; new succeeds, old lookup symbols absent; no Go binary executed"}
    return checks


def run_gate(args, *, runner=run_process, host=None) -> dict:
    output = args.output.resolve()
    require(not output.exists(), "output already exists; retain previous receipt and choose a new path")
    output.parent.mkdir(parents=True, exist_ok=True)
    logs = output.with_name(output.name + ".logs")
    require(not logs.exists(), "log directory already exists; choose a new output path")
    logs.mkdir()
    system, machine = host if host is not None else (platform.system(), platform.machine())
    result = {"schema": 1, "gate": "CT-011 installed old ABI2", "status": "failed",
              "release_compatibility_complete": False, "link_checks_required": args.require_links,
              "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "host": {"system": system, "machine": machine, "python": sys.version},
              "gate_source_sha256": sha256(Path(__file__)), "commands": [], "logs": str(logs),
              "inputs": {"new_bundle": str(args.new_bundle.resolve()), "new_sha256": args.new_sha256,
                         "new_version": args.new_version, "old_bundle": str(args.old_bundle.resolve()),
                         "old_sha256": args.old_sha256, "old_release_receipt": str(args.old_release_receipt.resolve())}}
    commands = Commands(logs, result["commands"], runner)
    try:
        require((system, machine) == ("Darwin", "arm64") and struct.calcsize("P") == 8,
                "this gate requires native macOS ARM64; Linux/cross-build/Rosetta are not accepted")
        require(sys.version_info >= (3, 10), "installed wheel gate requires Python3.10 or newer")
        require(re.fullmatch(r"2\.2\.[0-9]+", args.new_version) is not None, "new bundle must be version2.2.x")
        with tempfile.TemporaryDirectory(prefix="chronotail-old-abi-") as temporary:
            work = Path(temporary).resolve()
            checkout = Path(__file__).resolve().parents[1]
            checkouts = [checkout, *(parent for parent in checkout.parents if (parent / ".git").exists())]
            require(not any(work.is_relative_to(parent) for parent in checkouts),
                    "temporary install must be outside checkout, including enclosing shared checkout")
            new = verify_bundle(args.new_bundle.resolve(), args.new_sha256, args.new_version, work / "new")
            old = verify_bundle(args.old_bundle.resolve(), args.old_sha256, OLD_VERSION, work / "old")
            result.update({"new_bundle": new, "old_bundle": old,
                           "old_provenance": verify_old_provenance(args.old_release_receipt.resolve(), old)})
            env = clean_env()
            site = work / "site"
            commands.run("install-new-wheel", [sys.executable, "-I", "-m", "pip", "--isolated", "install",
                         "--no-index", "--no-deps", "--no-compile", "--disable-pip-version-check",
                         "--target", str(site), new["wheel"]], work, env)
            require(sha256(site / "chronotail/__init__.py") == new["wheel_info"]["python_sha256"]
                    and sha256(site / "chronotail/_native/libchronotail.dylib") == new["native_sha256"],
                    "installed new wheel content mismatch")
            probe = work / "probe.py"
            probe.write_text(PROBE)
            result["probe_sha256"] = sha256(probe)
            result["probes"] = {}
            for kind, bundle in (("new", new), ("old", old)):
                native = site / "chronotail/_native/libchronotail.dylib" if kind == "new" else Path(old["native"])
                probe_env = dict(env)
                if kind == "old":
                    probe_env["CHRONOTAIL_LIBRARY"] = str(native)
                process = commands.run("python-" + kind, [sys.executable, "-I", str(probe), str(site),
                                       str(native), bundle["native_sha256"], new["wheel_info"]["python_sha256"],
                                       args.new_version, kind, json.dumps(OLD_SYMBOLS)], work, probe_env)
                observed = json.loads(process.stdout)
                require(observed.get("kind") == kind and observed.get("abi") == 2
                        and observed.get("native_path") == str(native.resolve())
                        and observed.get("installed_module") == str(site / "chronotail/__init__.py")
                        and observed.get("version") == args.new_version
                        and observed.get("native_sha256") == bundle["native_sha256"]
                        and observed.get("python_sha256") == new["wheel_info"]["python_sha256"]
                        and observed.get("existing_operations") == observed.get("capability_checks") == "passed",
                        f"invalid {kind} Python probe receipt")
                if kind == "old":
                    require(set(observed.get("unsupported", {})) == {"lookup", "lookup_prepared", "iter_range"}
                            and observed.get("fallback_calls") == 0, "invalid old unsupported-call receipt")
                result["probes"][kind] = observed
            result["link_checks"] = link_checks(new, old, work, commands, env)
            result["link_checks_complete"] = all(result["link_checks"][language]["status"] == "passed"
                                                 for language in ("c", "go"))
            if args.require_links:
                require(result["link_checks_complete"],
                        "release use requires both C and Go matching-new/old link checks; availability skips are incomplete evidence")
            for bundle in (new, old):
                require(sha256(Path(bundle["archive"])) == bundle["archive_sha256"]
                        and sha256(Path(bundle["native"])) == bundle["native_sha256"], "artifact changed during gate")
            result["artifact_hashes_stable"] = True
        result["status"] = "passed"
        result["release_compatibility_complete"] = result["link_checks_complete"]
    except (GateError, OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        result["error"] = str(error)
    finally:
        result["completed_at_utc"] = datetime.now(timezone.utc).isoformat()
        output.write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--new-bundle", type=Path, required=True)
    parser.add_argument("--new-sha256", required=True, help="SHA256 from validated new-artifact receipt")
    parser.add_argument("--new-version", default="2.2.0")
    parser.add_argument("--old-bundle", type=Path, required=True)
    parser.add_argument("--old-sha256", required=True, help="explicit pinned released-v2.0 outer SHA256")
    parser.add_argument("--old-release-receipt", type=Path, required=True,
                        help="CT-011 compact schema1 old-native-release-receipt.json provenance")
    parser.add_argument("--require-links", action="store_true",
                        help="required for release: fail unless BOTH C and Go positive-new/negative-old links pass")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = run_gate(args)
    except (GateError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps({"status": result["status"], "output": str(args.output.resolve()),
                      "release_compatibility_complete": result["release_compatibility_complete"],
                      "error": result.get("error")}))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
