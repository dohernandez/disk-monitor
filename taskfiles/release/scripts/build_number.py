#!/usr/bin/env python3
"""Choose the release build number (CFBundleVersion / sparkle:version) and refuse regressions.

Usage:
  python3 taskfiles/release/scripts/build_number.py --repo OWNER/NAME --run-number N --tag vX.Y.Z [--offset 100]

Options:
  --repo        Repository, as in $GITHUB_REPOSITORY.
  --run-number  Run number of the Checks run that tested the commit.
  --tag         The tag this release will publish (from release:version).
  --offset      Added to the run number (default 100). Checks restarted its run numbers
                when release moved to its own workflow; v1.10.0 shipped build 8 while
                v1.9.1 had 79, so Sparkle hid the update. The offset keeps builds above
                every earlier release.

Sparkle offers an update only when its build is higher than the installed one, and users
may still run any earlier release. This fails unless the new build is higher than the
highest build of every published release; a re-run of an already published tag must keep
its build. Prints build=N and appends it to $GITHUB_OUTPUT when set.
Needs `gh` with GH_TOKEN. Project tooling (task release:build-number); not part of the shipped app.
"""
import argparse
import os
import re
import subprocess
import sys


def published_build(appcast):
    builds = [int(value) for value in re.findall(r'<sparkle:version>\s*(\d+)\s*</sparkle:version>', appcast)]
    if not builds:
        raise ValueError('The latest appcast has no sparkle:version')
    return max(builds)


def choose(run_number, offset, tag, published):
    """published maps each released tag to its build."""
    build = run_number + offset
    if tag in published:
        if build != published[tag]:
            raise ValueError(f'{tag} was published with build {published[tag]}; a re-run must not change it (got {build})')
        return build
    if published:
        top = max(published, key=published.get)
        if build <= published[top]:
            raise ValueError(f'Build {build} is not above {top} build {published[top]}; Sparkle would not offer this update')
    return build


def published_builds(repo, limit=100):
    tags = subprocess.run(['gh', 'release', 'list', '--repo', repo, '--limit', str(limit), '--json', 'tagName', '--jq', '.[].tagName'],
                          capture_output=True, text=True, check=True).stdout.split()
    builds = {}
    for tag in tags:
        appcast = subprocess.run(['gh', 'release', 'download', tag, '--repo', repo, '-p', 'appcast-arm64.xml', '-O', '-'],
                                 capture_output=True, text=True)
        if appcast.returncode == 0:
            builds[tag] = published_build(appcast.stdout)
    return builds


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--run-number', type=int, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--offset', type=int, default=100)
    args = parser.parse_args()
    build = choose(args.run_number, args.offset, args.tag, published_builds(args.repo))
    print(f'build={build}')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
            out.write(f'build={build}\n')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
