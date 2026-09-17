#!/usr/bin/env python3
"""Build Chronotail's dependency-free platform wheel using only Python stdlib."""

from __future__ import annotations

import base64
import csv
import hashlib
import io
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZON = (ROOT / "build.zig.zon").read_text()
VERSION_MATCH = re.search(r'\.version\s*=\s*"([^"]+)"', ZON)
if VERSION_MATCH is None:
    raise RuntimeError("build.zig.zon does not declare a version")
VERSION = VERSION_MATCH.group(1)
DIST_INFO = f"chronotail-{VERSION}.dist-info"


def digest(data: bytes) -> str:
    value = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return "sha256=" + value.decode()


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: build-wheel.py <native-library> <platform-tag> <output-dir>")
    native = Path(sys.argv[1])
    platform = sys.argv[2]
    output = Path(sys.argv[3])
    filename = f"chronotail-{VERSION}-py3-none-{platform}.whl"
    files = {
        "chronotail/__init__.py": (ROOT / "python/src/chronotail/__init__.py").read_bytes(),
        f"chronotail/_native/{native.name}": native.read_bytes(),
        f"{DIST_INFO}/METADATA": (
            f"Metadata-Version: 2.1\nName: chronotail\nVersion: {VERSION}\n"
            "Summary: Python bindings for Chronotail\nRequires-Python: >=3.10\n"
        ).encode(),
        f"{DIST_INFO}/WHEEL": (
            "Wheel-Version: 1.0\nGenerator: chronotail-release\n"
            "Root-Is-Purelib: false\nTag: py3-none-" + platform + "\n"
        ).encode(),
    }
    rows = [[name, digest(data), str(len(data))] for name, data in files.items()]
    record_name = f"{DIST_INFO}/RECORD"
    rows.append([record_name, "", ""])
    record = io.StringIO()
    csv.writer(record, lineterminator="\n").writerows(rows)
    files[record_name] = record.getvalue().encode()

    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output / filename, "w", zipfile.ZIP_DEFLATED) as wheel:
        for name, data in files.items():
            wheel.writestr(name, data)


if __name__ == "__main__":
    main()
