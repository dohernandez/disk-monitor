"""Check internal helper identity continuity without registration or installation."""
from pathlib import Path
import plistlib
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'HelperPrototype'))
from verify_replacement import checked, requirement
old, new = map(Path, sys.argv[1:])
metadata = [plistlib.loads((app / 'Contents/Info.plist').read_bytes()) for app in (old, new)]
assert metadata[0]['CFBundleIdentifier'] == metadata[1]['CFBundleIdentifier'] == 'local.darien.diskmonitor'
assert int(metadata[1]['CFBundleVersion']) > int(metadata[0]['CFBundleVersion'])
for relative in ('', 'Contents/MacOS/Scanner', 'Contents/MacOS/ScannerBridge'):
    before, after = [app / relative for app in (old, new)]
    for path in (before, after):
        checked(['codesign', '--verify', '--strict', str(path)])
    checked(['codesign', '--verify', '--strict', '-R', '=' + requirement(before), str(after)])
print('PASS: app identity, increasing build and pinned internal helper identities retained')
