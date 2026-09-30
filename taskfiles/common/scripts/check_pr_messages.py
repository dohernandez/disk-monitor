#!/usr/bin/env python3
"""Check every new commit message, and the PR description, for AI attribution (CI Lint job).

Usage:
  python3 taskfiles/common/scripts/check_pr_messages.py --repo OWNER/NAME --sha SHA [--pr NUMBER]

Options:
  --repo    Repository, as in $GITHUB_REPOSITORY.
  --sha     Commit to check when there is no PR (push to main, manual dispatch).
  --pr      Pull request number; when given and not empty, every PR commit and the PR
            description are checked.

Commits made through GitHub's signed commit API never run local git hooks, so CI
runs the SAME task the commit-msg hook runs, `task common:check:commit-msg`, on each
message: every commit gets the full check (conventional subject, no AI attribution),
the PR description gets `--attribution-only`.
Needs `gh` with GH_TOKEN (read access). Project tooling (task
common:check:pr-messages); not part of the shipped app.

Exit codes:
  0 - every message is valid
  1 - a message fails, or no commit was found
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def gh(*args):
    return subprocess.run(['gh', 'api', *args], capture_output=True, text=True, check=True).stdout


def messages(repo, sha, pr):
    """[(label, text, full_check)] for the commits and, for a PR, its description."""
    if pr:
        commits = [json.loads(line) for line in gh('--paginate', 'repos/%s/pulls/%s/commits' % (repo, pr), '--jq', '.[] | {sha, message: .commit.message}').splitlines()]
        body = json.loads(gh('repos/%s/pulls/%s' % (repo, pr)))['body'] or ''
        return [(c['sha'][:7], c['message'], True) for c in commits] + [('PR #%s description' % pr, body, False)]
    commit = json.loads(gh('repos/%s/commits/%s' % (repo, sha)))
    return [(commit['sha'][:7], commit['commit']['message'], True)]


def commit_msg_task(text, full):
    """Run `task common:check:commit-msg` (the hook's task) on one message; return its errors."""
    with tempfile.TemporaryDirectory(prefix='pr-message-') as directory:
        message = Path(directory) / 'message.txt'
        message.write_text(text)
        command = ['task', 'common:check:commit-msg', '--'] + ([] if full else ['--attribution-only']) + [str(message)]
        result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        return []
    lines = [ln for ln in result.stderr.splitlines() if ln.startswith('commit message: ')]
    return lines or ['common:check:commit-msg failed: ' + result.stderr.strip()]


def failures(items, run=commit_msg_task):
    found = []
    for label, text, full in items:
        found += ['%s: %s' % (label, error) for error in run(text, full)]
    return found


def main():
    parser = argparse.ArgumentParser(description='Check PR commit messages and description for AI attribution.')
    parser.add_argument('--repo', required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--pr', default='')
    args = parser.parse_args()
    items = messages(args.repo, args.sha, args.pr)
    if not any(full for _, _, full in items):
        print('FAIL: no commits found', file=sys.stderr)
        return 1
    problems = failures(items)
    for problem in problems:
        print('FAIL: ' + problem, file=sys.stderr)
    if problems:
        return 1
    print('PASS: %d commit message(s)%s free of AI attribution' % (sum(1 for i in items if i[2]), ' and the PR description' if args.pr else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
