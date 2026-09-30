#!/usr/bin/env python3
"""Check a branch name: its prefix sets the release version bump, so a typo must fail.

Usage:
  python3 taskfiles/common/scripts/check_branch_name.py --branch NAME
  python3 taskfiles/common/scripts/check_branch_name.py

Options:
  --branch NAME    Branch to check (CI passes the PR head branch). Without it, the
                   current git branch is checked; main and a detached HEAD are skipped.

A merged PR's branch prefix decides the release bump (taskfiles/release/scripts/
release_version.py: major*/release* -> major, minor*/feature*/feat* -> minor, anything
else -> patch). A misspelled prefix such as `fetaure/x` would silently ship as a patch,
so only `<type>/<slug>` with a known type is accepted. The printed bump comes from
release_version.level itself, so the check cannot drift from the release logic.

Project tooling (task common:check:branch-name); not part of the shipped app.

Exit codes:
  0 - valid (or skipped: main / detached HEAD)
  1 - invalid branch name
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'release/scripts'))
from release_version import level  # noqa: E402

TYPES = ('major', 'release', 'minor', 'feature', 'feat', 'fix', 'hotfix', 'patch', 'docs', 'chore',
         'ci', 'refactor', 'test', 'build', 'perf', 'style', 'deps', 'dependabot', 'renovate')
BRANCH = re.compile(r'^(%s)/[a-z0-9][a-z0-9._/-]*$' % '|'.join(TYPES))
SKIP = ('main', 'HEAD')


def problems(branch):
    if BRANCH.fullmatch(branch):
        return []
    return ["branch '%s' must be '<type>/<slug>' (lowercase slug); type one of %s. "
            "The prefix sets the release bump: major/release -> major, minor/feature/feat -> minor, others -> patch"
            % (branch, ', '.join(TYPES))]


def main():
    parser = argparse.ArgumentParser(description='Check that a branch name sets the intended release bump.')
    parser.add_argument('--branch', default='')
    args = parser.parse_args()
    branch = args.branch or subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    if not args.branch and branch in SKIP:
        print("SKIP: '%s' is not a PR branch" % branch)
        return 0
    errors = problems(branch)
    for error in errors:
        print('FAIL: ' + error, file=sys.stderr)
    if errors:
        return 1
    print("PASS: branch '%s' -> %s release bump" % (branch, level(branch)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
