"""Branch names set the release bump, so the prefix must be a known type."""
import pathlib
import sys
_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(_ROOT / 'taskfiles/common/scripts'), str(_ROOT / 'taskfiles/release/scripts')]
import unittest
from check_branch_name import problems
from release_version import level


class BranchNameTests(unittest.TestCase):
    def test_valid_names_and_their_bump(self):
        for branch, bump in (('feat/spotlight-exact-exclusions', 'minor'), ('feature/x', 'minor'), ('minor/x', 'minor'),
                             ('fix/pending-update-indicator', 'patch'), ('chore/taskfile-tooling', 'patch'),
                             ('refactor/tooling-layout', 'patch'), ('docs/readme', 'patch'),
                             ('major/api', 'major'), ('release/v2', 'major'), ('dependabot/pip/ruff-1.0', 'patch')):
            with self.subTest(branch=branch):
                self.assertEqual(problems(branch), [])
                self.assertEqual(level(branch), bump)

    def test_typos_and_unprefixed_names_fail(self):
        for branch in ('fetaure/x', 'feature-x', 'Feat/X', 'feat/', 'my-branch', 'features/x', 'fix/Upper', 'main'):
            with self.subTest(branch=branch):
                self.assertTrue(problems(branch))


if __name__ == '__main__':
    unittest.main()
