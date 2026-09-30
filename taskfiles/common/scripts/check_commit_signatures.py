#!/usr/bin/env python3
"""Require GitHub-verified signatures on every new commit (CI policy job).

Usage:
  python3 taskfiles/common/scripts/check_commit_signatures.py --repo OWNER/NAME --sha SHA [--pr NUMBER]

Options:
  --repo    Repository, as in $GITHUB_REPOSITORY.
  --sha     Commit to check when there is no PR (push to main, manual dispatch).
  --pr      Pull request number; when given and not empty, every commit of the PR is checked.

Needs the `gh` CLI with GH_TOKEN (read access). Project tooling (task
common:check:commit-signatures); not part of the shipped app.

Exit codes:
  0 - every checked commit is verified
  1 - a commit is unverified, or none were found
"""
import argparse
import subprocess
import sys


def verified(repo, sha, pr):
    if pr:
        command = ['gh', 'api', '--paginate', 'repos/%s/pulls/%s/commits' % (repo, pr), '--jq', '.[].commit.verification.verified']
    else:
        command = ['gh', 'api', 'repos/%s/commits/%s' % (repo, sha), '--jq', '.commit.verification.verified']
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout.splitlines()


def main():
    parser = argparse.ArgumentParser(description='Require GitHub-verified commit signatures.')
    parser.add_argument('--repo', required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--pr', default='')
    args = parser.parse_args()
    values = verified(args.repo, args.sha, args.pr)
    if not values or any(value != 'true' for value in values):
        print('FAIL: every new commit must have a verified signature', file=sys.stderr)
        return 1
    print('PASS: all new commits have GitHub-verified signatures')
    return 0


if __name__ == '__main__':
    sys.exit(main())
