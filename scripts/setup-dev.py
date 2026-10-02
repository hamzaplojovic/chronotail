#!/usr/bin/env python3
"""Install checksum-pinned developer tools inside this checkout."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def install(name: str, spec: dict, target: str) -> None:
    destination = ROOT / '.tools' / (name + '-' + spec['version'] + '-' + target)
    executable = destination / ('zig' if name == 'zig' else 'bin/go')
    source = spec['platforms'][target]
    identity = dict(name=name, version=spec['version'], target=target, **source)
    receipt = destination / '.chronotail-toolchain.json'
    if executable.exists() and (not receipt.exists() or json.loads(receipt.read_text()) != identity):
        raise RuntimeError('toolchain cache identity changed; remove and reinstall ' + str(destination))
    if not executable.exists():
        with tempfile.TemporaryDirectory(dir=ROOT / '.tools') as temporary:
            work = Path(temporary)
            archive = work / 'toolchain.tar'
            with urllib.request.urlopen(source['url'], timeout=120) as response, archive.open('wb') as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != source['sha256']:
                raise RuntimeError('checksum mismatch for ' + name)
            # Validate names before asking system tar to extract a trusted archive.
            with tarfile.open(archive) as stream:
                for member in stream.getmembers():
                    if member.name.startswith('/') or '..' in Path(member.name).parts:
                        raise RuntimeError('unsafe archive member')
                    if member.issym() or member.islnk():
                        if member.linkname.startswith('/') or '..' in Path(member.linkname).parts:
                            raise RuntimeError('unsafe archive link')
            unpacked = work / 'unpacked'
            unpacked.mkdir()
            subprocess.run(['tar', '-xf', str(archive), '--strip-components=1', '-C', str(unpacked)], check=True)
            unpacked.rename(destination)
            receipt.write_text(json.dumps(identity, indent=2) + '\n')
    result = subprocess.check_output([str(executable), 'version'], text=True).strip()
    expected = spec['version'] if name == 'zig' else 'go' + spec['version']
    if (name == 'zig' and result != expected) or (name == 'go' and expected not in result.split()):
        raise RuntimeError('unexpected installed version: ' + result)
    link = ROOT / '.tools/bin' / name
    if link.is_symlink():
        link.unlink()
    elif link.exists():
        raise RuntimeError('refusing to replace ' + str(link))
    link.symlink_to(os.path.relpath(executable, link.parent))
    if name == 'go':
        formatter = ROOT / '.tools/bin/gofmt'
        if formatter.is_symlink():
            formatter.unlink()
        elif formatter.exists():
            raise RuntimeError('refusing to replace ' + str(formatter))
        formatter.symlink_to(os.path.relpath(destination / 'bin/gofmt', formatter.parent))
    print(result, flush=True)


def main() -> None:
    system = {'Linux': 'linux', 'Darwin': 'macos'}.get(platform.system())
    architecture = {'x86_64': 'x86_64', 'AMD64': 'x86_64', 'arm64': 'aarch64', 'aarch64': 'aarch64'}.get(platform.machine())
    target = str(architecture) + '-' + str(system)
    lock = json.loads((ROOT / 'scripts/dev/toolchains.json').read_text())
    if target not in lock['zig']['platforms']:
        raise SystemExit('unsupported development host: ' + target)
    (ROOT / '.tools/bin').mkdir(parents=True, exist_ok=True)
    for name, spec in lock.items():
        install(name, spec, target)
    print('Tools ready. Run: ./scripts/dev.sh quick')


if __name__ == '__main__':
    main()
