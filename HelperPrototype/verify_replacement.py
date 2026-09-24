#!/usr/bin/env python3
"""Read-only preflight. Never installs, registers, prompts, or changes trust."""
import plistlib
import subprocess
import sys
from pathlib import Path


def checked(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Signature verification failed: ' + result.stderr.strip())
    return result.stdout + result.stderr


def requirement(path):
    output = checked(['/usr/bin/codesign', '-d', '-r-', str(path)])
    for line in output.splitlines():
        if line.startswith('designated => '):
            return line.removeprefix('designated => ')
    raise ValueError('Missing designated requirement')


def verify(previous, replacement):
    previous, replacement = Path(previous), Path(replacement)
    old = plistlib.loads((previous / 'Contents/Info.plist').read_bytes())
    new = plistlib.loads((replacement / 'Contents/Info.plist').read_bytes())
    if old['CFBundleIdentifier'] != new['CFBundleIdentifier']:
        raise ValueError('Bundle identifier changed; this is not an upgrade')
    if int(new['CFBundleVersion']) <= int(old['CFBundleVersion']):
        raise ValueError('Replacement must have a strictly higher build number')
    for relative in ['', 'Contents/MacOS/Scanner']:
        old_path, new_path = previous / relative, replacement / relative
        checked(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(old_path)])
        checked(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(new_path)])
        checked(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement(old_path), str(new_path)])
    return 'PASS: increasing build number and original app/helper signing requirements retained'


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3:
            raise ValueError('Usage: verify_replacement.py PREVIOUS_APP REPLACEMENT_APP')
        print(verify(*sys.argv[1:]))
    except (ValueError, OSError, KeyError) as error:
        sys.exit(str(error))
