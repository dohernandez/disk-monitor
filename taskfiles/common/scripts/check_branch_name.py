#!/usr/bin/env python3
"""Check a branch name: its prefix sets the release version bump, so a typo must fail.

Usage:
  python3 taskfiles/common/scripts/check_branch_name.py --branch NAME [--repo OWNER/NAME --pr NUMBER]
  python3 taskfiles/common/scripts/check_branch_name.py

Options:
  --branch NAME    Branch to check (CI passes the PR head branch). Without it, the
                   current git branch is checked; main and a detached HEAD are skipped.
  --repo, --pr     With a no-release branch, list the PR's files (gh + GH_TOKEN) and
                   fail if any shipped file changed.

A merged PR's branch prefix decides the release (taskfiles/release/scripts/
release_version.py): chore/, ci/, docs/, test/ -> no release; major*/release* -> major;
minor*/feature*/feat* -> minor; anything else -> patch. A misspelled prefix such as
`fetaure/x` would silently ship as a patch, so only `<type>/<slug>` with a known type is
accepted, and a no-release PR may not change what ships (SHIPPED). The printed result
comes from release_version.level itself, so the check cannot drift from the release logic.

Project tooling (task common:check:branch-name); not part of the shipped app.

Exit codes:
  0 - valid (or skipped: main / detached HEAD)
  1 - invalid branch name
"""
import argparse
import json
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
_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_ROOT / 'tests/release'))
from test_shipped_source import SHIPPED as SHIPPED_SWIFT  # noqa: E402

# Files that end up in the app bundle or decide its contents: every Swift source a release
# compiles (tests/release/test_shipped_source.py SHIPPED, itself checked against build.sh)
# plus VERSION and the build inputs. A change here needs a releasing branch (fix/, feat/, ...),
# never chore/ci/docs/test.
SHIPPED = SHIPPED_SWIFT + ('VERSION', 'taskfiles/build/scripts/build.sh', 'taskfiles/build/scripts/bundle_info.py',
                           'taskfiles/build/scripts/update-config.json', 'taskfiles/build/scripts/key_public.swift',
                           'taskfiles/build/scripts/sparkle.py', 'taskfiles/build/scripts/secure_archive.py',
                           'taskfiles/build/scripts/scanner_identity.py', 'taskfiles/build/scripts/scanner_constraint.py',
                           'taskfiles/build/scripts/build_signed_scanner.py')


def problems(branch, files=()):
    if not BRANCH.fullmatch(branch):
        return ["branch '%s' must be '<type>/<slug>' (lowercase slug); type one of %s. The prefix sets the "
                "release: chore/ci/docs/test -> none, major/release -> major, minor/feature/feat -> minor, others -> patch"
                % (branch, ', '.join(TYPES))]
    shipped = sorted(set(files) & set(SHIPPED))
    if level(branch) == 'none' and shipped:
        return ["branch '%s' does not release, but changes shipped files: %s. Use a releasing prefix such as fix/ or feat/"
                % (branch, ', '.join(shipped))]
    return []


def pr_files(repo, pr):
    raw = subprocess.run(['gh', 'api', '--paginate', 'repos/%s/pulls/%s/files' % (repo, pr), '--jq', '.[] | {filename, previous_filename}'],
                         capture_output=True, text=True, check=True).stdout
    names = []
    for line in raw.splitlines():
        entry = json.loads(line)
        names += [n for n in (entry.get('filename'), entry.get('previous_filename')) if n]
    return names


def main():
    parser = argparse.ArgumentParser(description='Check that a branch name sets the intended release bump.')
    parser.add_argument('--branch', default='')
    parser.add_argument('--repo', default='')
    parser.add_argument('--pr', default='')
    args = parser.parse_args()
    branch = args.branch or subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    if not args.branch and branch in SKIP:
        print("SKIP: '%s' is not a PR branch" % branch)
        return 0
    files = pr_files(args.repo, args.pr) if args.repo and args.pr and level(branch) == 'none' else ()
    errors = problems(branch, files)
    for error in errors:
        print('FAIL: ' + error, file=sys.stderr)
    if errors:
        return 1
    bump = level(branch)
    print("PASS: branch '%s' -> %s" % (branch, 'no release' if bump == 'none' else bump + ' release bump'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
