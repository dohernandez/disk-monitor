"""Bind launchd to the final signed scanner, before signing its containing app."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

SERVICE = 'local.darien.diskmonitor.scanner.service'

def constraint(app):
    executable = Path(app) / 'Contents/MacOS/Scanner'
    subprocess.run(['codesign', '--verify', '--strict', str(executable)], check=True)
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(executable)],
                            capture_output=True, text=True, check=True)
    hashes = re.findall(r'^CDHash=([0-9a-fA-F]{40})$', result.stderr, re.M)
    identifiers = re.findall(r'^Identifier=(.+)$', result.stderr, re.M)
    if len(hashes) != 1 or identifiers != [SERVICE]:
        raise ValueError('Expected one native scanner signature with the service identity')
    return {'signing-identifier': SERVICE, 'cdhash': bytes.fromhex(hashes[0])}

def check(app):
    path = Path(app) / f'Contents/Library/LaunchDaemons/{SERVICE}.plist'
    actual = plistlib.loads(path.read_bytes()).get('SpawnConstraint')
    if actual != constraint(app):
        raise ValueError('Scanner launch constraint does not match the signed executable')

if __name__ == '__main__':
    app = Path(sys.argv[1])
    path = app / f'Contents/Library/LaunchDaemons/{SERVICE}.plist'
    value = plistlib.loads(path.read_bytes())
    value['SpawnConstraint'] = constraint(app)
    path.write_bytes(plistlib.dumps(value))
