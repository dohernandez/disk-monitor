#!/usr/bin/env python3
"""Reserve a unique semantic tag at a tested commit, safely across concurrent merges."""
import argparse
import os
import re
import subprocess
from pathlib import Path

SEMVER = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')

# Tooling, CI, docs and test-only branches merge without a release (Darien, 2026-09-30).
# check_branch_name.py fails such a PR if it touches shipped files.
NO_RELEASE = ('chore/', 'ci/', 'docs/', 'test/')

def level(branch):
    if branch.startswith(NO_RELEASE):
        return 'none'
    if branch.startswith(('major', 'release')):
        return 'major'
    if branch.startswith(('minor', 'feature', 'feat')):
        return 'minor'
    return 'patch'

def next_tag(tags, branch, initial='1.0.0'):
    versions = [tuple(map(int, match.groups())) for tag in tags if (match := SEMVER.fullmatch(tag))]
    floor = tuple(map(int, initial.split('.')))
    if level(branch) == 'none':
        raise ValueError('Branch ' + branch + ' does not release')
    if not versions:
        return 'v' + initial
    major, minor, patch = max(versions)
    bump = level(branch)
    candidate = (major + 1, 0, 0) if bump == 'major' else (major, minor + 1, 0) if bump == 'minor' else (major, minor, patch + 1)
    return 'v' + '.'.join(map(str, max(floor, candidate)))

def remote_tags():
    raw = subprocess.check_output(['git', 'ls-remote', '--tags', 'origin'], text=True)
    tags = {}
    for line in raw.splitlines():
        sha, ref = line.split()
        tag = ref.removeprefix('refs/tags/').removesuffix('^{}')
        if SEMVER.fullmatch(tag):
            if ref.endswith('^{}') or tag not in tags:
                tags[tag] = sha
    return tags

def reserve(commit, branch, initial='1.0.0'):
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Expected a full commit SHA')
    for _ in range(12):
        tags = remote_tags()
        existing = [tag for tag, sha in tags.items() if sha == commit]
        if existing:
            if len(existing) != 1:
                raise ValueError('Multiple version tags point at this commit; inspect before releasing')
            return existing[0]
        tag = next_tag(tags, branch, initial)
        result = subprocess.run(['git', 'push', 'origin', commit + ':refs/tags/' + tag], text=True, capture_output=True)
        if result.returncode == 0:
            return tag
        if remote_tags() == tags:
            raise RuntimeError('Cannot reserve release tag: ' + result.stderr)
        # A concurrent merge reserved this version. Re-read and retry, never force-push.
    raise RuntimeError('Too many concurrent version reservations; rerun this workflow')

if __name__ == '__main__':
    argparse.ArgumentParser(description='Reserve or reuse the release tag of HEAD. Reads RELEASE_BRANCH; writes release, tag and version to GITHUB_OUTPUT.').parse_args()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main'], check=True)
    branch = os.environ.get('RELEASE_BRANCH', 'patch/manual')
    if level(branch) == 'none':
        values = 'release=false\n'
        print('No release: ' + branch + ' is a tooling/CI/docs/test branch')
    else:
        tag = reserve(commit, branch, Path('VERSION').read_text().strip())
        values = 'release=true\ntag=' + tag + '\nversion=' + tag[1:] + '\n'
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(values)
    print(values, end='')
