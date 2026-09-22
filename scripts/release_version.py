#!/usr/bin/env python3
"""Reserve a unique semantic tag at a tested commit, safely across concurrent merges."""
import os
import re
import subprocess
import sys
from pathlib import Path

SEMVER = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')

def level(branch):
    if branch.startswith(('major', 'release')):
        return 'major'
    if branch.startswith(('minor', 'feature', 'feat')):
        return 'minor'
    return 'patch'

def next_tag(tags, branch, initial='1.0.0'):
    versions = [tuple(map(int, match.groups())) for tag in tags if (match := SEMVER.fullmatch(tag))]
    floor = tuple(map(int, initial.split('.')))
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
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main'], check=True)
    tag = reserve(commit, os.environ.get('RELEASE_BRANCH', 'patch/manual'), Path('VERSION').read_text().strip())
    values = 'tag=' + tag + '\nversion=' + tag[1:] + '\n'
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(values)
    print(values, end='')
