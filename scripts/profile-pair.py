#!/usr/bin/env python3
"""Alternate baseline/candidate profiles on one host; never publish them."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(args: list, cwd: Path = ROOT, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def check_contract(metadata: dict, previous: dict | None) -> dict:
    contract = {key: metadata[key] for key in ('format', 'zig', 'os', 'arch', 'points', 'repetitions', 'quick')}
    if previous is not None and contract != previous:
        raise ValueError('profile metadata/input contract changed during comparison')
    return contract


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', help='git revision to compare with the current checkout')
    parser.add_argument('--full', action='store_true', help='use full datasets instead of the quick matrix')
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    if args.repetitions < 2:
        parser.error('at least two alternating repetitions are required')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip():
        parser.error('commit the candidate first; paired evidence requires a clean source snapshot')
    candidate_revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    revision = subprocess.check_output(['git', 'rev-parse', '--verify', args.baseline + '^{commit}'], cwd=ROOT, text=True).strip()
    environment = dict(os.environ)
    environment['PATH'] = str(ROOT / '.tools/bin') + os.pathsep + environment.get('PATH', '')
    evidence = ROOT / '.dev-results/paired'
    evidence.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=evidence))
    work = output / 'baseline'
    candidate = output / 'candidate'
    (output / 'baseline-commit.txt').write_text(revision + '\n')
    (output / 'candidate-commit.txt').write_text(candidate_revision + '\n')
    run(['python3', 'scripts/dev/metadata.py', str(output / 'environment.json')], env=environment)
    run(['git', 'worktree', 'add', '--detach', str(work), revision])
    collected = {'baseline': [], 'candidate': []}
    try:
        run(['git', 'worktree', 'add', '--detach', str(candidate), candidate_revision])
        harness = Path('tests/performance/main.zig')
        if hashlib.sha256((work / harness).read_bytes()).digest() != hashlib.sha256((candidate / harness).read_bytes()).digest():
            raise ValueError('harness/input contract differs; use a separately specified experiment')
        metadata_contract = None
        for repetition in range(args.repetitions):
            order = ('baseline', 'candidate') if repetition % 2 == 0 else ('candidate', 'baseline')
            for label in order:
                destination = output / (label + '-' + str(repetition) + '.jsonl')
                command = ['zig', 'build', 'performance', '-Doptimize=ReleaseFast', '--', '--points', '1000000', '--repetitions', '1', '--output', str(destination)]
                if not args.full:
                    command.append('--quick')
                (output / (label + '-' + str(repetition) + '.command.json')).write_text(json.dumps(command) + '\n')
                with (output / (label + '-' + str(repetition) + '.log')).open('w') as log:
                    run(command, cwd=work if label == 'baseline' else candidate, env=environment, stdout=log, stderr=subprocess.STDOUT)
                run(['python3', str(ROOT / 'scripts/check-profile.py'), str(destination)])
                sample_metadata = json.loads(destination.read_text().splitlines()[0])
                metadata_contract = check_contract(sample_metadata, metadata_contract)
                collected[label].append(destination)
        for label, files in collected.items():
            rows = [json.loads(line) for file in files for line in file.read_text().splitlines()]
            metadata = next(row for row in rows if row['type'] == 'metadata')
            metadata['repetitions'] = args.repetitions
            results = [row for row in rows if row['type'] == 'result']
            combined = output / (label + '.jsonl')
            combined.write_text(''.join(json.dumps(row) + '\n' for row in [metadata] + results))
            run(['python3', str(ROOT / 'scripts/check-profile.py'), str(combined)])
        with (output / 'comparison.md').open('w') as report:
            run(['python3', 'tests/performance/compare.py', str(output / 'baseline.jsonl'), str(output / 'candidate.jsonl')], stdout=report)
        print('Diagnostic comparison:', output / 'comparison.md')
    finally:
        # Only this disposable worktree is removed. Evidence remains at output.
        if candidate.exists():
            run(['git', 'worktree', 'remove', '--force', str(candidate)])
        run(['git', 'worktree', 'remove', '--force', str(work)])


if __name__ == '__main__':
    main()
