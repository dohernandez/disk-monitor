#!/usr/bin/env python3
"""Find the branch of the PR merged as a main commit; its prefix sets the version bump.

Usage:
  python3 taskfiles/release/scripts/merged_branch.py --repo OWNER/NAME --sha SHA

Options:
  --repo    Repository, as in $GITHUB_REPOSITORY.
  --sha     The main commit being released.

Prints RELEASE_BRANCH=<branch> and, when $GITHUB_ENV is set, appends it there for
release:version. A commit with no merged PR (direct push, manual dispatch) gets
patch/direct-push. Needs `gh` with GH_TOKEN. Project tooling (task
release:version:branch); not part of the shipped app.
"""
import argparse
import json
import os
import subprocess
import sys


def merged_branch(pulls, sha):
    branches = [p['head']['ref'] for p in pulls if p.get('merged_at') and p.get('merge_commit_sha') == sha]
    return branches[0] if branches else 'patch/direct-push'


def main():
    parser = argparse.ArgumentParser(description='Find the merged PR branch of a main commit.')
    parser.add_argument('--repo', required=True)
    parser.add_argument('--sha', required=True)
    args = parser.parse_args()
    raw = subprocess.run(['gh', 'api', 'repos/%s/commits/%s/pulls' % (args.repo, args.sha)], capture_output=True, text=True, check=True).stdout
    line = 'RELEASE_BRANCH=' + merged_branch(json.loads(raw), args.sha) + '\n'
    if os.environ.get('GITHUB_ENV'):
        with open(os.environ['GITHUB_ENV'], 'a') as out:
            out.write(line)
    print(line, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
