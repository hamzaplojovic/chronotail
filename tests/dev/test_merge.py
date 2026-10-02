import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('merge_pr', Path(__file__).resolve().parents[2] / 'scripts/merge-pr.py')
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)


class MergeGateTests(unittest.TestCase):
    def setUp(self):
        self.pr = dict(headRefOid='abc', baseRefName='main', state='OPEN', isDraft=False,
                       mergeable='MERGEABLE', mergeStateStatus='CLEAN',
                       statusCheckRollup=[dict(name='Required CI', status='COMPLETED', conclusion='SUCCESS')])
        self.review = dict(reviewed_sha='abc', reviewers=['independent correctness agent'], blocking_findings=[])

    def test_reviewed_green_commit(self):
        self.assertEqual(merge.validate(self.pr, self.review), 'abc')

    def test_stale_review(self):
        self.review['reviewed_sha'] = 'old'
        with self.assertRaises(ValueError): merge.validate(self.pr, self.review)

    def test_invalid_reviewer_identity(self):
        for reviewers in [True, 'reviewer', [None], [''], ['  '], []]:
            self.review['reviewers'] = reviewers
            with self.assertRaises(ValueError): merge.validate(self.pr, self.review)

    def test_failed_or_missing_gate(self):
        for checks in [[], [dict(name='Required CI', status='COMPLETED', conclusion='FAILURE')],
                       [dict(name='Required CI', status='IN_PROGRESS')]]:
            self.pr['statusCheckRollup'] = checks
            with self.assertRaises(ValueError): merge.validate(self.pr, self.review)

    def test_other_failure_blocks(self):
        self.pr['statusCheckRollup'].append(dict(name='review', status='COMPLETED', conclusion='FAILURE'))
        with self.assertRaises(ValueError): merge.validate(self.pr, self.review)

    def test_blocking_review(self):
        self.review['blocking_findings'] = ['durability failure']
        with self.assertRaises(ValueError): merge.validate(self.pr, self.review)

    def test_github_policy_blocks(self):
        self.pr['mergeStateStatus'] = 'BLOCKED'
        with self.assertRaises(ValueError): merge.validate(self.pr, self.review)

    def test_ci_rerun_blocks_execution(self):
        self.pr['baseRefOid'] = 'base'
        self.pr['url'] = 'https://github.com/example/repo/pull/1'
        fresh = dict(self.pr, statusCheckRollup=[dict(name='Required CI', status='IN_PROGRESS')])
        with patch('sys.argv', ['merge-pr.py', '1', '--review', 'review.json', '--execute']), \
             patch.object(merge.Path, 'read_text', return_value=json.dumps(self.review)), \
             patch.object(merge.subprocess, 'check_output', side_effect=[json.dumps(self.pr), json.dumps(fresh)]), \
             patch.object(merge.subprocess, 'run') as execute:
            with self.assertRaises(ValueError): merge.main()
            execute.assert_not_called()

    def test_changed_base_blocks_execution(self):
        self.pr['baseRefOid'] = 'base'
        self.pr['url'] = 'https://github.com/example/repo/pull/1'
        with patch('sys.argv', ['merge-pr.py', '1', '--review', 'review.json', '--execute']), \
             patch.object(merge.Path, 'read_text', return_value=json.dumps(self.review)), \
             patch.object(merge.subprocess, 'check_output', side_effect=[json.dumps(self.pr), json.dumps(dict(self.pr, baseRefOid='new'))]), \
             patch.object(merge.subprocess, 'run') as execute:
            with self.assertRaises(ValueError): merge.main()
            execute.assert_not_called()
