import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('profile_pair', Path(__file__).resolve().parents[2] / 'scripts/profile-pair.py')
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)


class PairContractTests(unittest.TestCase):
    def setUp(self):
        self.metadata = dict(format=1, zig='0.15.2', os='macos', arch='aarch64',
                             points=100000, repetitions=1, quick=True, engine_format=7)
        self.contract = pair.check_contract(self.metadata, None)

    def test_different_data_size_rejected(self):
        with self.assertRaises(ValueError):
            pair.check_contract(dict(self.metadata, points=200000), self.contract)

    def test_different_toolchain_or_host_rejected(self):
        for key, value in [('zig', '0.16.0'), ('arch', 'x86_64'), ('quick', False)]:
            with self.assertRaises(ValueError):
                pair.check_contract(dict(self.metadata, **{key: value}), self.contract)

    def test_format_comparison_is_explicitly_allowed(self):
        self.assertEqual(pair.check_contract(dict(self.metadata, engine_format=8), self.contract), self.contract)
