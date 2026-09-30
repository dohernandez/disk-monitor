#!/usr/bin/env python3
"""Install the pinned Task binary after checking its SHA-256 (taskfiles/provision/task.json).

Usage:
  python3 taskfiles/provision/scripts/install_task.py --dir DIR [--github-path]

Options:
  --dir DIR        Folder that receives the `task` binary (created if missing).
  --github-path    Also append DIR to $GITHUB_PATH so later workflow steps find `task`.

CI runs this directly (it is the bootstrap: no `task` exists yet). It replaces
arduino/setup-task, which does not verify the download, because the release job
runs Task with the update-signing key in its environment. Only the `task` file is
read from the archive; no archive path is ever written to disk.

Exit codes:
  0 - installed and `task --version` matches the pin
  1 - unsupported platform, checksum mismatch or missing binary
"""
import argparse
import hashlib
import io
import json
import os
import platform
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

PIN = Path(__file__).resolve().parents[1] / 'task.json'
PLATFORMS = {('Darwin', 'arm64'): 'darwin_arm64', ('Darwin', 'x86_64'): 'darwin_amd64',
             ('Linux', 'x86_64'): 'linux_amd64', ('Linux', 'aarch64'): 'linux_arm64'}


def task_binary(archive):
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = tar.getmember('task')
        if not member.isreg():
            raise ValueError('task in the archive is not a regular file')
        return tar.extractfile(member).read()


def install(directory, pin=None):
    pin = pin or json.loads(PIN.read_text())
    key = PLATFORMS.get((platform.system(), platform.machine()))
    if key not in pin['sha256']:
        raise SystemExit('Unsupported platform for pinned Task: %s %s' % (platform.system(), platform.machine()))
    url = pin['url'].format(version=pin['version'], platform=key)
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    digest = hashlib.sha256(archive).hexdigest()
    if digest != pin['sha256'][key]:
        raise SystemExit('Task %s checksum mismatch: got %s' % (key, digest))
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / 'task'
    if target.is_symlink():
        raise SystemExit('Refusing to write through a symbolic link: %s' % target)
    staged = directory / '.task.partial'
    staged.unlink(missing_ok=True)
    staged.write_bytes(task_binary(archive))
    staged.chmod(0o755)
    staged.replace(target)
    version = subprocess.run([str(target), '--version'], capture_output=True, text=True, check=True).stdout
    if pin['version'] not in version:
        raise SystemExit('Installed Task reports %r, expected %s' % (version.strip(), pin['version']))
    print('PASS: Task %s (%s) verified and installed at %s' % (pin['version'], key, target))
    return target


def main():
    parser = argparse.ArgumentParser(description='Install the pinned, checksum-verified Task binary.')
    parser.add_argument('--dir', required=True, type=Path)
    parser.add_argument('--github-path', action='store_true')
    args = parser.parse_args()
    directory = args.dir.resolve()
    install(directory)
    if args.github_path:
        with open(os.environ['GITHUB_PATH'], 'a') as path:
            path.write(str(directory) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
