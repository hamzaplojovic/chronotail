import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('setup_dev', Path(__file__).resolve().parents[2] / 'scripts/setup-dev.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / '.tools/bin').mkdir(parents=True)
        self.target = 'aarch64-macos'
        self.source = dict(url='https://example.invalid/tool.tar.xz', sha256='a'*64)
        self.tool = dict(version='0.15.2', platforms={self.target: self.source})
        self.destination = self.root / '.tools/zig-0.15.2-aarch64-macos'
        self.destination.mkdir()
        (self.destination / 'zig').touch()

    def test_unidentified_cache_rejected(self):
        with patch.object(setup, 'ROOT', self.root):
            with self.assertRaises(RuntimeError): setup.install('zig', self.tool, self.target)

    def test_changed_pin_rejected(self):
        identity = dict(name='zig', version='0.15.2', target=self.target, **self.source)
        identity['sha256'] = 'b'*64
        (self.destination / '.chronotail-toolchain.json').write_text(json.dumps(identity))
        with patch.object(setup, 'ROOT', self.root):
            with self.assertRaises(RuntimeError): setup.install('zig', self.tool, self.target)

    def test_other_architecture_is_not_reused(self):
        other = self.root / '.tools/zig-0.15.2-x86_64-macos'
        self.destination.rename(other)
        with patch.object(setup, 'ROOT', self.root), patch.object(setup.urllib.request, 'urlopen', side_effect=ValueError('download')) as download:
            with self.assertRaisesRegex(ValueError, 'download'):
                setup.install('zig', self.tool, self.target)
            download.assert_called_once()
