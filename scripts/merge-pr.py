#!/usr/bin/env python3
"""Merge an authorized, independently reviewed PR only after successful CI."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess


def validate(pr: dict, review: dict) -> str:
    sha = pr['headRefOid']
    if pr.get('state') != 'OPEN' or pr.get('isDraft'):
        raise ValueError('PR must be open and ready')
    if pr.get('baseRefName') != 'main' or pr.get('mergeable') != 'MERGEABLE' or pr.get('mergeStateStatus') != 'CLEAN':
        raise ValueError('PR must merge cleanly into main and satisfy GitHub policy')
    reviewers = review.get('reviewers')
    if review.get('reviewed_sha') != sha or not isinstance(reviewers, list) or not reviewers or any(not isinstance(person, str) or not person.strip() for person in reviewers):
        raise ValueError('independent review must match the current PR commit')
    if review.get('blocking_findings') != []:
        raise ValueError('unresolved blocking findings prevent merge')
    checks = pr.get('statusCheckRollup') or []
    required = [check for check in checks if check.get('name') == 'Required CI']
    if not required or any(check.get('status') != 'COMPLETED' or check.get('conclusion') != 'SUCCESS' for check in required):
        raise ValueError('Required CI must complete successfully')
    for check in checks:
        if check.get('name'):
            if check.get('status') != 'COMPLETED' or check.get('conclusion') not in ('SUCCESS', 'NEUTRAL', 'SKIPPED'):
                raise ValueError('check failed or pending: ' + check['name'])
        elif check.get('state') != 'SUCCESS':
            raise ValueError('status failed or pending: ' + check.get('context', 'unknown'))
    return sha


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pr', type=int)
    parser.add_argument('--review', required=True, type=Path, help='independent review JSON: reviewed_sha, reviewers, blocking_findings')
    parser.add_argument('--execute', action='store_true', help='perform an already-authorized merge; default is validation only')
    args = parser.parse_args()
    fields = 'headRefOid,baseRefOid,baseRefName,isDraft,state,mergeable,mergeStateStatus,statusCheckRollup,url'
    pr = json.loads(subprocess.check_output(['gh', 'pr', 'view', str(args.pr), '--json', fields], text=True))
    sha = validate(pr, json.loads(args.review.read_text()))
    print('Validated:', pr['url'], sha)
    if args.execute:
        fresh = json.loads(subprocess.check_output(['gh', 'pr', 'view', str(args.pr), '--json', fields], text=True))
        if validate(fresh, json.loads(args.review.read_text())) != sha or fresh['baseRefOid'] != pr['baseRefOid']:
            raise ValueError('head or base changed during final merge checks')
        # Server verifies the exact head SHA again; a racing push cannot be merged.
        subprocess.run(['gh', 'pr', 'merge', str(args.pr), '--squash', '--match-head-commit', sha], check=True)


if __name__ == '__main__':
    main()
