"""Exercise profile dispatch without building or running a benchmark."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ProfileDispatchTests(unittest.TestCase):
    def check_dispatch(self, mode, expected):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "dev").mkdir()
            shutil.copyfile(ROOT / "scripts/dev.sh", scripts / "dev.sh")
            (scripts / "dev-env.sh").write_text(
                'CHRONOTAIL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"\n'
                'export PATH="$CHRONOTAIL_ROOT/bin:$PATH"\n'
            )
            (scripts / "dev/metadata.py").write_text("pass\n")
            (scripts / "check-profile.py").write_text("pass\n")
            binary = root / "bin"
            binary.mkdir()
            zig = binary / "zig"
            zig.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys\n"
                "if sys.argv[1:] == ['version']:\n"
                "    print('0.15.2')\n"
                "else:\n"
                "    pathlib.Path('invocation.json').write_text(json.dumps(sys.argv[1:]))\n"
            )
            zig.chmod(0o755)
            result = subprocess.run(
                ["bash", str(scripts / "dev.sh"), "profile", mode],
                cwd=root, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / "invocation.json").read_text()), expected)

    def test_full_has_no_empty_argument_or_quick_flag(self):
        self.check_dispatch("full", ["build", "performance", "-Doptimize=ReleaseFast",
                                     "--", "--output", ".dev-results/profile.jsonl"])

    def test_quick_preserves_flag(self):
        self.check_dispatch("quick", ["build", "performance", "-Doptimize=ReleaseFast",
                                      "--", "--quick", "--output", ".dev-results/profile.jsonl"])


if __name__ == "__main__":
    unittest.main()
