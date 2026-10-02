#!/usr/bin/env python3
"""Capture reproducibility metadata without environment variables or secrets."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys


def command(*args: str) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return result.stdout.strip() if result.returncode == 0 else 'unavailable'


def main() -> None:
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    data = {
        'commit': command('git', 'rev-parse', 'HEAD'),
        'dirty': bool(command('git', 'status', '--porcelain')),
        'platform': platform.platform(),
        'architecture': platform.machine(),
        'python': platform.python_version(),
        'zig': command('zig', 'version'),
        'go': command('go', 'version'),
        'compiler': command('cc', '--version'),
        'toolchain_lock_sha256': hashlib.sha256(Path('scripts/dev/toolchains.json').read_bytes()).hexdigest(),
    }
    output.write_text(json.dumps(data, indent=2) + '\n')


if __name__ == '__main__':
    main()
